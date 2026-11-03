package com.github.catvod.crawler;

import android.util.Log;

public class SpiderDebug {

    private static final String TAG = "SpiderDebug";

    public static void log(String message) {
        if (message != null) Log.d(TAG, message);
    }

    public static void log(String message, Object... args) {
        if (message == null) return;
        try {
            Log.d(TAG, String.format(message, args));
        } catch (Exception ignored) {
            Log.d(TAG, message);
        }
    }

    public static void log(Throwable throwable) {
        if (throwable != null) Log.d(TAG, "spider error", throwable);
    }
}
