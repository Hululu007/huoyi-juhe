package com.github.catvod.utils;

import com.github.catvod.spider.Init;

import java.io.File;

public class Path {

    public static File root() {
        return Init.context().getFilesDir();
    }

    public static File cache() {
        File dir = Init.context().getCacheDir();
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File cache(String name) {
        File file = new File(cache(), name);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        return file;
    }

    public static File files() {
        File dir = Init.context().getFilesDir();
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File files(String name) {
        File file = new File(files(), name);
        File parent = file.getParentFile();
        if (parent != null && !parent.exists()) parent.mkdirs();
        return file;
    }

    public static File download() {
        File dir = new File(files(), "download");
        if (!dir.exists()) dir.mkdirs();
        return dir;
    }

    public static File jar() {
        throw new UnsupportedOperationException(
                "catvod 兼容层未实现 Path.jar()：本 App 不提供壳内 jar 目录");
    }

    public static File tv() {
        throw new UnsupportedOperationException(
                "catvod 兼容层未实现 Path.tv()：本 App 不提供壳内电视目录");
    }
}
