package com.fqapp.fqapp

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.Settings
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * 手机根目录公开文件夹通道（火蚁聚合文件夹的权限与根目录）。
 *
 * Android 11+ 上根目录写权限属于全部文件访问：应用不能静默拿到，
 * 只能打开系统设置页请用户亲手开一次。文件夹本身的创建由 Dart 侧
 * Directory.create 自动做。
 */
class PublicFolderPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private var context: Context? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/public_folder")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        context = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "publicRoot" -> {
                result.success(Environment.getExternalStorageDirectory().absolutePath)
            }
            "hasAllFilesAccess" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    result.success(Environment.isExternalStorageManager())
                } else {
                    result.success(true)
                }
            }
            "requestAllFilesAccess" -> {
                val ctx = context
                if (ctx == null) {
                    result.error("no_context", "通道未附着到引擎", null)
                    return
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val intent = Intent(
                        Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                        Uri.parse("package:${ctx.packageName}"),
                    ).apply {
                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    }
                    ctx.startActivity(intent)
                }
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
