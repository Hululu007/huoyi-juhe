package com.fanrenxiuxianguanyingchuan

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.DocumentsContract
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.util.concurrent.Executors

/**
 * 演员库存储授权通道（fqapp/actress_storage）：系统文件/目录选择器
 * （SAF）授予的持久读权限，是全部文件访问权限之外的第二条授权路
 * ——安卓 10–16 通吃、不需要 MANAGE_EXTERNAL_STORAGE。
 *
 * - pickTree：ACTION_OPEN_DOCUMENT_TREE 选目录（如 MYTV），拿持久
 *   读授权后 Dart 侧按 listDbFiles 的清单把 .db 镜像进应用私有
 *   目录再开（源文件只读不写；镜像在私有目录也绕开 WAL 库只读
 *   目录建不出 -shm 的坑）。
 * - pickFile：ACTION_OPEN_DOCUMENT 选单个 .db 文件，同上。
 * - listDbFiles：递归列目录树下的 .db（深度/数量有上限）。
 * - copyDocument：后台线程流式拷贝，临时文件 + 改名落定，半截
 *   文件不算数；大库（约 850MB）不堵平台线程。
 * - hasGrant：查持久授权还在不在（用户在系统里撤销/换机恢复丢
 *   授权时 Dart 要能发现并重新引导）。
 *
 * 全部意图启动都 try/catch：鸿蒙卓易通容器里选择器/设置页可能
 * 没有承接方，失败回明确错误给 Dart 显示提示，绝不抛进通道。
 */
