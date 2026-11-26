package com.fanrenxiuxianguanyingchuan

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * bytevc2 转码验证插件（43 轮验证批）：只做四项真机探测，不接播放链。
 *
 * 转码器是打了 BVC2 解码补丁的 FFmpeg 可执行文件，改名 libbvc2transcode.so
 * 放 jniLibs（见 third_party/bytevc2/）。它不是 JNI 库：靠安装期把原生库
 * 解包落盘（build.gradle.kts 的 useLegacyPackaging）后直接 exec，exec 被拒
 * 时用 /system/bin/linker64 拉起。探测逻辑镜像上游 fqapp 的
 * Bytevc2TranscodePlugin.available / exec 形态，按本包包名与验证用途改写。
 *
 * 通道 fanrenxiuxian/bytevc2verify：
 * - inspect   -> 转码器在 nativeLibraryDir 的落盘情况（路径/存在/大小/可执行）
 * - runDirect -> 直接 exec 转码器跑 -version，回退出码与输出尾段
 * - runLinker -> 用 linker64 拉起转码器跑 -version，回退出码与输出尾段
 * - transcode -> upstream 同款转码参数跑一次真转码（验证页第 4 项用）
 */
class Bytevc2VerifyPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context
    private val worker =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "bytevc2-verify")
        }
    private val main = Handler(Looper.getMainLooper())

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        worker.shutdownNow()
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "inspect" -> result.success(inspect())
            "runDirect" -> runVersion(result, useLinker = false)
            "runLinker" -> runVersion(result, useLinker = true)
            "transcode" -> transcode(call, result)
            else -> result.notImplemented()
        }
    }

    private fun binaryFile(): File =
        File(context.applicationInfo.nativeLibraryDir, BINARY)

    private fun inspect(): Map<String, Any?> {
        val binary = binaryFile()
        val exists = binary.isFile
        return mapOf(
            "nativeLibraryDir" to context.applicationInfo.nativeLibraryDir,
            "path" to binary.absolutePath,
            "exists" to exists,
            "size" to if (exists) binary.length() else 0L,
            "canExecute" to if (exists) binary.canExecute() else false,
        )
    }

    private fun executable(): File? {
        val binary = binaryFile()
        if (!binary.isFile) return null
        if (!binary.canExecute()) binary.setExecutable(true, false)
        return binary
    }

    /** 跑 -version 取原文输出：direct 直接 exec，linker 经 /system/bin/linker64。 */
    private fun runVersion(result: MethodChannel.Result, useLinker: Boolean) {
        val binary = executable()
        if (binary == null) {
            result.success(
                mapOf(
                    "ok" to false,
                    "exitCode" to -1,
                    "output" to "转码器文件不存在：${binaryFile().absolutePath}",
                ),
            )
            return
        }
        worker.execute {
            val outcome: Map<String, Any?> = try {
                val args = mutableListOf<String>()
                if (useLinker) {
                    val linker = File("/system/bin/linker64").takeIf { it.exists() }
                        ?: File("/system/bin/linker").takeIf { it.exists() }
                    if (linker == null) {
                        throw IOException("linker 不存在：/system/bin/linker64 与 /system/bin/linker 均不可见")
                    }
                    args += linker.absolutePath
                }
                args += listOf(binary.absolutePath, "-hide_banner", "-version")
                val run = runCaptured(args, VERSION_TIMEOUT_MS)
                mapOf(
                    "ok" to (run.first == 0),
                    "exitCode" to run.first,
                    "output" to run.second,
                )
            } catch (error: Exception) {
                mapOf(
                    "ok" to false,
                    "exitCode" to -1,
                    "output" to (error.message ?: error.toString()),
                )
            }
            main.post { result.success(outcome) }
        }
    }

    private fun transcode(call: MethodCall, result: MethodChannel.Result) {
        val input = call.argument<String>("input")
        val output = call.argument<String>("output")
        val keyHex = call.argument<String>("keyHex") ?: ""
        val timeoutMs = call.argument<Number>("timeoutMs")?.toLong() ?: DEFAULT_TIMEOUT_MS
        if (input.isNullOrEmpty() || output.isNullOrEmpty()) {
            result.error("BAD_ARGUMENT", "transcode needs an input and an output path", null)
            return
        }
        val binary = executable()
        if (binary == null) {
            result.error("UNAVAILABLE", "bytevc2 transcoder is not installed", null)
            return
        }
        val enqueuedAt = SystemClock.elapsedRealtime()
        worker.execute {
            var failure: String? = null
            try {
                val remainingMs = timeoutMs - (SystemClock.elapsedRealtime() - enqueuedAt)
                if (remainingMs <= 0) {
                    throw IllegalStateException("bytevc2 transcode timed out while queued")
                }
                val exit = runFfmpeg(binary, input, output, keyHex, remainingMs)
                if (exit != 0) failure = "bytevc2 transcode exited with $exit"
            } catch (error: Exception) {
                failure = error.message ?: error.toString()
            }
            val message = failure
            main.post {
                if (message == null) result.success(output) else result.error("FAILED", message, null)
            }
        }
    }

    /**
     * Direct exec first; only an IOException from ProcessBuilder.start()
     * (permission / SELinux refusal) falls back to linker64. A non-zero
     * transcode exit is never retried. Mirrors the upstream probe logic.
     */
    private fun runFfmpeg(
        binary: File,
        input: String,
        output: String,
        keyHex: String,
        timeoutMs: Long,
    ): Int {
        val args = ffmpegArgs(binary.absolutePath, input, output, keyHex)
        return try {
            val run = runCaptured(args, timeoutMs)
            if (run.first != 0) {
                throw IllegalStateException("bytevc2 transcode failed (exit ${run.first}): ${run.second}")
            }
            run.first
        } catch (error: IOException) {
            val linker = File("/system/bin/linker64").takeIf { it.exists() }
                ?: File("/system/bin/linker").takeIf { it.exists() }
                ?: throw error
            val fallback = ffmpegArgs(binary.absolutePath, input, output, keyHex)
            fallback.add(0, linker.absolutePath)
            val run = runCaptured(fallback, timeoutMs)
            if (run.first != 0) {
                throw IllegalStateException("bytevc2 transcode failed via linker (exit ${run.first}): ${run.second}")
            }
            run.first
        }
    }

    private fun ffmpegArgs(binary: String, input: String, output: String, keyHex: String): MutableList<String> {
        val args = mutableListOf(
            binary, "-hide_banner", "-loglevel", "error", "-nostdin",
        )
        val key = keyHex.trim()
        if (key.isNotEmpty()) {
            args += listOf("-decryption_key", key)
        }
        args += listOf(
            "-i", input,
            "-map", "0:v:0", "-map", "0:a:0?",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "25",
            "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-movflags", "+faststart",
            "-f", "mp4", "-y", output,
        )
        return args
    }

    /** Runs a command, merging stderr into stdout; returns exit code + output tail. */
    private fun runCaptured(args: List<String>, timeoutMs: Long): Pair<Int, String> {
        val command = ProcessBuilder(args)
        command.redirectErrorStream(true)
        val process = command.start()
        val output = StringBuilder()
        val logReader = Thread({
            try {
                process.inputStream.bufferedReader().use { reader ->
                    val buffer = CharArray(1024)
                    while (true) {
                        val count = reader.read(buffer)
                        if (count < 0) break
                        synchronized(output) {
                            val kept = minOf(count, MAX_LOG_CHARS - output.length)
                            if (kept > 0) output.append(buffer, 0, kept)
                        }
                    }
                }
            } catch (_: IOException) {
                // Killing the process or closing its pipe can interrupt a read.
            }
        }, "bytevc2-verify-log").apply {
            isDaemon = true
            start()
        }
        var interrupted = false
        try {
            if (!process.waitFor(timeoutMs, TimeUnit.MILLISECONDS)) {
                val log = synchronized(output) { output.toString().trim() }
                throw IllegalStateException("timed out after ${timeoutMs}ms: $log")
            }
            logReader.join(CLEANUP_TIMEOUT_MS)
            return process.exitValue() to synchronized(output) { output.toString().trim() }
        } catch (error: InterruptedException) {
            interrupted = true
            throw error
        } finally {
            process.destroyForcibly()
            try {
                process.waitFor(CLEANUP_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            } catch (_: InterruptedException) {
                interrupted = true
            }
            for (stream in listOf(process.inputStream, process.outputStream, process.errorStream)) {
                try {
                    stream.close()
                } catch (_: IOException) {
                    // Cleanup must preserve the original outcome.
                }
            }
            logReader.interrupt()
            try {
                logReader.join(CLEANUP_TIMEOUT_MS)
            } catch (_: InterruptedException) {
                interrupted = true
            }
            if (interrupted) Thread.currentThread().interrupt()
        }
    }

    private companion object {
        const val CHANNEL = "fanrenxiuxian/bytevc2verify"
        const val BINARY = "libbvc2transcode.so"
        const val MAX_LOG_CHARS = 4096
        const val CLEANUP_TIMEOUT_MS = 1000L
        const val VERSION_TIMEOUT_MS = 30_000L
        const val DEFAULT_TIMEOUT_MS = 10 * 60 * 1000L
    }
}
