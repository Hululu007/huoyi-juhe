#include "huoyi_quickjs.h"
#include <jni.h>
#include <stdlib.h>
#include <string.h>

static JavaVM *g_vm = NULL;
static jclass g_bridge_class = NULL;
static jmethodID g_fetch_method = NULL;
static jmethodID g_request_method = NULL;
static jmethodID g_pdfa_method = NULL;
static jmethodID g_pdfh_method = NULL;
static jmethodID g_pd_method = NULL;

static char *call_static_string(jmethodID method, const char *arg) {
    if (!g_vm || !g_bridge_class || !method) return NULL;
    JNIEnv *env = NULL;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != 0 || !env) return NULL;
    jstring jarg = (*env)->NewStringUTF(env, arg);
    if (!jarg) return NULL;
    jstring jout = (jstring)(*env)->CallStaticObjectMethod(env, g_bridge_class, method, jarg);
    (*env)->DeleteLocalRef(env, jarg);
    if ((*env)->ExceptionCheck(env)) {
        (*env)->ExceptionClear(env);
        return NULL;
    }
    if (!jout) return NULL;
    const char *out = (*env)->GetStringUTFChars(env, jout, NULL);
    if (!out) {
        (*env)->DeleteLocalRef(env, jout);
        return NULL;
    }
    char *copy = strdup(out);
    (*env)->ReleaseStringUTFChars(env, jout, out);
    (*env)->DeleteLocalRef(env, jout);
    return copy;
}

static char *jni_fetch(const char *url) {
    return call_static_string(g_fetch_method, url);
}

static char *jni_request(const char *arg) {
    return call_static_string(g_request_method, arg);
}

static char *jni_pdfa(const char *arg) {
    return call_static_string(g_pdfa_method, arg);
}

static char *jni_pdfh(const char *arg) {
    return call_static_string(g_pdfh_method, arg);
}

static char *jni_pd(const char *arg) {
    return call_static_string(g_pd_method, arg);
}

JNIEXPORT jstring JNICALL
Java_com_fqapp_fqapp_QuickJSBridge_nativeEval(JNIEnv *env, jclass clazz, jstring script, jint timeoutMs) {
    if ((*env)->GetJavaVM(env, &g_vm) == 0 && g_bridge_class == NULL) {
        jclass local = (*env)->FindClass(env, "com/fqapp/fqapp/QuickJSBridge");
        if (local) {
            g_bridge_class = (jclass)(*env)->NewGlobalRef(env, local);
            (*env)->DeleteLocalRef(env, local);
            g_fetch_method = (*env)->GetStaticMethodID(env, g_bridge_class, "fetch", "(Ljava/lang/String;)Ljava/lang/String;");
            g_request_method = (*env)->GetStaticMethodID(env, g_bridge_class, "requestJson", "(Ljava/lang/String;)Ljava/lang/String;");
            g_pdfa_method = (*env)->GetStaticMethodID(env, g_bridge_class, "pdfaJson", "(Ljava/lang/String;)Ljava/lang/String;");
            g_pdfh_method = (*env)->GetStaticMethodID(env, g_bridge_class, "pdfhJson", "(Ljava/lang/String;)Ljava/lang/String;");
            g_pd_method = (*env)->GetStaticMethodID(env, g_bridge_class, "pdJson", "(Ljava/lang/String;)Ljava/lang/String;");
        }
        huoyi_qjs_set_fetch(jni_fetch);
        huoyi_qjs_set_request(jni_request);
        huoyi_qjs_set_pdfa(jni_pdfa);
        huoyi_qjs_set_pdfh(jni_pdfh);
        huoyi_qjs_set_pd(jni_pd);
    }
    (void)clazz;
    const char *text = script ? (*env)->GetStringUTFChars(env, script, NULL) : NULL;
    if (!text) return (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"empty script\"}");
    char *out = huoyi_qjs_eval(text, (int)timeoutMs);
    (*env)->ReleaseStringUTFChars(env, script, text);
    jstring result = (*env)->NewStringUTF(env, out ? out : "{\"ok\":false,\"error\":\"out of memory\"}");
    huoyi_qjs_free(out);
    return result;
}
