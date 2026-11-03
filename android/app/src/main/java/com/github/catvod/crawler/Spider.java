package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

public class Spider {

    public void init(Context context) throws Exception {
    }

    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    public String getName() {
        return "";
    }

    public String homeContent(boolean filter) throws Exception {
        return "";
    }

    public String homeVideoContent() throws Exception {
        return "";
    }

    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        return "";
    }

    public String detailContent(List<String> ids) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return searchContent(key, quick);
    }

    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return "";
    }

    public String liveContent(String url) throws Exception {
        return "";
    }

    public String action(String action) throws Exception {
        return "";
    }

    public boolean isVideoFormat(String url) {
        return false;
    }

    public boolean manualVideoCheck() {
        return false;
    }

    public Object[] proxy(Map<String, String> params) {
        return null;
    }

    public void destroy() {
    }
}
