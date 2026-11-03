package com.fqapp.fqapp

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermission

object JarFilePrep {

    fun isWritable(file: File): Boolean {
        return try {
            val perms = Files.getPosixFilePermissions(file.toPath())
            perms.contains(PosixFilePermission.OWNER_WRITE) ||
                perms.contains(PosixFilePermission.GROUP_WRITE) ||
                perms.contains(PosixFilePermission.OTHERS_WRITE)
        } catch (error: Throwable) {
            file.canWrite()
        }
    }

    fun sealForLoad(file: File) {
        if (!file.isFile) {
            throw IllegalStateException("jar 文件不存在，无法加载：${file.absolutePath}")
        }
        if (!isWritable(file)) return
        file.setReadOnly()
        if (isWritable(file)) {
            try {
                val perms = Files.getPosixFilePermissions(file.toPath()).toMutableSet()
                perms.remove(PosixFilePermission.OWNER_WRITE)
                perms.remove(PosixFilePermission.GROUP_WRITE)
                perms.remove(PosixFilePermission.OTHERS_WRITE)
                Files.setPosixFilePermissions(file.toPath(), perms)
            } catch (ignored: Throwable) {
            }
        }
        if (isWritable(file)) {
            throw IllegalStateException(
                "jar 文件无法置为只读，安卓 14 及以上系统会拒绝加载可写的 dex 文件：${file.absolutePath}"
            )
        }
    }

    fun makeWritable(file: File) {
        if (!file.exists() || isWritable(file)) return
        file.setWritable(true, false)
        if (!isWritable(file)) {
            try {
                val perms = Files.getPosixFilePermissions(file.toPath()).toMutableSet()
                perms.add(PosixFilePermission.OWNER_WRITE)
                Files.setPosixFilePermissions(file.toPath(), perms)
            } catch (ignored: Throwable) {
            }
        }
        if (!isWritable(file)) {
            throw IllegalStateException("jar 文件无法恢复可写，无法更新：${file.absolutePath}")
        }
    }

    fun replaceTarget(temp: File, target: File) {
        if (target.exists() && !target.delete()) {
            makeWritable(target)
            if (!target.delete() && target.exists()) {
                throw IllegalStateException("无法删除旧 jar 文件，更新失败：${target.absolutePath}")
            }
        }
        if (!temp.renameTo(target)) {
            temp.copyTo(target, overwrite = false)
            temp.delete()
        }
        sealForLoad(target)
    }
}
