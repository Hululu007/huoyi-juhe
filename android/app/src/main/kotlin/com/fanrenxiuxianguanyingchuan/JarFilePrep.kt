package com.fanrenxiuxianguanyingchuan

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

    /// 原子替换目标 jar：同一目录内的 rename(2) 直接覆盖旧文件，
    /// 全程不存在“目标文件缺失”的空窗。旧写法先删目标再放新文件，
    /// 删与放之间的空窗 + 并发 ensureJar 抢同一个 .part 临时文件，
    /// 会把目标删空（18 轮升级后 jar 指纹变了、首次解包必走替换路径，
    /// 首页影视区又 3 站并发加载，撞上即全部 jar 站报
    /// “jar 文件不存在，无法加载”）。rename 时旧文件即使是只读
    /// 密封的、即使正被 DexClassLoader mmap，也能被原子换掉
    /// （只要求目录可写，旧映射继续指向旧 inode，不受影响）。
    fun replaceTarget(temp: File, target: File) {
        if (temp.renameTo(target)) {
            sealForLoad(target)
            return
        }
        // rename 失败（极少见，如跨文件系统）才走拷贝兜底：目标还在
        // 就保留旧文件、报明确错误，绝不先删目标把路走绝；目标不在
        // 才拷贝一份新的。
        if (target.exists()) {
            throw IllegalStateException("jar 文件无法原子替换，旧文件保留：${target.absolutePath}")
        }
        temp.copyTo(target, overwrite = false)
        temp.delete()
        sealForLoad(target)
    }
}
