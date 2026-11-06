package com.fanrenxiuxianguanyingchuan

import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.util.Base64
import com.google.zxing.BarcodeFormat
import com.google.zxing.EncodeHintType
import com.google.zxing.MultiFormatWriter
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream
import java.io.File
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.drinkless.tdlib.TdApi

/**
 * TDLib 登录桥（第一阶段：库 + 桥 + 登录）。
 *
 * Dart 侧经 MethodChannel `fqapp/tdlib` 调方法、经 EventChannel
 * `fqapp/tdlib/events` 收登录状态变化。TDLib 的登录态存在它自己的
 * 数据库目录里（Dart 侧传过来的 getApplicationSupportDirectory()/tdlib），
 * 不需要 session.json；凭证（api_id/api_hash）每次初始化时由 Dart 侧
 * 从构建期注入传过来，不写死、不记日志、不进 git。
 *
 * 二维码由 Kotlin 侧用 ZXing 画成 PNG（照 TeleTV 的 Qr.kt），
 * Base64 后放在 ShowQr 状态事件里给 Dart 侧直接显示，不新增 Dart 依赖。
 *
 * 插件那套（tgdrama-android + tgphone）不动，这是并列的另一条登录路。
 */
class TdlibPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private val mainHandler = Handler(Looper.getMainLooper())

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var client: TdlibClient? = null
    private var repository: TdlibAuthRepository? = null
    private var eventSink: EventChannel.EventSink? = null
    private var lastQrLink: String? = null
    private var lastQrPngBase64: String? = null

    // 上次初始化的参数：退出登录后重建客户端（restart）时复用，
    // 凭证不记日志、不进 git，只留在内存里。
    private var lastApiId: Int = 0
    private var lastApiHash: String = ""
    private var lastDatabaseDir: String = ""
    private var lastFilesDir: String = ""
    private var lastApplicationVersion: String = "1.0.0"

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel = MethodChannel(binding.binaryMessenger, "fqapp/tdlib")
        methodChannel.setMethodCallHandler(this)
        eventChannel = EventChannel(binding.binaryMessenger, "fqapp/tdlib/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
        scope.cancel()
        runCatching { client?.close() }
        client = null
        repository = null
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // 刚订阅就把当前状态推一次，Dart 侧不用等下一次变化。
        repository?.let { postState(it.state.value) }
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "initialize" -> initialize(call, result)
            "getState" -> {
                val repo = repository
                if (repo == null) {
                    result.success(stateMap(TdlibAuthState.Initializing))
                } else {
                    result.success(stateMap(repo.state.value))
                }
            }
            "requestQrCode" -> {
                // 等登录方式时要二维码；等密码时是换号重登；正在显示时
                // 链接由 TDLib 自动刷新，直接回当前状态。
                val repo = repository
                if (repo == null) {
                    result.error("not_initialized", "TDLib 未初始化", null)
                } else {
                    repo.requestQrCode()
                    result.success(stateMap(repo.state.value))
                }
            }
            "sendPhoneCode" -> {
                val phone = call.argument<String>("phone").orEmpty()
                if (phone.isEmpty()) {
                    result.error("invalid_argument", "缺少手机号", null)
                } else {
                    sendPhoneCode(phone, result)
                }
            }
            "checkCode" -> {
                val code = call.argument<String>("code")
                if (code.isNullOrEmpty()) {
                    result.error("invalid_argument", "缺少短信验证码", null)
                } else if (repository == null) {
                    result.error("not_initialized", "TDLib 未初始化", null)
                } else {
                    repository!!.checkCode(code)
                    result.success(null)
                }
            }
            "resendCode" -> resendCode(result)
            "register" -> {
                val firstName = call.argument<String>("firstName").orEmpty()
                val lastName = call.argument<String>("lastName").orEmpty()
                if (firstName.isEmpty()) {
                    result.error("invalid_argument", "请先输入名字", null)
                } else {
                    register(firstName, lastName, result)
                }
            }
            "restart" -> restart(result)
            "submitPassword" -> {
                val password = call.argument<String>("password")
                if (password.isNullOrEmpty()) {
                    result.error("invalid_argument", "缺少二步验证密码", null)
                } else if (repository == null) {
                    result.error("not_initialized", "TDLib 未初始化", null)
                } else {
                    repository!!.checkPassword(password)
                    result.success(null)
                }
            }
            "logOut" -> {
                val repo = repository
                if (repo == null) {
                    result.error("not_initialized", "TDLib 未初始化", null)
                } else {
                    repo.logOut { message -> postEvent(mapOf("state" to "logoutError", "message" to message)) }
                    result.success(null)
                }
            }
            "getMe" -> getMe(result)
            else -> result.notImplemented()
        }
    }

    private fun initialize(call: MethodCall, result: MethodChannel.Result) {
        val existing = repository
        if (existing != null) {
            // 已退出时重建客户端再登（TeleTV 登出后也是重建客户端）；
            // 其他状态直接回当前状态。
            if (existing.state.value !is TdlibAuthState.LoggedOut) {
                result.success(stateMap(existing.state.value))
                return
            }
            runCatching { client?.close() }
            client = null
            repository = null
        }
        val apiId = (call.argument<Int>("apiId") ?: 0)
        val apiHash = call.argument<String>("apiHash").orEmpty()
        val databaseDirArg = call.argument<String>("databaseDir").orEmpty()
        val filesDirArg = call.argument<String>("filesDir").orEmpty()
        val applicationVersion = call.argument<String>("applicationVersion") ?: "1.0.0"
        if (apiId == 0 || apiHash.isEmpty() || databaseDirArg.isEmpty()) {
            result.error("missing_credentials", "缺少 Telegram 凭证或数据库目录", null)
            return
        }
        val newClient: TdlibClient
        try {
            // 构造器里加载 libcryptox/libsslx/libtdjni，缺库时这里抛
            // UnsatisfiedLinkError，不许炸启动，只回不可用。
            newClient = TdlibClient()
        } catch (error: Throwable) {
            result.error("tdlib_unavailable", "TDLib 原生库加载失败：${error.message}", null)
            return
        }
        lastApiId = apiId
        lastApiHash = apiHash
        lastDatabaseDir = databaseDirArg
        lastFilesDir = if (filesDirArg.isEmpty()) "$databaseDirArg-files" else filesDirArg
        lastApplicationVersion = applicationVersion
        val repo = TdlibAuthRepository(
            client = newClient,
            scope = scope,
            apiId = apiId,
            apiHash = apiHash,
            databaseDir = File(databaseDirArg),
            filesDir = File(lastFilesDir),
            applicationVersion = applicationVersion,
        )
        client = newClient
        repository = repo
        scope.launch {
            repo.state.collect { state -> postState(state) }
        }
        repo.start()
        result.success(stateMap(repo.state.value))
    }

    /**
     * 关掉旧客户端、按上次初始化的参数重建一个（换手机号、退出后重登用）。
     * 退出前重建不了：先调 initialize。
     */
    private fun restart(result: MethodChannel.Result) {
        val repo = repository
        if (repo == null || lastApiId == 0 || lastApiHash.isEmpty() || lastDatabaseDir.isEmpty()) {
            result.error("not_initialized", "TDLib 未初始化", null)
            return
        }
        runCatching { client?.close() }
        client = null
        repository = null
        val newClient: TdlibClient
        try {
            newClient = TdlibClient()
        } catch (error: Throwable) {
            result.error("tdlib_unavailable", "TDLib 原生库加载失败：${error.message}", null)
            return
        }
        val newRepo = TdlibAuthRepository(
            client = newClient,
            scope = scope,
            apiId = lastApiId,
            apiHash = lastApiHash,
            databaseDir = File(lastDatabaseDir),
            filesDir = File(lastFilesDir),
            applicationVersion = lastApplicationVersion,
        )
        client = newClient
        repository = newRepo
        scope.launch {
            newRepo.state.collect { state -> postState(state) }
        }
        newRepo.start()
        result.success(stateMap(newRepo.state.value))
    }

    /** 发短信验证码：成功回 {"action": "sent"/"resent", "phoneNumber": ...}。 */
    private fun sendPhoneCode(phone: String, result: MethodChannel.Result) {
        val repo = repository
        if (repo == null) {
            result.error("not_initialized", "TDLib 未初始化", null)
            return
        }
        scope.launch {
            runCatching { repo.sendPhoneCode(phone) }
                .onSuccess { action ->
                    mainHandler.post {
                        result.success(
                            mapOf<String, Any?>(
                                "action" to action,
                                "phoneNumber" to phone,
                            )
                        )
                    }
                }
                .onFailure { error ->
                    mainHandler.post {
                        result.error(
                            "phone_failed",
                            error.message ?: "发送验证码失败",
                            null,
                        )
                    }
                }
        }
    }

    /** 验证码重发一遍（只能在等验证码时调）。 */
    private fun resendCode(result: MethodChannel.Result) {
        val repo = repository
        if (repo == null) {
            result.error("not_initialized", "TDLib 未初始化", null)
            return
        }
        scope.launch {
            runCatching { repo.resendCode() }
                .onSuccess {
                    mainHandler.post { result.success(null) }
                }
                .onFailure { error ->
                    mainHandler.post {
                        result.error(
                            "phone_failed",
                            error.message ?: "重新发送验证码失败",
                            null,
                        )
                    }
                }
        }
    }

    /** 未注册的手机号填名字完成注册。 */
    private fun register(firstName: String, lastName: String, result: MethodChannel.Result) {
        val repo = repository
        if (repo == null) {
            result.error("not_initialized", "TDLib 未初始化", null)
            return
        }
        scope.launch {
            runCatching { repo.registerUser(firstName, lastName) }
                .onSuccess {
                    mainHandler.post { result.success(null) }
                }
                .onFailure { error ->
                    mainHandler.post {
                        result.error(
                            "register_failed",
                            error.message ?: "注册失败",
                            null,
                        )
                    }
                }
        }
    }

    private fun getMe(result: MethodChannel.Result) {
        val activeClient = client
        val repo = repository
        if (activeClient == null || repo == null) {
            result.error("not_initialized", "TDLib 未初始化", null)
            return
        }
        if (repo.state.value !is TdlibAuthState.Ready) {
            result.error("not_ready", "TDLib 未登录", null)
            return
        }
        scope.launch {
            runCatching { activeClient.send<TdApi.User>(TdApi.GetMe()) }
                .onSuccess { user ->
                    val username = user.usernames?.activeUsernames?.firstOrNull()
                        ?: user.usernames?.editableUsername
                    withContext(Dispatchers.Main) {
                        result.success(
                            mapOf<String, Any?>(
                                "id" to user.id,
                                "firstName" to user.firstName,
                                "lastName" to user.lastName,
                                "username" to username,
                                "phoneNumber" to user.phoneNumber,
                            )
                        )
                    }
                }
                .onFailure { error ->
                    withContext(Dispatchers.Main) {
                        result.error("get_me_failed", error.message ?: "取当前用户失败", null)
                    }
                }
        }
    }

    private fun postState(state: TdlibAuthState) {
        postEvent(stateMap(state))
    }

    private fun postEvent(event: Map<String, Any?>) {
        mainHandler.post { eventSink?.success(event) }
    }

    /**
     * 登录状态转 Dart 侧的 map。ShowQr 时附上二维码 PNG（Base64），
     * 同一链接只生成一次；不含凭证，不记日志。
     */
    private fun stateMap(state: TdlibAuthState): Map<String, Any?> {
        return when (state) {
            is TdlibAuthState.Initializing -> mapOf("state" to "initializing")
            is TdlibAuthState.WaitPhoneNumber -> mapOf("state" to "waitPhoneNumber")
            is TdlibAuthState.ShowQr -> {
                val png = qrPngBase64(state.link)
                val map = mutableMapOf<String, Any?>(
                    "state" to "showQr",
                    "link" to state.link,
                )
                if (png != null) map["qrPngBase64"] = png
                map
            }
            is TdlibAuthState.WaitCode -> mapOf(
                "state" to "waitCode",
                "phoneNumber" to state.phoneNumber,
                "timeout" to state.timeout,
                "error" to state.error,
                "checking" to state.checking,
            )
            is TdlibAuthState.WaitRegistration -> mapOf("state" to "waitRegistration")
            is TdlibAuthState.WaitPassword -> mapOf(
                "state" to "waitPassword",
                "hint" to state.hint,
                "error" to state.error,
                "checking" to state.checking,
            )
            is TdlibAuthState.Ready -> mapOf("state" to "ready")
            is TdlibAuthState.Error -> mapOf("state" to "error", "message" to state.message)
            is TdlibAuthState.SigningOut -> mapOf("state" to "signingOut")
            is TdlibAuthState.LoggedOut -> mapOf("state" to "loggedOut")
        }
    }

    private fun qrPngBase64(link: String): String? {
        if (link == lastQrLink && lastQrPngBase64 != null) return lastQrPngBase64
        return try {
            val hints = mapOf(EncodeHintType.MARGIN to 1)
            val matrix = MultiFormatWriter().encode(
                link, BarcodeFormat.QR_CODE, QR_SIZE, QR_SIZE, hints
            )
            val bitmap = Bitmap.createBitmap(QR_SIZE, QR_SIZE, Bitmap.Config.RGB_565)
            for (x in 0 until QR_SIZE) {
                for (y in 0 until QR_SIZE) {
                    bitmap.setPixel(x, y, if (matrix[x, y]) Color.BLACK else Color.WHITE)
                }
            }
            val out = ByteArrayOutputStream()
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, out)
            val encoded = Base64.encodeToString(out.toByteArray(), Base64.NO_WRAP)
            lastQrLink = link
            lastQrPngBase64 = encoded
            encoded
        } catch (error: Throwable) {
            null
        }
    }

    private companion object {
        const val QR_SIZE = 512
    }
}