class ActressStoragePlugin : FlutterPlugin, ActivityAware,
    MethodChannel.MethodCallHandler, PluginRegistry.ActivityResultListener {

    companion object {
        private const val REQ_PICK_TREE = 0xAC01
        private const val REQ_PICK_FILE = 0xAC02
        private const val MAX_DEPTH = 4
        private const val MAX_FILES = 128
    }

    private var channel: MethodChannel? = null
    private var context: Context? = null
    private var activity: Activity? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingResult: MethodChannel.Result? = null
    private var pendingRequestCode: Int = 0
    private val ioExecutor = Executors.newSingleThreadExecutor()
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "fqapp/actress_storage")
        channel?.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel?.setMethodCallHandler(null)
        channel = null
        context = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        activityBinding = binding
        binding.addActivityResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        onAttachedToActivity(binding)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(this)
        activityBinding = null
        activity = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickTree" -> launchPicker(tree = true, result)
            "pickFile" -> launchPicker(tree = false, result)
            "listDbFiles" -> {
                val treeUri = call.argument<String>("treeUri")
                if (treeUri.isNullOrEmpty()) {
                    result.error("bad_args", "treeUri 为空", null)
                    return
                }
                listDbFiles(treeUri, result)
            }
            "statDocument" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrEmpty()) {
                    result.error("bad_args", "uri 为空", null)
                    return
                }
                statDocument(uri, result)
            }
            "copyDocument" -> {
                val uri = call.argument<String>("uri")
                val destPath = call.argument<String>("destPath")
                if (uri.isNullOrEmpty() || destPath.isNullOrEmpty()) {
                    result.error("bad_args", "uri/destPath 为空", null)
                    return
                }
                copyDocument(uri, destPath, result)
            }
            "hasGrant" -> {
                val uri = call.argument<String>("uri")
                if (uri.isNullOrEmpty()) {
                    result.success(false)
                    return
                }
                val ctx = context
                if (ctx == null) {
                    result.success(false)
                    return
                }
                val granted = ctx.contentResolver.persistedUriPermissions.any {
                    it.uri.toString() == uri && it.isReadPermission
                }
                result.success(granted)
            }
            else -> result.notImplemented()
        }
    }

    private fun launchPicker(tree: Boolean, result: MethodChannel.Result) {
        val act = activity
        if (act == null) {
            result.error("no_activity", "没有可用的 Activity 打不开系统选择器", null)
            return
        }
        if (pendingResult != null) {
            result.error("busy", "上一个选择器还没关", null)
            return
        }
        val intent = if (tree) {
            Intent(Intent.ACTION_OPEN_DOCUMENT_TREE)
        } else {
            Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
                addCategory(Intent.CATEGORY_OPENABLE)
                type = "*/*"
            }
        }
        intent.addFlags(
            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                Intent.FLAG_GRANT_PERSISTABLE_URI_PERMISSION,
        )
        val requestCode = if (tree) REQ_PICK_TREE else REQ_PICK_FILE
        try {
            act.startActivityForResult(intent, requestCode)
        } catch (e: Exception) {
            result.error("unavailable", "系统选择器打不开：${e.message}", null)
            return
        }
        pendingResult = result
        pendingRequestCode = requestCode
    }

    override fun onActivityResult(
        requestCode: Int,
        resultCode: Int,
        data: Intent?,
    ): Boolean {
        if (requestCode != REQ_PICK_TREE && requestCode != REQ_PICK_FILE) {
            return false
        }
        val result = pendingResult ?: return true
        pendingResult = null
        val tree = requestCode == REQ_PICK_TREE
        val uri = data?.data
        if (resultCode != Activity.RESULT_OK || uri == null) {
            // 用户取消：回 null，Dart 按「没选」处理，不算失败。
            result.success(null)
            return true
        }
        val ctx = context
        if (ctx != null) {
            val takeFlags = (data.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION)
            try {
                ctx.contentResolver.takePersistableUriPermission(uri, takeFlags)
            } catch (e: Exception) {
                // 容器/厂商不给持久授权：当次授权仍可用（Dart 会立刻
                // 镜像），只是重启后可能要重选，Dart 侧 hasGrant 会
                // 发现并重新引导，不在这里报错。
            }
        }
        if (tree) {
            val name = documentName(uri, isTree = true)
            result.success(
                mapOf("uri" to uri.toString(), "name" to (name ?: "")),
            )
        } else {
            val stat = queryDocument(uri)
            result.success(
                mapOf(
                    "uri" to uri.toString(),
                    "name" to (stat?.get("name") ?: ""),
                    "size" to (stat?.get("size") ?: -1L),
                    "lastModified" to (stat?.get("lastModified") ?: 0L),
                ),
            )
        }
        return true
    }

    /// 文档显示名（目录授权给的是树 URI，要取树根文档名）。
    private fun documentName(uri: Uri, isTree: Boolean): String? {
        val ctx = context ?: return null
        val docUri = if (isTree) {
            try {
                DocumentsContract.buildDocumentUriUsingTree(
                    uri,
                    DocumentsContract.getTreeDocumentId(uri),
                )
            } catch (e: Exception) {
                uri
            }
        } else {
            uri
        }
        return queryDocument(docUri)?.get("name") as? String
    }

    /// 查单个文档的 name/size/lastModified；查不到回 null。
    private fun queryDocument(docUri: Uri): Map<String, Any?>? {
        val ctx = context ?: return null
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        var cursor: Cursor? = null
        return try {
            cursor = ctx.contentResolver.query(docUri, projection, null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                mapOf(
                    "name" to cursor.stringOrNull(0),
                    "size" to cursor.longOrDefault(1, -1L),
                    "lastModified" to cursor.longOrDefault(2, 0L),
                )
            } else {
                null
            }
        } catch (e: Exception) {
            null
        } finally {
            cursor?.close()
        }
    }

    private fun statDocument(uriText: String, result: MethodChannel.Result) {
        val uri = Uri.parse(uriText)
        val stat = queryDocument(uri)
        if (stat == null) {
            result.success(null)
        } else {
            result.success(
                mapOf(
                    "exists" to true,
                    "name" to (stat["name"] ?: ""),
                    "size" to (stat["size"] ?: -1L),
                    "lastModified" to (stat["lastModified"] ?: 0L),
                ),
            )
        }
    }

    private fun listDbFiles(treeUriText: String, result: MethodChannel.Result) {
        val ctx = context
        if (ctx == null) {
            result.error("no_context", "通道未附着到引擎", null)
            return
        }
        ioExecutor.execute {
            val out = mutableListOf<Map<String, Any?>>()
            try {
                val treeUri = Uri.parse(treeUriText)
                val rootDocId = DocumentsContract.getTreeDocumentId(treeUri)
                walkTree(ctx, treeUri, rootDocId, "", 0, out)
                mainHandler.post { result.success(out) }
            } catch (e: Exception) {
                mainHandler.post {
                    result.error("list_failed", "列目录失败：${e.message}", null)
                }
            }
        }
    }

    private fun walkTree(
        ctx: Context,
        treeUri: Uri,
        parentDocId: String,
        relPrefix: String,
        depth: Int,
        out: MutableList<Map<String, Any?>>,
    ) {
        if (depth > MAX_DEPTH || out.size >= MAX_FILES) return
        val childrenUri = DocumentsContract.buildChildDocumentsUriUsingTree(
            treeUri,
            parentDocId,
        )
        val projection = arrayOf(
            DocumentsContract.Document.COLUMN_DOCUMENT_ID,
            DocumentsContract.Document.COLUMN_DISPLAY_NAME,
            DocumentsContract.Document.COLUMN_MIME_TYPE,
            DocumentsContract.Document.COLUMN_SIZE,
            DocumentsContract.Document.COLUMN_LAST_MODIFIED,
        )
        var cursor: Cursor? = null
        try {
            cursor = ctx.contentResolver.query(childrenUri, projection, null, null, null)
                ?: return
            while (cursor.moveToNext() && out.size < MAX_FILES) {
                val docId = cursor.stringOrNull(0) ?: continue
                val name = cursor.stringOrNull(1) ?: continue
                val mime = cursor.stringOrNull(2)
                if (mime == DocumentsContract.Document.MIME_TYPE_DIR) {
                    walkTree(ctx, treeUri, docId, "$relPrefix$name/", depth + 1, out)
                } else if (name.lowercase().endsWith(".db")) {
                    val docUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, docId)
                    out.add(
                        mapOf(
                            "uri" to docUri.toString(),
                            "name" to name,
                            "relPath" to "$relPrefix$name",
                            "size" to cursor.longOrDefault(3, -1L),
                            "lastModified" to cursor.longOrDefault(4, 0L),
                        ),
                    )
                }
            }
        } catch (e: Exception) {
            // 某一层列不出来（授权被收回/提供方异常）：已收集的照常
            // 返回，不整单失败。
        } finally {
            cursor?.close()
        }
    }

    private fun copyDocument(
        uriText: String,
        destPath: String,
        result: MethodChannel.Result,
    ) {
        val ctx = context
        if (ctx == null) {
            result.error("no_context", "通道未附着到引擎", null)
            return
        }
        ioExecutor.execute {
            val dest = File(destPath)
            val tmp = File("$destPath.part")
            try {
                dest.parentFile?.mkdirs()
                val input = ctx.contentResolver.openInputStream(Uri.parse(uriText))
                    ?: throw IOException("打不开文档流")
                var total = 0L
                input.use { ins ->
                    FileOutputStream(tmp).use { out ->
                        val buffer = ByteArray(256 * 1024)
                        while (true) {
                            val n = ins.read(buffer)
                            if (n < 0) break
                            out.write(buffer, 0, n)
                            total += n
                        }
                        out.fd.sync()
                    }
                }
                if (dest.exists() && !dest.delete()) {
                    throw IOException("旧镜像删不掉：${dest.path}")
                }
                if (!tmp.renameTo(dest)) {
                    tmp.copyTo(dest, overwrite = true)
                    tmp.delete()
                }
                mainHandler.post { result.success(total) }
            } catch (e: Exception) {
                tmp.delete()
                mainHandler.post {
                    result.error("copy_failed", "拷贝失败：${e.message}", null)
                }
            }
        }
    }

    private fun Cursor.stringOrNull(index: Int): String? =
        if (isNull(index)) null else getString(index)

    private fun Cursor.longOrDefault(index: Int, fallback: Long): Long =
        if (isNull(index)) fallback else getLong(index)
}
