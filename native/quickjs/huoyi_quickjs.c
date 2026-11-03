#include "huoyi_quickjs.h"
#include "quickjs.h"
#include <stdlib.h>
#include <string.h>
#include <time.h>

static HuoyiFetchFunc g_fetch = NULL;
static HuoyiStringFunc g_request = NULL;
static HuoyiStringFunc g_pdfa = NULL;
static HuoyiStringFunc g_pdfh = NULL;
static HuoyiStringFunc g_pd = NULL;

void huoyi_qjs_set_fetch(HuoyiFetchFunc fn) { g_fetch = fn; }
void huoyi_qjs_set_request(HuoyiStringFunc fn) { g_request = fn; }
void huoyi_qjs_set_pdfa(HuoyiStringFunc fn) { g_pdfa = fn; }
void huoyi_qjs_set_pdfh(HuoyiStringFunc fn) { g_pdfh = fn; }
void huoyi_qjs_set_pd(HuoyiStringFunc fn) { g_pd = fn; }

void huoyi_qjs_free(char *ptr) { free(ptr); }

static long long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long long)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

typedef struct {
    long long deadline_ms;
    char *result_json;
} HuoyiQjsState;

static int interrupt_handler(JSRuntime *rt, void *opaque) {
    (void)rt;
    HuoyiQjsState *state = (HuoyiQjsState *)opaque;
    return now_ms() > state->deadline_ms;
}

static JSValue js_set_result(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1) return JS_UNDEFINED;
    JSValue json = JS_JSONStringify(ctx, argv[0], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) return JS_EXCEPTION;
    const char *str = JS_ToCString(ctx, json);
    if (str) {
        HuoyiQjsState *state = (HuoyiQjsState *)JS_GetContextOpaque(ctx);
        free(state->result_json);
        state->result_json = strdup(str);
        JS_FreeCString(ctx, str);
    }
    JS_FreeValue(ctx, json);
    return JS_UNDEFINED;
}

static JSValue js_noop(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)ctx;
    (void)this_val;
    (void)argc;
    (void)argv;
    return JS_UNDEFINED;
}

static JSValue js_fetch(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 1 || !g_fetch) {
        return JS_ThrowTypeError(ctx, "fetch not available");
    }
    const char *url = JS_ToCString(ctx, argv[0]);
    if (!url) return JS_EXCEPTION;
    char *body = g_fetch(url);
    JS_FreeCString(ctx, url);
    if (!body) {
        return JS_ThrowInternalError(ctx, "fetch failed");
    }
    JSValue result = JS_NewString(ctx, body);
    free(body);
    return result;
}

static char *stringify_value(JSContext *ctx, JSValueConst value) {
    JSValue json = JS_JSONStringify(ctx, value, JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json)) {
        JS_FreeValue(ctx, json);
        return NULL;
    }
    const char *str = JS_ToCString(ctx, json);
    if (!str) {
        JS_FreeValue(ctx, json);
        return NULL;
    }
    char *copy = strdup(str);
    JS_FreeCString(ctx, str);
    JS_FreeValue(ctx, json);
    return copy;
}

static JSValue js_request_impl(JSContext *ctx, int argc, JSValueConst *argv, const char *forced_method) {
    if (argc < 1 || !g_request) {
        return JS_ThrowTypeError(ctx, "request not available");
    }
    JSValue req = JS_NewObject(ctx);
    JSValue url_val = JS_UNDEFINED;
    JSValue method_val = JS_NewString(ctx, forced_method ? forced_method : "GET");
    JSValue headers_val = JS_NewObject(ctx);
    JSValue body_val = JS_NewString(ctx, "");
    if (JS_IsString(argv[0])) {
        url_val = JS_DupValue(ctx, argv[0]);
    } else if (JS_IsObject(argv[0])) {
        JSValue u = JS_GetPropertyStr(ctx, argv[0], "url");
        if (!JS_IsUndefined(u)) url_val = u; else JS_FreeValue(ctx, u);
        JSValue m = JS_GetPropertyStr(ctx, argv[0], "method");
        if (JS_IsString(m) && !forced_method) {
            JS_FreeValue(ctx, method_val);
            method_val = m;
        } else {
            JS_FreeValue(ctx, m);
        }
        JSValue h = JS_GetPropertyStr(ctx, argv[0], "headers");
        if (JS_IsObject(h)) {
            JS_FreeValue(ctx, headers_val);
            headers_val = h;
        } else {
            JS_FreeValue(ctx, h);
        }
        JSValue b = JS_GetPropertyStr(ctx, argv[0], "body");
        if (JS_IsString(b)) {
            JS_FreeValue(ctx, body_val);
            body_val = b;
        } else {
            JS_FreeValue(ctx, b);
        }
    }
    if (argc > 1) {
        if (JS_IsObject(argv[1])) {
            JS_FreeValue(ctx, headers_val);
            headers_val = JS_DupValue(ctx, argv[1]);
        } else if (JS_IsString(argv[1])) {
            JS_FreeValue(ctx, body_val);
            body_val = JS_DupValue(ctx, argv[1]);
        }
    }
    JS_SetPropertyStr(ctx, req, "url", url_val);
    JS_SetPropertyStr(ctx, req, "method", method_val);
    JS_SetPropertyStr(ctx, req, "headers", headers_val);
    JS_SetPropertyStr(ctx, req, "body", body_val);
    char *arg = stringify_value(ctx, req);
    JS_FreeValue(ctx, req);
    if (!arg) return JS_EXCEPTION;
    char *body = g_request(arg);
    free(arg);
    if (!body) return JS_NewString(ctx, "");
    JSValue result = JS_NewString(ctx, body);
    free(body);
    return result;
}

