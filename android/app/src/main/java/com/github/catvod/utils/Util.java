package com.github.catvod.utils;

import android.util.Base64;

import java.io.UnsupportedEncodingException;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.UUID;

public class Util {

    public static String md5(String text) {
        if (text == null) return "";
        try {
            MessageDigest digest = MessageDigest.getInstance("MD5");
            byte[] bytes = digest.digest(text.getBytes(StandardCharsets.UTF_8));
            StringBuilder builder = new StringBuilder(bytes.length * 2);
            for (byte b : bytes) builder.append(String.format("%02x", b & 0xff));
            return builder.toString();
        } catch (NoSuchAlgorithmException e) {
            return "";
        }
    }

    public static String base64(String text) {
        if (text == null) return "";
        return Base64.encodeToString(text.getBytes(StandardCharsets.UTF_8), Base64.NO_WRAP);
    }

    public static String base64(byte[] data) {
        if (data == null) return "";
        return Base64.encodeToString(data, Base64.NO_WRAP);
    }

    public static byte[] base64Decode(String text) {
        if (text == null || text.isEmpty()) return new byte[0];
        return Base64.decode(text, Base64.DEFAULT);
    }

    public static String decodeBase64(String text) {
        byte[] data = base64Decode(text);
        return new String(data, StandardCharsets.UTF_8);
    }

    public static String encodeURIComponent(String text) {
        if (text == null) return "";
        try {
            return URLEncoder.encode(text, "UTF-8")
                    .replace("+", "%20")
                    .replace("%21", "!")
                    .replace("%27", "'")
                    .replace("%28", "(")
                    .replace("%29", ")")
                    .replace("%7E", "~");
        } catch (UnsupportedEncodingException e) {
            return text;
        }
    }

    public static String getUUID() {
        return UUID.randomUUID().toString().replace("-", "");
    }

    public static boolean isEmpty(String text) {
        return text == null || text.isEmpty();
    }

    public static String trim(String text) {
        return text == null ? "" : text.trim();
    }
}
