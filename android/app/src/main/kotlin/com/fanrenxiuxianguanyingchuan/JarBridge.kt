package com.fanrenxiuxianguanyingchuan

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.github.catvod.spider.Init
import dalvik.system.DexClassLoader
import dalvik.system.DexFile
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileOutputStream
import java.lang.reflect.InvocationTargetException
import java.net.HttpURLConnection
import java.net.URL
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

object JarBridge {

    private const val CHANNEL = "juhe/jarbridge"
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())
    private val loaders = ConcurrentHashMap<String, DexClassLoader>()
    private val spiders = ConcurrentHashMap<String, Any>()
    private val initialized = ConcurrentHashMap.newKeySet<String>()
    // 同一 configId 的解包锁：Dart 侧首页影视区一窗 3 站并发加载时，
    // 3 路 callJson 会同时调 ensureJar；不加锁时它们抢同一个
    // `<configId>.jar.part` 临时文件和同一个目标文件，互相删文件、
    // 互相抢临时文件，能把目标删空（18 轮升级后指纹变了、首次解包
    // 必走替换路径，撞上即全部 jar 站报“jar 文件不存在，无法加载”，
    // 且 Dart 侧缓存了路径、重试也不好）。锁按 configId 分，
    // 不同 jar 的解包互不阻塞。
    private val ensureLocks = ConcurrentHashMap<String, Any>()
    // 当前系统出口代理（与 Rust 核心走同一份，见 SystemProxyService）：
    // Dart 侧启动与网络变化时经 setJarProxy 送进来；新起的加载器在建蜘蛛
    // 时补上，已在的加载器在 setJarProxy 里当场刷一遍。
    @Volatile
    private var jarProxyUrl: String = ""

    fun register(messenger: BinaryMessenger, context: Context) {
        Init.init(context)
        MethodChannel(messenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "ensureJar" -> {
                    val configId = call.argument<String>("configId").orEmpty()
                    val url = call.argument<String>("url").orEmpty()
                    val md5 = call.argument<String>("md5").orEmpty()
                    if (configId.isEmpty() || url.isEmpty()) {
                        result.error("jar_invalid", "缺少 jar 配置标识或下载地址", null)
                    } else {
                        runAsync(result) { ensureJar(context, configId, url, md5) }
                    }
                }
                "call" -> {
                    val siteId = call.argument<String>("siteId").orEmpty()
                    val jarPath = call.argument<String>("jarPath").orEmpty()
                    val className = call.argument<String>("className").orEmpty()
                    val method = call.argument<String>("method").orEmpty()
                    if (siteId.isEmpty() || jarPath.isEmpty() || className.isEmpty() || method.isEmpty()) {
                        result.error("jar_invalid", "缺少 jar 站点调用参数", null)
                    } else {
                        val args = call.argument<Map<String, Any?>>("args") ?: emptyMap()
                        val ext = call.argument<String>("ext").orEmpty()
                        val configId = call.argument<String>("configId").orEmpty()
                        runAsync(result) {
                            mapOf("text" to callSpider(context, siteId, configId, jarPath, className, ext, method, args))
                        }
                    }
                }
                "release" -> {
                    val siteId = call.argument<String>("siteId").orEmpty()
                    runAsync(result) {
                        releaseSpider(siteId)
                        mapOf("released" to true)
                    }
                }
                "jarProxy" -> {
                    val configId = call.argument<String>("configId").orEmpty()
                    val jarPath = call.argument<String>("jarPath").orEmpty()
                    val className = call.argument<String>("className").orEmpty()
                    if (configId.isEmpty() || jarPath.isEmpty() || className.isEmpty()) {
                        result.error("jar_invalid", "缺少 jar 代理调用参数", null)
                    } else {
                        val param = call.argument<Map<String, Any?>>("param") ?: emptyMap()
                        val siteId = call.argument<String>("siteId").orEmpty()
                        val ext = call.argument<String>("ext").orEmpty()
                        runAsync(result) { jarProxy(context, siteId, configId, jarPath, className, ext, param) }
                    }
                }
                "setJarFingerprint" -> {
                    val enabled = call.argument<Boolean>("enabled") ?: true
                    com.github.catvod.net.OkHttp.setFingerprintEnabled(enabled)
                    result.success(mapOf("jarFingerprint" to enabled))
                }
                "setJarProxy" -> {
                    val url = call.argument<String>("url").orEmpty()
                    jarProxyUrl = url
                    var applied = 0
                    for (loader in loaders.values) {
                        if (applyJarProxyToLoader(loader)) applied++
                    }
                    result.success(
                        mapOf(
                            "jarProxy" to url,
                            "applied" to applied,
                            "loaders" to loaders.size,
                        ),
                    )
                }
                "enumerate" -> {
                    val jarPath = call.argument<String>("jarPath").orEmpty()
                    if (jarPath.isEmpty()) {
                        result.error("jar_invalid", "缺少待枚举的 jar 路径", null)
                    } else {
                        runAsync(result) { enumerateClasses(context, jarPath) }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> Map<String, Any?>) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.javaClass.simpleName
                mainHandler.post { result.error("jar_error", message, null) }
            }
        }
    }

    // 把出口代理交给某个 jar 加载器里的 ZakaHttp：ZakaCfg.setProxy 会同时
    // 写 SharedPreferences（之后 syncProxy 也能读到）并立即生效。
    // ZakaCfg 是包内可见类，只能反射调；不含 Zaka 类的 jar（纯 TVBox
    // 导入包）找不到类就返回 false，不报错、不挡调用方。
    private fun applyJarProxyToLoader(loader: ClassLoader): Boolean {
        return runCatching {
            val cfg = loader.loadClass("com.github.catvod.spider.ZakaCfg")
            val setProxy = cfg.getDeclaredMethod("setProxy", String::class.java)
            setProxy.isAccessible = true
            setProxy.invoke(null, jarProxyUrl)
            true
        }.getOrDefault(false)
    }

    private fun jarFile(context: Context, configId: String): File {
        val dir = File(context.filesDir, "jarbridge")
        if (!dir.exists()) dir.mkdirs()
        val safe = configId.replace(Regex("[^A-Za-z0-9._-]"), "_")
        return File(dir, "$safe.jar")
    }

    private fun md5Of(file: File): String {
        val digest = MessageDigest.getInstance("MD5")
        file.inputStream().use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read <= 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun ensureJar(context: Context, configId: String, url: String, expectedMd5: String): Map<String, Any?> {
        val lock = ensureLocks.computeIfAbsent(configId) { Any() }
        synchronized(lock) {
            return ensureJarLocked(context, configId, url, expectedMd5)
        }
    }

    private fun ensureJarLocked(context: Context, configId: String, url: String, expectedMd5: String): Map<String, Any?> {
        val target = jarFile(context, configId)
        val expected = expectedMd5.trim().lowercase()
        if (target.exists()) {
            val current = md5Of(target)
            if (expected.isEmpty() || current == expected) {
                JarFilePrep.sealForLoad(target)
                return mapOf("path" to target.absolutePath, "md5" to current)
            }
        }
        val temp = File(target.parentFile, target.name + ".part")
        if (temp.exists() && !temp.delete()) JarFilePrep.makeWritable(temp)
        if (url.startsWith("http://") || url.startsWith("https://")) {
            val connection = URL(url).openConnection() as HttpURLConnection
            connection.connectTimeout = 20000
            connection.readTimeout = 60000
            connection.instanceFollowRedirects = true
            connection.setRequestProperty("User-Agent", "okhttp/4.12.0")
            try {
                val code = connection.responseCode
                if (code !in 200..299) throw IllegalStateException("jar 下载失败：HTTP $code（$url）")
                connection.inputStream.use { input ->
                    FileOutputStream(temp).use { output -> input.copyTo(output) }
                }
            } finally {
                connection.disconnect()
            }
        } else {
            val source = File(url.removePrefix("file://"))
            if (!source.exists()) throw IllegalStateException("本地 jar 文件不存在：$url")
            source.inputStream().use { input ->
                FileOutputStream(temp).use { output -> input.copyTo(output) }
            }
        }
        val actual = md5Of(temp)
        if (expected.isNotEmpty() && actual != expected) {
            temp.delete()
            throw IllegalStateException("jar MD5 校验不符：配置要求 $expected，实际 $actual，已拒绝加载")
        }
        JarFilePrep.replaceTarget(temp, target)
        loaders.remove(configId)
        val stale = spiders.keys.filter { it.startsWith("jar:$configId:") }
        stale.forEach { releaseSpider(it) }
        return mapOf("path" to target.absolutePath, "md5" to actual)
    }

    private fun isLibraryClass(name: String): Boolean {
        val prefixes = listOf(
            "android.", "androidx.", "kotlin.", "kotlinx.", "java.", "javax.",
            "sun.", "dalvik.", "com.google.", "okhttp3.", "okio.", "retrofit2.",
            "com.squareup.", "org.json.", "com.fasterxml.", "org.apache.",
            "io.reactivex.", "com.bumptech.", "org.slf4j.", "org.jetbrains.",
        )
        return prefixes.any { name.startsWith(it) }
    }

    @Suppress("DEPRECATION")
    private fun enumerateClasses(context: Context, jarPath: String): Map<String, Any?> {
        val file = File(jarPath)
        if (!file.exists()) throw IllegalStateException("jar 文件不存在：$jarPath")
        JarFilePrep.sealForLoad(file)
        val optimized = File(context.codeCacheDir, "jarbridge_enum")
        if (!optimized.exists()) optimized.mkdirs()
        val names = mutableSetOf<String>()
        val dexEntries = try {
            java.util.jar.JarFile(file).use { jar ->
                jar.entries().asSequence()
                    .map { it.name }
                    .filter { it.endsWith(".dex") }
                    .toList()
            }
        } catch (error: Throwable) {
            emptyList<String>()
        }
        if (dexEntries.isNotEmpty()) {
            for ((index, dexName) in dexEntries.withIndex()) {
                val extracted = File(optimized, "${file.name}.$index.dex")
                try {
                    java.util.jar.JarFile(file).use { jar ->
                        jar.getInputStream(jar.getJarEntry(dexName)).use { input ->
                            extracted.outputStream().use { output -> input.copyTo(output) }
                        }
                    }
                    val dexFile = DexFile.loadDex(
                        extracted.absolutePath,
                        File(optimized, "${file.name}.$index.odex").absolutePath,
                        0
                    )
                    try {
                        val entries = dexFile.entries()
                        while (entries.hasMoreElements()) {
                            val name = entries.nextElement()
                            if (!name.contains('$') && !isLibraryClass(name)) {
                                names.add(name)
                            }
                        }
                    } finally {
                        dexFile.close()
                    }
                } catch (error: Throwable) {
                    // 单个 dex 读失败不影响其它 dex 的枚举。
                }
            }
        }
        if (names.isEmpty()) {
            val dexFile = DexFile.loadDex(
                jarPath,
                File(optimized, file.name + ".odex").absolutePath,
                0
            )
            try {
                val entries = dexFile.entries()
                while (entries.hasMoreElements()) {
                    val name = entries.nextElement()
                    if (!name.contains('$') && !isLibraryClass(name)) {
                        names.add(name)
                    }
                }
            } finally {
                dexFile.close()
            }
        }
        val loader = DexClassLoader(jarPath, optimized.absolutePath, null, context.classLoader)
        val dexIndex = DexSpiderIndex(file)
        val classes = names.sortedWith(
            compareBy<String> { !it.startsWith("com.github.catvod.spider.") }
                .thenBy { it },
        ).map { name ->
            var instantiable = false
            var reason = ""
            val type: Class<*>? = try {
                loader.loadClass(name)
            } catch (error: Throwable) {
                if (dexIndex.isSpider(name)) {
                    instantiable = true
                } else {
                    reason = "类加载失败：${error.message ?: error.javaClass.simpleName}"
                }
                null
            }
            if (type != null) {
                try {
                    when {
                        type.isInterface -> reason = "接口，不可实例化"
                        java.lang.reflect.Modifier.isAbstract(type.modifiers) ->
                            reason = "抽象类，不可实例化"
                        !com.github.catvod.crawler.Spider::class.java.isAssignableFrom(type) ->
                            reason = "未继承 catvod Spider 基类"
                        else -> {
                            type.getConstructor()
                            instantiable = true
                        }
                    }
                } catch (error: NoSuchMethodException) {
                    reason = "缺少公开无参构造方法"
                } catch (error: Throwable) {
                    reason = "类加载失败：${error.message ?: error.javaClass.simpleName}"
                }
            }
            mapOf("className" to name, "instantiable" to instantiable, "reason" to reason)
        }
        return mapOf("classes" to classes)
    }

    private class DexSpiderIndex(private val jarFile: File) {
        private data class DexClass(
            val superName: String?,
            val flags: Int,
            val hasPublicNoArgConstructor: Boolean,
        )

        private class DexReader(private val bytes: ByteArray) {
            var pos: Int = 0

            fun uleb(): Int {
                var result = 0
                var shift = 0
                while (true) {
                    val value = bytes[pos++].toInt() and 0xff
                    result = result or ((value and 0x7f) shl shift)
                    if (value and 0x80 == 0) break
                    shift += 7
                }
                return result
            }
        }

        private var cached: Map<String, DexClass>? = null

        fun isSpider(name: String): Boolean {
            val index = cached ?: load().also { cached = it }
            val target = index[name] ?: return false
            if (target.flags and 0x200 != 0 || target.flags and 0x400 != 0) return false
            if (!target.hasPublicNoArgConstructor) return false
            val seen = mutableSetOf<String>()
            var superName = target.superName
            while (superName != null && seen.add(superName)) {
                if (superName == "com.github.catvod.crawler.Spider") return true
                if (superName == "java.lang.Object") return false
                superName = index[superName]?.superName ?: return false
            }
            return false
        }

        private fun load(): Map<String, DexClass> {
            val result = mutableMapOf<String, DexClass>()
            try {
                java.util.jar.JarFile(jarFile).use { jar ->
                    val dexNames = jar.entries().asSequence()
                        .map { it.name }
                        .filter { it.endsWith(".dex") }
                        .toList()
                    for (dexName in dexNames) {
                        jar.getInputStream(jar.getJarEntry(dexName)).use { input ->
                            parseDex(input.readBytes(), result)
                        }
                    }
                }
            } catch (ignored: Throwable) {
            }
            return result
        }

        private fun parseDex(bytes: ByteArray, result: MutableMap<String, DexClass>) {
            try {
                if (bytes.size < 112) return
                val buffer = java.nio.ByteBuffer.wrap(bytes)
                    .order(java.nio.ByteOrder.LITTLE_ENDIAN)
                val stringIdsSize = buffer.getInt(56)
                val stringIdsOff = buffer.getInt(60)
                val typeIdsSize = buffer.getInt(64)
                val typeIdsOff = buffer.getInt(68)
                val protoIdsSize = buffer.getInt(72)
                val protoIdsOff = buffer.getInt(76)
                val methodIdsSize = buffer.getInt(88)
                val methodIdsOff = buffer.getInt(92)
                val classDefsSize = buffer.getInt(96)
                val classDefsOff = buffer.getInt(100)
                if (stringIdsSize < 0 || typeIdsSize < 0 || protoIdsSize < 0 ||
                    methodIdsSize < 0 || classDefsSize < 0
                ) return
                val strings = ArrayList<String>(stringIdsSize)
                for (i in 0 until stringIdsSize) {
                    strings.add(readDexString(bytes, buffer.getInt(stringIdsOff + i * 4)))
                }
                val types = ArrayList<String>(typeIdsSize)
                for (i in 0 until typeIdsSize) {
                    val stringIndex = buffer.getInt(typeIdsOff + i * 4)
                    types.add(if (stringIndex in strings.indices) strings[stringIndex] else "")
                }
                val methodNames = ArrayList<String>(methodIdsSize)
                val methodProtos = ArrayList<Int>(methodIdsSize)
                for (i in 0 until methodIdsSize) {
                    val base = methodIdsOff + i * 8
                    val nameIndex = buffer.getInt(base + 4)
                    methodNames.add(if (nameIndex in strings.indices) strings[nameIndex] else "")
                    methodProtos.add(buffer.getShort(base + 2).toInt() and 0xffff)
                }
                for (i in 0 until classDefsSize) {
                    try {
                        val base = classDefsOff + i * 32
                        val classIndex = buffer.getInt(base)
                        val flags = buffer.getInt(base + 4)
                        val superIndex = buffer.getInt(base + 8)
                        val classDataOff = buffer.getInt(base + 24)
                        val className = descriptorToName(
                            if (classIndex in types.indices) types[classIndex] else "",
                        )
                        if (className.isEmpty()) continue
                        var hasPublicNoArgConstructor = false
                        if (classDataOff > 0 && classDataOff < bytes.size) {
                            hasPublicNoArgConstructor = hasPublicNoArgConstructor(
                                bytes,
                                classDataOff,
                                methodNames,
                                methodProtos,
                                buffer,
                                protoIdsOff,
                                protoIdsSize,
                            )
                        }
                        val superName = if (superIndex == -1) {
                            null
                        } else {
                            descriptorToName(
                                if (superIndex in types.indices) types[superIndex] else "",
                            )
                        }
                        result[className] = DexClass(superName, flags, hasPublicNoArgConstructor)
                    } catch (ignored: Throwable) {
                    }
                }
            } catch (ignored: Throwable) {
            }
        }

        private fun hasPublicNoArgConstructor(
            bytes: ByteArray,
            classDataOff: Int,
            methodNames: List<String>,
            methodProtos: List<Int>,
            buffer: java.nio.ByteBuffer,
            protoIdsOff: Int,
            protoIdsSize: Int,
        ): Boolean {
            val reader = DexReader(bytes)
            reader.pos = classDataOff
            val staticFields = reader.uleb()
            val instanceFields = reader.uleb()
            val directMethods = reader.uleb()
            reader.uleb()
            repeat(staticFields + instanceFields) {
                reader.uleb()
                reader.uleb()
            }
            var methodIndex = 0
            repeat(directMethods) {
                methodIndex += reader.uleb()
                val methodFlags = reader.uleb()
                reader.uleb()
                if (methodIndex in methodNames.indices &&
                    methodNames[methodIndex] == "<init>" &&
                    methodFlags and 0x1 != 0
                ) {
                    val protoIndex = methodProtos[methodIndex]
                    if (protoIndex in 0 until protoIdsSize) {
                        val parametersOff = buffer.getInt(protoIdsOff + protoIndex * 12 + 8)
                        if (parametersOff == 0) return true
                        if (parametersOff > 0 && parametersOff + 4 <= bytes.size &&
                            buffer.getInt(parametersOff) == 0
                        ) return true
                    }
                }
            }
            return false
        }

        private fun readDexString(bytes: ByteArray, dataOff: Int): String {
            if (dataOff < 0 || dataOff >= bytes.size) return ""
            val reader = DexReader(bytes)
            reader.pos = dataOff
            reader.uleb()
            val start = reader.pos
            var end = start
            while (end < bytes.size && bytes[end].toInt() != 0) end++
            return String(bytes, start, end - start, java.nio.charset.StandardCharsets.UTF_8)
        }

        private fun descriptorToName(descriptor: String): String {
            if (descriptor.length < 2 || !descriptor.startsWith("L") ||
                !descriptor.endsWith(";")
            ) return ""
            return descriptor.substring(1, descriptor.length - 1).replace('/', '.')
        }
    }

    private fun loaderFor(context: Context, configId: String, jarPath: String): DexClassLoader {
        return loaders.computeIfAbsent(configId) {
            JarFilePrep.sealForLoad(File(jarPath))
            val optimized = File(context.codeCacheDir, "jarbridge_$configId")
            if (!optimized.exists()) optimized.mkdirs()
            DexClassLoader(jarPath, optimized.absolutePath, null, context.classLoader)
        }
    }

    private fun spiderFor(context: Context, siteId: String, configId: String, jarPath: String, className: String, ext: String): Any {
        spiders[siteId]?.let { return it }
        synchronized(spiders) {
            spiders[siteId]?.let { return it }
            val loader = loaderFor(context, configId, jarPath)
            if (jarProxyUrl.isNotEmpty()) {
                applyJarProxyToLoader(loader)
            }
            val type = try {
                loader.loadClass(className)
            } catch (error: ClassNotFoundException) {
                loaders.remove(configId)
                runCatching {
                    File(context.codeCacheDir, "jarbridge_$configId").deleteRecursively()
                }
                val file = File(jarPath)
                val state = if (file.exists()) "存在，${file.length()} 字节" else "不存在"
                throw IllegalStateException("jar 中未找到站点类 $className，该配置的 api 与 spider 不匹配或 jar 不完整（jar 文件：$state）")
            } catch (error: LinkageError) {
                throw IllegalStateException("jar 类 $className 加载失败（可能依赖未提供的壳组件）：${error.message}")
            }
            val instance = try {
                type.getDeclaredConstructor().newInstance()
            } catch (error: Exception) {
                throw IllegalStateException("jar 站点类 $className 无法实例化：${error.cause?.message ?: error.message}")
            }
            try {
                val init = type.getMethod("init", Context::class.java, String::class.java)
                init.invoke(instance, context.applicationContext, ext)
            } catch (error: NoSuchMethodException) {
                try {
                    type.getMethod("init", Context::class.java).invoke(instance, context.applicationContext)
                } catch (ignored: NoSuchMethodException) {
                }
            } catch (error: InvocationTargetException) {
                throw IllegalStateException("jar 站点 $className 初始化失败：${error.targetException?.message ?: error.message}")
            }
            spiders[siteId] = instance
            initialized.add(siteId)
            if (instance is com.github.catvod.crawler.Spider) {
                Init.registerSpider(className, instance)
            }
            return instance
        }
    }

    private fun releaseSpider(siteId: String) {
        val instance = spiders.remove(siteId) ?: return
        initialized.remove(siteId)
        runCatching {
            instance.javaClass.getMethod("destroy").invoke(instance)
        }
        if (instance is com.github.catvod.crawler.Spider) {
            Init.unregisterSpider(instance.javaClass.name)
        }
    }

    private fun callSpider(
        context: Context,
        siteId: String,
        configId: String,
        jarPath: String,
        className: String,
        ext: String,
        method: String,
        args: Map<String, Any?>
    ): String {
        val spider = spiderFor(context, siteId, configId, jarPath, className, ext)
        val type = spider.javaClass
        fun text(value: Any?): String = value as? String ?: ""
        return try {
            when (method) {
                "homeContent" -> text(
                    type.getMethod("homeContent", Boolean::class.javaPrimitiveType)
                        .invoke(spider, args["filter"] as? Boolean ?: true)
                )
                "homeVideoContent" -> text(type.getMethod("homeVideoContent").invoke(spider))
                "categoryContent" -> {
                    val extend = HashMap<String, String>()
                    (args["extend"] as? Map<*, *>)?.forEach { (key, value) ->
                        if (key != null && value != null) extend[key.toString()] = value.toString()
                    }
                    text(
                        type.getMethod(
                            "categoryContent",
                            String::class.java,
                            String::class.java,
                            Boolean::class.javaPrimitiveType,
                            HashMap::class.java
                        ).invoke(
                            spider,
                            args["tid"] as? String ?: "",
                            args["pg"] as? String ?: "1",
                            args["filter"] as? Boolean ?: true,
                            extend
                        )
                    )
                }
                "detailContent" -> {
                    val ids = (args["ids"] as? List<*>)?.map { it.toString() } ?: emptyList()
                    text(
                        type.getMethod("detailContent", List::class.java)
                            .invoke(spider, ids)
                    )
                }
                "searchContent" -> {
                    val key = args["key"] as? String ?: ""
                    val quick = args["quick"] as? Boolean ?: false
                    val pg = args["pg"] as? String ?: "1"
                    val paged = try {
                        type.getMethod(
                            "searchContent",
                            String::class.java,
                            Boolean::class.javaPrimitiveType,
                            String::class.java
                        )
                    } catch (ignored: NoSuchMethodException) {
                        null
                    }
                    if (paged != null) {
                        text(paged.invoke(spider, key, quick, pg))
                    } else {
                        text(
                            type.getMethod("searchContent", String::class.java, Boolean::class.javaPrimitiveType)
                                .invoke(spider, key, quick)
                        )
                    }
                }
                "playerContent" -> {
                    val vipFlags = (args["vipFlags"] as? List<*>)?.map { it.toString() } ?: emptyList<String>()
                    text(
                        type.getMethod(
                            "playerContent",
                            String::class.java,
                            String::class.java,
                            List::class.java
                        ).invoke(spider, args["flag"] as? String ?: "", args["id"] as? String ?: "", vipFlags)
                    )
                }
                else -> throw IllegalStateException("jar 桥不支持的方法：$method")
            }
        } catch (error: InvocationTargetException) {
            val cause = error.targetException
            throw IllegalStateException("jar 站点 $className.$method 执行失败：${cause?.message ?: cause?.javaClass?.simpleName ?: "未知错误"}")
        } catch (error: NoSuchMethodException) {
            throw IllegalStateException("jar 站点 $className 未实现方法 $method（与 catvod Spider 契约不符）")
        }
    }

    /// 本地代理：CatVod 的 `Spider.proxy(Map)` 是实例方法（jar 里 112 个
    /// Zaka 蜘蛛全是实例 proxy，没有一个是静态的），所以这里复用
    /// [spiderFor] 的缓存实例调它；此前要求 proxy 必须是静态方法，
    /// 每个 jar 站的本地代理都直接抛错，播放器经本地代理取流时一律
    /// 收到 502（表现为「播放服务暂时不可用」）。`siteId` 为空时退
    /// 回 `jarProxy:<configId>:<类名>` 作实例缓存键，`ext` 缺省为空。
    private fun jarProxy(
        context: Context,
        siteId: String,
        configId: String,
        jarPath: String,
        className: String,
        ext: String,
        param: Map<String, Any?>
    ): Map<String, Any?> {
        // siteId 在时严格按它取缓存实例（同类不同站可能 ext 不同，
        // 不能串）；siteId 为空时先复用已缓存的同类实例，没有才新建。
        val spider = if (siteId.isNotEmpty()) {
            spiderFor(context, siteId, configId, jarPath, className, ext)
        } else {
            spiders.values.firstOrNull { it.javaClass.name == className }
                ?: spiderFor(
                    context,
                    "jarProxy:$configId:$className",
                    configId,
                    jarPath,
                    className,
                    ext,
                )
        }
        val type = spider.javaClass
        val args = HashMap<String, String>()
        param.forEach { (key, value) ->
            if (key != null && value != null) args[key.toString()] = value.toString()
        }
        val returned = try {
            type.getMethod("proxy", Map::class.java).invoke(spider, args)
        } catch (error: NoSuchMethodException) {
            throw IllegalStateException("jar 类 $className 未实现 proxy 方法，无法处理本地代理请求")
        } catch (error: InvocationTargetException) {
            throw IllegalStateException("jar 类 $className.proxy 执行失败：${error.targetException?.message ?: error.targetException?.javaClass?.simpleName ?: "未知错误"}")
        }
        val array = returned as? Array<*>
            ?: throw IllegalStateException("jar 类 $className.proxy 返回格式错误：需要 [状态码、类型、字节流] 三元组")
        if (array.size < 3) {
            throw IllegalStateException("jar 类 $className.proxy 返回格式错误：需要 [状态码、类型、字节流] 三元组")
        }
        val status = (array[0] as? Number)?.toInt() ?: 200
        val mime = array[1] as? String ?: "application/octet-stream"
        val body = when (val raw = array[2]) {
            is ByteArray -> raw
            is String -> raw.toByteArray(Charsets.UTF_8)
            is java.io.InputStream -> raw.use { it.readBytes() }
            else -> throw IllegalStateException("jar 类 $className.proxy 返回的字节流类型不受支持：${raw?.javaClass?.simpleName ?: "空"}")
        }
        return mapOf(
            "status" to status,
            "mime" to mime,
            "bodyBase64" to android.util.Base64.encodeToString(body, android.util.Base64.NO_WRAP),
        )
    }
}