static JSValue js_request(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    return js_request_impl(ctx, argc, argv, NULL);
}

static JSValue js_get(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    return js_request_impl(ctx, argc, argv, "GET");
}

static JSValue js_post(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    return js_request_impl(ctx, argc, argv, "POST");
}

static JSValue js_parse_or_empty(JSContext *ctx, HuoyiStringFunc fn, const char *arg) {
    char *out = fn(arg);
    if (!out) return JS_NewString(ctx, "");
    JSValue value = JS_ParseJSON(ctx, out, strlen(out), "<host>");
    free(out);
    if (JS_IsException(value)) return JS_EXCEPTION;
    return value;
}

static char *build_html_args(JSContext *ctx, int argc, JSValueConst *argv, int with_attr) {
    JSValue obj = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, obj, "html", JS_DupValue(ctx, argv[0]));
    JS_SetPropertyStr(ctx, obj, "selector", JS_DupValue(ctx, argv[1]));
    if (with_attr && argc > 2) {
        JS_SetPropertyStr(ctx, obj, "attr", JS_DupValue(ctx, argv[2]));
    }
    char *arg = stringify_value(ctx, obj);
    JS_FreeValue(ctx, obj);
    return arg;
}

static JSValue js_pdfa(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || !g_pdfa) {
        return JS_ThrowTypeError(ctx, "pdfa not available");
    }
    char *arg = build_html_args(ctx, argc, argv, 0);
    if (!arg) return JS_EXCEPTION;
    JSValue value = js_parse_or_empty(ctx, g_pdfa, arg);
    free(arg);
    if (JS_IsException(value)) {
        JSValue empty = JS_NewArray(ctx);
        return empty;
    }
    return value;
}

static JSValue js_pdfh(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || !g_pdfh) {
        return JS_ThrowTypeError(ctx, "pdfh not available");
    }
    char *arg = build_html_args(ctx, argc, argv, 0);
    if (!arg) return JS_EXCEPTION;
    char *out = g_pdfh(arg);
    free(arg);
    if (!out) return JS_NewString(ctx, "");
    JSValue result = JS_NewString(ctx, out);
    free(out);
    return result;
}

static JSValue js_pd(JSContext *ctx, JSValueConst this_val, int argc, JSValueConst *argv) {
    (void)this_val;
    if (argc < 2 || !g_pd) {
        return JS_ThrowTypeError(ctx, "pd not available");
    }
    char *arg = build_html_args(ctx, argc, argv, 1);
    if (!arg) return JS_EXCEPTION;
    char *out = g_pd(arg);
    free(arg);
    if (!out) return JS_NewString(ctx, "");
    JSValue result = JS_NewString(ctx, out);
    free(out);
    return result;
}

static char *json_escape(const char *s) {
    size_t len = strlen(s);
    char *out = (char *)malloc(len * 2 + 3);
    if (!out) return NULL;
    size_t j = 0;
    out[j++] = '"';
    for (size_t i = 0; i < len; i++) {
        unsigned char c = (unsigned char)s[i];
        if (c == '"' || c == '\\') { out[j++] = '\\'; out[j++] = (char)c; }
        else if (c == '\n') { out[j++] = '\\'; out[j++] = 'n'; }
        else if (c == '\r') { out[j++] = '\\'; out[j++] = 'r'; }
        else if (c == '\t') { out[j++] = '\\'; out[j++] = 't'; }
        else if (c < 0x20) { j += (size_t)snprintf(out + j, 16, "\\u%04x", c); }
        else out[j++] = (char)c;
    }
    out[j++] = '"';
    out[j] = '\0';
    return out;
}

