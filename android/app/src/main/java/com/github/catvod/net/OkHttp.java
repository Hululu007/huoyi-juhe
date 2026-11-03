package com.github.catvod.net;

import java.io.IOException;
import java.util.Map;
import java.util.concurrent.TimeUnit;

import okhttp3.Call;
import okhttp3.FormBody;
import okhttp3.Interceptor;
import okhttp3.OkHttpClient;
import okhttp3.Request;
import okhttp3.Response;
import okhttp3.ResponseBody;

public class OkHttp {

    private static volatile OkHttpClient shared;
    private static volatile boolean fingerprintEnabled = true;

    public static void setFingerprintEnabled(boolean enabled) {
        fingerprintEnabled = enabled;
    }

    public static boolean isFingerprintEnabled() {
        return fingerprintEnabled;
    }

    private static String pickProfile(String userAgent) {
        if (userAgent == null) return "chrome";
        String ua = userAgent.toLowerCase();
        if (ua.contains("firefox")) return "firefox";
        if (ua.contains("edg/") || ua.contains("edge/")) return "edge";
        if (ua.contains("chrome") || ua.contains("chromium")) return "chrome";
        if (ua.contains("safari")) return "safari";
        return "chrome";
    }

    private static String profileUserAgent(String profile) {
        if ("firefox".equals(profile)) {
            return "Mozilla/5.0 (Android 14; Mobile; rv:133.0) Gecko/133.0 Firefox/133.0";
        }
        if ("safari".equals(profile)) {
            return "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1";
        }
        if ("edge".equals(profile)) {
            return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36 EdgA/131.0.0.0";
        }
        return "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36";
    }

    private static String profileAccept(String profile) {
        if ("firefox".equals(profile)) {
            return "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8";
        }
        if ("safari".equals(profile)) {
            return "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8";
        }
        return "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8";
    }

    private static String profileSecChUa(String profile) {
        if ("chrome".equals(profile)) {
            return "\"Google Chrome\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"";
        }
        if ("edge".equals(profile)) {
            return "\"Microsoft Edge\";v=\"131\", \"Chromium\";v=\"131\", \"Not_A Brand\";v=\"24\"";
        }
        return null;
    }

    static class FingerprintInterceptor implements Interceptor {
        @Override
        public Response intercept(Chain chain) throws IOException {
            Request request = chain.request();
            if (!fingerprintEnabled) return chain.proceed(request);
            String profile = pickProfile(request.header("User-Agent"));
            Request.Builder builder = request.newBuilder();
            if (request.header("User-Agent") == null) {
                builder.header("User-Agent", profileUserAgent(profile));
            }
            if (request.header("Accept") == null) {
                builder.header("Accept", profileAccept(profile));
            }
            if (request.header("Accept-Language") == null) {
                builder.header("Accept-Language", "zh-CN,zh;q=0.9,en;q=0.8");
            }
            String secChUa = profileSecChUa(profile);
            if (secChUa != null && request.header("sec-ch-ua") == null) {
                builder.header("sec-ch-ua", secChUa);
                builder.header("sec-ch-ua-mobile", "?1");
                builder.header("sec-ch-ua-platform", "\"Android\"");
            }
            return chain.proceed(builder.build());
        }
    }

    public static OkHttpClient client() {
        OkHttpClient client = shared;
        if (client == null) {
            synchronized (OkHttp.class) {
                client = shared;
                if (client == null) {
                    client = new OkHttpClient.Builder()
                            .connectTimeout(15, TimeUnit.SECONDS)
                            .readTimeout(30, TimeUnit.SECONDS)
                            .writeTimeout(30, TimeUnit.SECONDS)
                            .followRedirects(true)
                            .followSslRedirects(true)
                            .addInterceptor(new FingerprintInterceptor())
                            .build();
                    shared = client;
                }
            }
        }
        return client;
    }

    public static OkHttpClient client(long timeoutMillis) {
        return client().newBuilder()
                .connectTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
                .readTimeout(timeoutMillis, TimeUnit.MILLISECONDS)
                .build();
    }

    public static Request.Builder builder(String url, Map<String, String> headers) {
        Request.Builder builder = new Request.Builder().url(url);
        if (headers != null) {
            for (Map.Entry<String, String> entry : headers.entrySet()) {
                if (entry.getKey() != null && entry.getValue() != null) {
                    builder.header(entry.getKey(), entry.getValue());
                }
            }
        }
        return builder;
    }

    public static Call newCall(String url, Map<String, String> headers) {
        return client().newCall(builder(url, headers).build());
    }

    public static String get(String url) throws IOException {
        return get(url, null);
    }

    public static String get(String url, Map<String, String> headers) throws IOException {
        try (Response response = newCall(url, headers).execute()) {
            return bodyText(response);
        }
    }

    public static String post(String url, Map<String, String> params) throws IOException {
        return post(url, params, null);
    }

    public static String post(String url, Map<String, String> params, Map<String, String> headers) throws IOException {
        FormBody.Builder form = new FormBody.Builder();
        if (params != null) {
            for (Map.Entry<String, String> entry : params.entrySet()) {
                if (entry.getKey() != null && entry.getValue() != null) {
                    form.add(entry.getKey(), entry.getValue());
                }
            }
        }
        Request request = builder(url, headers).post(form.build()).build();
        try (Response response = client().newCall(request).execute()) {
            return bodyText(response);
        }
    }

    public static String post(String url, String body, Map<String, String> headers, String contentType) throws IOException {
        okhttp3.MediaType mediaType = contentType == null ? null : okhttp3.MediaType.parse(contentType);
        Request request = builder(url, headers)
                .post(okhttp3.RequestBody.create(body == null ? "" : body, mediaType))
                .build();
        try (Response response = client().newCall(request).execute()) {
            return bodyText(response);
        }
    }

    private static String bodyText(Response response) throws IOException {
        ResponseBody body = response.body();
        return body == null ? "" : body.string();
    }
}
