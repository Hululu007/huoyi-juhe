package com.fanrenxiuxianguanyingchuan

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * 软件内更新桥（通道 fqapp/appupdate，同步批 B8）：
 * appInfo 读本包版本名/版本号；installApk 把已下载并验过
 * SHA-256 的安装包经 FileProvider 交给系统安装器——没有
 * 「安装未知应用」权限时先跳系统设置页并回 install_permission，
 * 让用户授权后回来重点；openUrl 用系统浏览器打开发布页。
 */
class AppUpdatePlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/appupdate")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("no_context", "通道未附着到引擎", null)
            return
        }
        when (call.method) {
            "appInfo" -> {
                val info = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
                val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    info.longVersionCode
                } else {
                    @Suppress("DEPRECATION")
                    info.versionCode.toLong()
                }
                result.success(
                    mapOf(
                        "versionName" to (info.versionName ?: ""),
                        "versionCode" to code,
                    ),
                )
            }
            "installApk" -> installApk(ctx, call.argument<String>("path").orEmpty(), result)
            "openUrl" -> {
                val url = call.argument<String>("url").orEmpty()
                if (url.isEmpty()) {
                    result.success(false)
                    return
                }
                try {
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url)).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    ctx.startActivity(intent)
                    result.success(true)
                } catch (e: Exception) {
                    result.success(false)
                }
            }
            else -> result.notImplemented()
        }
    }

    private fun installApk(ctx: Context, path: String, result: MethodChannel.Result) {
        val file = File(path)
        if (path.isEmpty() || !file.exists()) {
            result.error("missing_apk", "安装包不存在，请重新下载", null)
            return
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            !ctx.packageManager.canRequestPackageInstalls()
        ) {
            val intent = Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:${ctx.packageName}"),
            ).apply { addFlags(Intent.FLAG_ACTIVITY_NEW_TASK) }
            try {
                ctx.startActivity(intent)
            } catch (e: Exception) {
                // 设置页打不开也回同一个错误码，Dart 侧文案已说明。
            }
            result.error(
                "install_permission",
                "请先允许本应用安装未知应用，然后回来重新点安装",
                null,
            )
            return
        }
        try {
            val uri = FileProvider.getUriForFile(
                ctx,
                "${ctx.packageName}.fileprovider",
                file,
            )
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(
                    Intent.FLAG_ACTIVITY_NEW_TASK or
                        Intent.FLAG_GRANT_READ_URI_PERMISSION,
                )
            }
            ctx.startActivity(intent)
            result.success(null)
        } catch (e: Exception) {
            result.error("install_failed", "调起系统安装器失败：${e.message}", null)
        }
    }
}
