package com.fqapp.fqapp

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors

class PyBridge(context: Context) {
    private val appContext = context.applicationContext
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger): MethodChannel {
        val channel = MethodChannel(messenger, "juhe/pybridge")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "status" -> runAsync(result) { status() }
                "validate" -> {
                    val source = call.argument<String>("source")
                    if (source == null) {
                        result.error("invalid_argument", "缺少蜘蛛源码", null)
                    } else {
                        runAsync(result) { validate(source) }
                    }
                }
                "call" -> {
                    val path = call.argument<String>("path")
                    val request = call.argument<String>("request")
                    if (path == null || request == null) {
                        result.error("invalid_argument", "缺少蜘蛛路径或请求", null)
                    } else {
                        runAsync(result) { dispatch(path, request) }
                    }
                }
                "dispose" -> {
                    val path = call.argument<String>("path")
                    if (path == null) {
                        result.error("invalid_argument", "缺少蜘蛛路径", null)
                    } else {
                        runAsync(result) { dispose(path) }
                    }
                }
                "disposeAll" -> runAsync(result) { disposeAll() }
                else -> result.notImplemented()
            }
        }
        return channel
    }

    private fun runAsync(result: MethodChannel.Result, block: () -> String) {
        executor.execute {
            try {
                val value = block()
                mainHandler.post { result.success(value) }
            } catch (error: Throwable) {
                val message = error.message ?: error.toString()
                mainHandler.post { result.error("py_runtime_error", message, null) }
            }
        }
    }

    private fun python(): Python {
        if (!Python.isStarted()) {
            Python.start(AndroidPlatform(appContext))
        }
        return Python.getInstance()
    }

    private fun host() = python().getModule("py_spider_host")

    private fun status(): String {
        val py = python()
        val version = py.getModule("sys").get("version")?.toString()?.lineSequence()?.firstOrNull() ?: ""
        return """{"available":true,"python":${jsonString(version)}}"""
    }

    private fun validate(source: String): String =
        host().callAttr("validate_source_json", source).toString()

    private fun dispatch(path: String, request: String): String =
        host().callAttr("handle", path, request).toString()

    private fun dispose(path: String): String =
        host().callAttr("dispose", path).toString()

    private fun disposeAll(): String =
        host().callAttr("dispose_all").toString()

    private fun jsonString(value: String): String {
        val escaped = value
            .replace("\\", "\\\\")
            .replace("\"", "\\\"")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
        return "\"$escaped\""
    }

    fun shutdown() {
        executor.shutdownNow()
    }
}