char *huoyi_qjs_eval(const char *script, int timeout_ms) {
    if (!script) return strdup("{\"ok\":false,\"error\":\"empty script\"}");
    if (timeout_ms <= 0) timeout_ms = 10000;
    if (timeout_ms > 60000) timeout_ms = 60000;
    JSRuntime *rt = JS_NewRuntime();
    if (!rt) return strdup("{\"ok\":false,\"error\":\"cannot create runtime\"}");
    JS_SetMemoryLimit(rt, 32 * 1024 * 1024);
    JS_SetMaxStackSize(rt, 256 * 1024);
    HuoyiQjsState state;
    state.deadline_ms = now_ms() + timeout_ms;
    state.result_json = NULL;
    JS_SetInterruptHandler(rt, interrupt_handler, &state);
    JSContext *ctx = JS_NewContext(rt);
    if (!ctx) {
        JS_FreeRuntime(rt);
        return strdup("{\"ok\":false,\"error\":\"cannot create context\"}");
    }
    JS_SetContextOpaque(ctx, &state);
    JSValue global = JS_GetGlobalObject(ctx);
    JS_SetPropertyStr(ctx, global, "setResult", JS_NewCFunction(ctx, js_set_result, "setResult", 1));
    JS_SetPropertyStr(ctx, global, "fetch", JS_NewCFunction(ctx, js_fetch, "fetch", 1));
    JS_SetPropertyStr(ctx, global, "request", JS_NewCFunction(ctx, js_request, "request", 2));
    JS_SetPropertyStr(ctx, global, "get", JS_NewCFunction(ctx, js_get, "get", 2));
    JS_SetPropertyStr(ctx, global, "post", JS_NewCFunction(ctx, js_post, "post", 2));
    JS_SetPropertyStr(ctx, global, "pdfa", JS_NewCFunction(ctx, js_pdfa, "pdfa", 2));
    JS_SetPropertyStr(ctx, global, "pdfh", JS_NewCFunction(ctx, js_pdfh, "pdfh", 2));
    JS_SetPropertyStr(ctx, global, "pd", JS_NewCFunction(ctx, js_pd, "pd", 3));
    JS_SetPropertyStr(ctx, global, "log", JS_NewCFunction(ctx, js_noop, "log", 1));
    JS_SetPropertyStr(ctx, global, "print", JS_NewCFunction(ctx, js_noop, "print", 1));
    JSValue console = JS_NewObject(ctx);
    JS_SetPropertyStr(ctx, console, "log", JS_NewCFunction(ctx, js_noop, "log", 1));
    JS_SetPropertyStr(ctx, console, "error", JS_NewCFunction(ctx, js_noop, "error", 1));
    JS_SetPropertyStr(ctx, global, "console", console);
    JS_FreeValue(ctx, global);
    JSValue val = JS_Eval(ctx, script, strlen(script), "<huoyi>", JS_EVAL_TYPE_GLOBAL);
    char *out = NULL;
    if (JS_IsException(val)) {
        JSValue exc = JS_GetException(ctx);
        const char *msg = JS_ToCString(ctx, exc);
        char *escaped = msg ? json_escape(msg) : strdup("\"unknown error\"");
        size_t need = strlen(escaped) + 32;
        out = (char *)malloc(need);
        if (out) snprintf(out, need, "{\"ok\":false,\"error\":%s}", escaped);
        free(escaped);
        if (msg) JS_FreeCString(ctx, msg);
        JS_FreeValue(ctx, exc);
    } else {
        if (state.result_json) {
            size_t need = strlen(state.result_json) + 32;
            out = (char *)malloc(need);
            if (out) snprintf(out, need, "{\"ok\":true,\"result\":%s}", state.result_json);
        } else {
            JSValue json = JS_JSONStringify(ctx, val, JS_UNDEFINED, JS_UNDEFINED);
            if (!JS_IsException(json)) {
                const char *str = JS_ToCString(ctx, json);
                if (str) {
                    size_t need = strlen(str) + 32;
                    out = (char *)malloc(need);
                    if (out) snprintf(out, need, "{\"ok\":true,\"result\":%s}", str);
                    JS_FreeCString(ctx, str);
                }
                JS_FreeValue(ctx, json);
            }
            if (!out) out = strdup("{\"ok\":true,\"result\":null}");
        }
    }
    JS_FreeValue(ctx, val);
    free(state.result_json);
    JS_FreeContext(ctx);
    JS_FreeRuntime(rt);
    if (!out) out = strdup("{\"ok\":false,\"error\":\"out of memory\"}");
    return out;
}
