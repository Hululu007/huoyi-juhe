package com.fanrenxiuxianguanyingchuan

import android.content.Context
import android.net.ConnectivityManager
import android.net.ProxyInfo
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 系统代理读取通道（`fqapp/system-proxy`）：读手机的系统代理（用户 VPN /
 * 梯子设的代理），交给 Dart 侧转给 Rust 核心当出口代理用。
 *
 * Rust 核心的 reqwest 在手机上读不到系统代理（只读环境变量，App 进程里
 * 没有），直连会被墙拦；这条通道就是 Dart 侧的代理来源。
 *
 * 只用公开 API：[ConnectivityManager.getDefaultProxy]。注意两处不能用的：
 * `getProxyForNetwork` 与 `ProxyInfo.getType` 都是隐藏 API（不在公开的
 * android.jar 里），写了编译不过，所以不用它们：
 * - 不按活动网络取，只取默认代理；
 * - 类型固定报 `http`：Android 系统代理（设置里的全局代理 / Wi-Fi 代理）
 *   本来就只支持 HTTP 代理，SOCKS 设不成系统代理，报 `http` 就是如实。
 * PAC 代理（只有 pacFileUrl、没有 host/port）原生侧解不了，直接回 null，
 * Dart 侧按无代理处理（核心回直连）。
 *
 * 任何异常都回 null，不抛、不闪退。
 */
class SystemProxyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != METHOD_GET_PROXY) {
            result.notImplemented()
            return
        }
        result.success(readProxy())
    }

    private fun readProxy(): Map<String, Any>? {
        return try {
            val ctx = context ?: return null
            val manager =
                ctx.getSystemService(Context.CONNECTIVITY_SERVICE)
                    as? ConnectivityManager ?: return null
            val info: ProxyInfo = manager.defaultProxy ?: return null
            val host = info.host?.trim().orEmpty()
            val port = info.port
            // 无 host 或端口非法（0 / 负数）都当无代理：PAC 代理走这里，
            // host 为空，直接回 null。
            if (host.isEmpty() || port <= 0) return null
            mapOf(
                "host" to host,
                "port" to port,
                // 见类注释：系统代理只支持 HTTP，类型如实报 http。
                "type" to "http",
            )
        } catch (_: Exception) {
            null
        }
    }

    companion object {
        private const val CHANNEL = "fqapp/system-proxy"
        private const val METHOD_GET_PROXY = "getProxy"
    }
}
