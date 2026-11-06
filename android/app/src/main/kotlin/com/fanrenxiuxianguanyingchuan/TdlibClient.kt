package com.fanrenxiuxianguanyingchuan

import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.channels.BufferOverflow
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.filterIsInstance
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.withTimeoutOrNull
import org.drinkless.tdlib.Client
import org.drinkless.tdlib.TdApi
import java.util.concurrent.ConcurrentHashMap

/** TDLib 返回 [TdApi.Error] 时抛出。 */
class TdlibException(val error: TdApi.Error) :
    Exception("TDLib error ${error.code}: ${error.message}")

/**
 * TDLib JNI 接口的协程/Flow 封装（照 TeleTV 的 TdlibClient 抄）。
 *
 * - 发请求是挂起函数（[send]），TDLib 回包后恢复。
 * - 收到的更新走共享 [updates] 流（多方订阅）。
 * - 每个文件的最新快照记在 [latestFile]，供后续边下边播用。
 */
class TdlibClient {

    // 原生库必须在 Client.create() 调任何 native 方法之前加载。
    // 先声明，保证在 `client` 属性初始化之前跑。
    private val nativeReady: Boolean = NativeLibs.ensureLoaded()

    // 初始化顺序很关键：Client.create() 会立刻起接收线程，
    // onIncoming() 可能在构造器跑完之前就被调到。
    // onIncoming() 碰到的字段（_updates、fileCache）必须在 `client` 之前初始化，
    // 否则头几个更新（含关键的 UpdateAuthorizationState）会因空字段被丢掉。
    private val _updates = MutableSharedFlow<TdApi.Update>(
        extraBufferCapacity = 512,
        onBufferOverflow = BufferOverflow.DROP_OLDEST
    )
    val updates: SharedFlow<TdApi.Update> = _updates.asSharedFlow()

    private val fileCache = ConcurrentHashMap<Int, TdApi.File>()

    private val client: Client = Client.create(
        /* updateHandler = */ { obj -> onIncoming(obj) },
        /* updateExceptionHandler = */ { e -> e.printStackTrace() },
        /* defaultExceptionHandler = */ { e -> e.printStackTrace() }
    )

    init {
        // 关掉 TDLib 原生日志。Client.execute 跑同步的、只管日志的函数。
        Client.execute(TdApi.SetLogVerbosityLevel(1))
    }

    private fun onIncoming(obj: TdApi.Object) {
        if (obj is TdApi.Update) {
            if (obj is TdApi.UpdateFile) fileCache[obj.file.id] = obj.file
            _updates.tryEmit(obj)
        }
    }

    /** 某个文件的最新快照，没见过返回 null。 */
    fun latestFile(fileId: Int): TdApi.File? = fileCache[fileId]

    /**
     * 发一个 TDLib 请求，挂起等回包。
     * TDLib 回错误时抛 [TdlibException]。
     */
    @Suppress("UNCHECKED_CAST")
    suspend fun <T : TdApi.Object> send(function: TdApi.Function<*>): T {
        val deferred = CompletableDeferred<TdApi.Object>()
        client.send(function) { result -> deferred.complete(result) }
        val result = deferred.await()
        if (result is TdApi.Error) throw TdlibException(result)
        // 直接回包里的文件快照也要记：下完的文件不再发 updateFile，
        // 请求结果（DownloadFile/GetFile）可能是它当前状态的唯一来源。
        if (result is TdApi.File) fileCache[result.id] = result
        return result as T
    }

    /**
     * 等下一个 [TdApi.UpdateFile]（[fileId] 的），[timeoutMs] 后没等到返回 null。
     * 供后续边下边播的数据源等更多已下字节用。
     */
    suspend fun awaitFileUpdate(fileId: Int, timeoutMs: Long): TdApi.File? =
        withTimeoutOrNull(timeoutMs) {
            updates.filterIsInstance<TdApi.UpdateFile>().first { it.file.id == fileId }.file
        }

    fun close() {
        client.send(TdApi.Close()) { }
    }
}

/**
 * 加载 TDLib 原生库（src/main/jniLibs），按依赖顺序。
 * libtdjni 链接的是 Telegram X 改名后的 OpenSSL 库（libcryptox / libsslx）。
 */
private object NativeLibs {
    @Volatile
    private var loaded = false

    @Synchronized
    fun ensureLoaded(): Boolean {
        if (!loaded) {
            System.loadLibrary("cryptox")
            System.loadLibrary("sslx")
            System.loadLibrary("tdjni")
            loaded = true
        }
        return true
    }
}
