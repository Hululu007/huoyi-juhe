package com.github.catvod.spider;

import android.content.Context;
import android.os.Handler;
import android.os.Looper;

import com.github.catvod.crawler.Spider;

import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

public class Init {

    private static volatile Context appContext;
    private static final ExecutorService executor = Executors.newCachedThreadPool();
    private static final Handler mainHandler = new Handler(Looper.getMainLooper());
    private static final Map<String, Spider> spiders = new ConcurrentHashMap<>();

    public static void init(Context context) {
        if (context != null) appContext = context.getApplicationContext();
    }

    public static Context context() {
        Context context = appContext;
        if (context == null) {
            throw new IllegalStateException("catvod 兼容层尚未初始化：Init.init(Context) 未被调用");
        }
        return context;
    }

    public static boolean isInitialized() {
        return appContext != null;
    }

    public static void execute(Runnable runnable) {
        executor.execute(runnable);
    }

    public static void post(Runnable runnable) {
        mainHandler.post(runnable);
    }

    public static void post(Runnable runnable, long delayMillis) {
        mainHandler.postDelayed(runnable, Math.max(0, delayMillis));
    }

    public static void registerSpider(String key, Spider spider) {
        if (key == null || spider == null) return;
        spiders.put(key, spider);
    }

    public static void unregisterSpider(String key) {
        if (key != null) spiders.remove(key);
    }

    public static Spider getSpider(String key) {
        Spider spider = key == null ? null : spiders.get(key);
        if (spider == null) {
            throw new UnsupportedOperationException(
                    "catvod 兼容层未提供跨站 Spider 查找：未注册的站点 key=" + key);
        }
        return spider;
    }
}
