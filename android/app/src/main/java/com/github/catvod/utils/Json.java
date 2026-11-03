package com.github.catvod.utils;

import com.google.gson.Gson;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

public class Json {

    private static final Gson gson = new Gson();

    public static JsonElement parse(String text) {
        if (text == null || text.trim().isEmpty()) return new JsonObject();
        return JsonParser.parseString(text);
    }

    public static JsonObject parseObject(String text) {
        JsonElement element = parse(text);
        return element != null && element.isJsonObject() ? element.getAsJsonObject() : new JsonObject();
    }

    public static String toJson(Object value) {
        return gson.toJson(value);
    }

    public static <T> T objectFrom(String text, Class<T> type) {
        return gson.fromJson(text, type);
    }

    public static Gson gson() {
        return gson;
    }
}
