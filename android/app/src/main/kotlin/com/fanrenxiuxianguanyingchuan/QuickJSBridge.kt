package com.fanrenxiuxianguanyingchuan

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import org.jsoup.Jsoup
import org.jsoup.nodes.Element

class QuickJSBridge {
    private val executor = Executors.newCachedThreadPool()
    private val mainHandler = Handler(Looper.getMainLooper())

    companion object {
        // 库缺失时不许炸启动：QuickJSBridge 在引擎装配时就实例化，
        // 这里抛 UnsatisfiedLinkError 会直接闪退。改为惰性加载：
        // 库在才能调 nativeEval，缺失时 eval 回 quickjs_unavailable、
        // status 如实报不可用，绝不在启动时抛。
        @Volatile
        private var nativeLoaded: Boolean? = null

        private fun ensureNativeLoaded(): Boolean {
            nativeLoaded?.let { return it }
            val loaded = try {
                System.loadLibrary("huoyi_quickjs")
                true
            } catch (error: Throwable) {
                false
            }
            nativeLoaded = loaded
            return loaded
        }

        private val httpClient: OkHttpClient by lazy {
            OkHttpClient.Builder()
                .connectTimeout(10, TimeUnit.SECONDS)
                .readTimeout(15, TimeUnit.SECONDS)
                .build()
        }

        private const val USER_AGENT =
            "Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 Chrome/120.0 Mobile Safari/537.36"

        @JvmStatic
        fun fetch(url: String): String? {
            return try {
                val request = Request.Builder().url(url)
                    .header("User-Agent", USER_AGENT)
                    .build()
                httpClient.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) null else response.body?.string()
                }
            } catch (error: Throwable) {
                null
            }
        }

        @JvmStatic
        fun requestJson(arg: String): String {
            return try {
                val json = JSONObject(arg)
                val url = json.optString("url")
                if (url.isEmpty()) return ""
                val method = json.optString("method", "GET").ifEmpty { "GET" }.uppercase()
                val headers = json.optJSONObject("headers")
                val bodyText = json.optString("body", "")
                val builder = Request.Builder().url(url)
                    .header("User-Agent", USER_AGENT)
                    .header("Accept", "*/*")
                if (headers != null) {
                    for (key in headers.keys()) {
                        builder.header(key, headers.optString(key))
                    }
                }
                val request = if (method == "GET" || method == "HEAD") {
                    builder.method(method, null).build()
                } else {
                    val body = bodyText.toRequestBody("application/x-www-form-urlencoded".toMediaTypeOrNull())
                    builder.method(method, body).build()
                }
                httpClient.newCall(request).execute().use { response ->
                    val bytes = response.body?.bytes() ?: return ""
                    val text = bytes.take(8 * 1024 * 1024).toByteArray().toString(Charsets.UTF_8)
                    text
                }
            } catch (error: Throwable) {
                ""
            }
        }

        private fun splitRule(rule: String): Pair<String, String> {
            val parts = rule.split("&&")
            if (parts.size == 1) return parts[0].trim() to "Text"
            val last = parts.last().trim()
            return parts.dropLast(1).joinToString("&&").trim() to last
        }

        private fun extract(element: Element, attr: String): String {
            return when (attr.lowercase()) {
                "", "text" -> element.text()
                "html", "outerhtml", "outer" -> element.outerHtml()
                "innerhtml", "inner" -> element.html()
                else -> element.attr(attr)
            }
        }

        private fun parseHtmlArgs(arg: String): Triple<String, String, String> {
            val json = JSONObject(arg)
            val html = json.optString("html")
            val selector = json.optString("selector")
            val attr = json.optString("attr")
            return Triple(html, selector, attr)
        }

        @JvmStatic
        fun pdfaJson(arg: String): String {
            return try {
                val (html, selector, _) = parseHtmlArgs(arg)
                val (css, _) = splitRule(selector)
                val elements = Jsoup.parse(html).select(css)
                val array = JSONArray()
                for (element in elements) array.put(element.outerHtml())
                array.toString()
            } catch (error: Throwable) {
                "[]"
            }
        }

        @JvmStatic
        fun pdfhJson(arg: String): String {
            return try {
                val (html, selector, _) = parseHtmlArgs(arg)
                val (css, attr) = splitRule(selector)
                val first = Jsoup.parse(html).select(css).firstOrNull() ?: return ""
                extract(first, attr)
            } catch (error: Throwable) {
                ""
            }
        }

        @JvmStatic
        fun pdJson(arg: String): String {
            return try {
                val (html, selector, attrArg) = parseHtmlArgs(arg)
                val (css, attr) = if (attrArg.isNotEmpty()) {
                    selector to attrArg
                } else {
                    splitRule(selector)
                }
                val first = Jsoup.parse(html).select(css).firstOrNull() ?: return ""
                extract(first, attr)
            } catch (error: Throwable) {
                ""
            }
        }
    }

    fun register(messenger: io.flutter.plugin.common.BinaryMessenger): MethodChannel {
        val channel = MethodChannel(messenger, "juhe/quickjs")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "eval" -> {
                    val script = call.argument<String>("script")
                    if (script == null) {
                        result.error("invalid_argument", "缺少 JS 脚本", null)
                    } else {
                        val timeout = call.argument<Int>("timeoutMs") ?: 10000
                        executor.execute {
                            try {
                                if (!ensureNativeLoaded()) {
                                    mainHandler.post {
                                        result.error("quickjs_unavailable", "JS 引擎不可用", null)
                                    }
                                } else {
                                    val value = nativeEval(script, timeout)
                                    mainHandler.post { result.success(value) }
                                }
                            } catch (error: Throwable) {
                                val message = error.message ?: error.toString()
                                mainHandler.post { result.error("quickjs_error", message, null) }
                            }
                        }
                    }
                }
                "status" -> result.success(
                    if (ensureNativeLoaded()) {
                        "{\"available\":true,\"engine\":\"QuickJS 2024-01-13\"}"
                    } else {
                        "{\"available\":false,\"engine\":\"\"}"
                    }
                )
                else -> result.notImplemented()
            }
        }
        return channel
    }

    fun shutdown() {
        executor.shutdownNow()
    }

    private external fun nativeEval(script: String, timeoutMs: Int): String
}
