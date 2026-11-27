#include "huoyi_quickjs.h"
#include <jni.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

static JavaVM *g_vm = NULL;
static jclass g_bridge_class = NULL;
static jmethodID g_fetch_method = NULL;
static jmethodID g_request_method = NULL;
static jmethodID g_pdfa_method = NULL;
static jmethodID g_pdfh_method = NULL;
static jmethodID g_pd_method = NULL;

/* ---- 标准 UTF-8 -> Modified UTF-8 转换（本次闪退的根因修复） ----
   病因：QuickJS 的 JS_ToCString 输出的是标准 UTF-8，非 BMP 字符
   （如 🔞 U+1F51E）被编成 4 字节序列 f0 9f 94 9e。而 JNI 的
   NewStringUTF 只认 Modified UTF-8：其中 0xF0 打头的序列根本不
   存在，非 BMP 字符的正规形式是代理对拆开、每个代理各编 3 字节
   （🔞 = ed a0 bd ed b4 9e），U+0000 则编成 c0 80。安卓 ART 对
   NewStringUTF 的入参做严格校验，喂进 4 字节序列会直接 abort
   进程（tombstone: "input is not valid Modified UTF-8"），插件
   第一次真跑、真页面第一次流过回调即闪退且无错误界面；桌面
   HotSpot 对同样的字节只是宽容错解成乱码、不崩，所以桌面复现
   不出。凡是内容来自 JS/页面数据的出向字符串，一律先经下面
   的助手转成 Modified UTF-8 再交给 NewStringUTF。 */

/* 宽容解码一个标准 UTF-8 码点：合法序列按规矩解；孤代理的三
   字节序列（CESU-8 形态）解出的码点落在 D800-DFFF，编码回去
   仍是同样的三字节，即原样保留；其余非法字节替换成 U+FFFD，
   只前进 1 字节继续扫，不让坏数据中断整串。 */
static uint32_t utf8_decode_one(const unsigned char *s, size_t remaining,
                                size_t *consumed) {
    unsigned char c = s[0];
    if (c < 0x80) {
        *consumed = 1;
        return c;
    }
    if (c >= 0xC2 && c <= 0xDF) {
        if (remaining >= 2 && (s[1] & 0xC0) == 0x80) {
            *consumed = 2;
            return ((uint32_t)(c & 0x1F) << 6) | (uint32_t)(s[1] & 0x3F);
        }
    } else if (c >= 0xE0 && c <= 0xEF) {
        if (remaining >= 3 && (s[1] & 0xC0) == 0x80 &&
            (s[2] & 0xC0) == 0x80) {
            uint32_t cp = ((uint32_t)(c & 0x0F) << 12) |
                          ((uint32_t)(s[1] & 0x3F) << 6) |
                          (uint32_t)(s[2] & 0x3F);
            if (cp >= 0x800) {
                *consumed = 3;
                return cp;
            }
        }
    } else if (c >= 0xF0 && c <= 0xF4) {
        if (remaining >= 4 && (s[1] & 0xC0) == 0x80 &&
            (s[2] & 0xC0) == 0x80 && (s[3] & 0xC0) == 0x80) {
            uint32_t cp = ((uint32_t)(c & 0x07) << 18) |
                          ((uint32_t)(s[1] & 0x3F) << 12) |
                          ((uint32_t)(s[2] & 0x3F) << 6) |
                          (uint32_t)(s[3] & 0x3F);
            if (cp >= 0x10000 && cp <= 0x10FFFF) {
                *consumed = 4;
                return cp;
            }
        }
    }
    *consumed = 1;
    return 0xFFFD;
}

static size_t mutf8_encode_one(uint32_t cp, unsigned char *dst) {
    if (cp == 0) {
        dst[0] = 0xC0;
        dst[1] = 0x80;
        return 2;
    }
    if (cp < 0x80) {
        dst[0] = (unsigned char)cp;
        return 1;
    }
    if (cp < 0x800) {
        dst[0] = (unsigned char)(0xC0 | (cp >> 6));
        dst[1] = (unsigned char)(0x80 | (cp & 0x3F));
        return 2;
    }
    if (cp < 0x10000) {
        /* BMP 3 字节照旧；孤代理 D800-DFFF 也走这里，三字节本身
           就是 Modified UTF-8 的合法形式，等于原样保留。 */
        dst[0] = (unsigned char)(0xE0 | (cp >> 12));
        dst[1] = (unsigned char)(0x80 | ((cp >> 6) & 0x3F));
        dst[2] = (unsigned char)(0x80 | (cp & 0x3F));
        return 3;
    }
    /* 非 BMP：拆成代理对，每个代理各编 3 字节，共 6 字节——这
       正是 Modified UTF-8 要求的形态，ART 校验可过。 */
    cp -= 0x10000;
    uint32_t pair[2];
    pair[0] = 0xD800 + (cp >> 10);
    pair[1] = 0xDC00 + (cp & 0x3FF);
    size_t n = 0;
    for (int i = 0; i < 2; i++) {
        dst[n++] = (unsigned char)(0xE0 | (pair[i] >> 12));
        dst[n++] = (unsigned char)(0x80 | ((pair[i] >> 6) & 0x3F));
        dst[n++] = (unsigned char)(0x80 | (pair[i] & 0x3F));
    }
    return n;
}

/* 把标准 UTF-8 的 C 字符串转成 Modified UTF-8 后再建 Java 串。
   缓冲区按最坏膨胀分配：4 字节序列转 6 字节是 1.5 倍，非法单
   字节替换成 U+FFFD 的 3 字节是 3 倍，按 3 倍 + 1 分配必够。 */
static jstring new_string_utf(JNIEnv *env, const char *s) {
    if (!s) return NULL;
    size_t len = strlen(s);
    unsigned char *buf = (unsigned char *)malloc(len * 3 + 1);
    if (!buf) return NULL;
    size_t in = 0, out = 0;
    while (in < len) {
        size_t consumed = 1;
        uint32_t cp = utf8_decode_one((const unsigned char *)s + in,
                                      len - in, &consumed);
        out += mutf8_encode_one(cp, buf + out);
        in += consumed;
    }
    buf[out] = '\0';
    jstring result = (*env)->NewStringUTF(env, (const char *)buf);
    free(buf);
    return result;
}

static char *call_static_string(jmethodID method, const char *arg) {
    if (!g_vm || !g_bridge_class || !method) return NULL;
    JNIEnv *env = NULL;
    if ((*g_vm)->AttachCurrentThread(g_vm, &env, NULL) != 0 || !env) return NULL;
    /* arg 来自 JS_ToCString，是标准 UTF-8（fetch 的 url、request/
       pdfa/pdfh/pd 的 JSON 参数，后者含整页 html），含非 BMP 字符
       时直喂 NewStringUTF 会被 ART abort，必须走转换助手。 */
    jstring jarg = new_string_utf(env, arg);
    if (!jarg) {
        /* 防御性修复（既有小洞，与本次闪退根因无关）：建串失败时
           可能挂着 pending exception（OOM 等），不清掉就 return
           会把异常泄漏给后续 JNI 调用；先清再返回。 */
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        return NULL;
    }
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

/* JNI 绑定名必须与宿主 App 的桥类全名一致：本 App 的桥类是
   com.fanrenxiuxianguanyingchuan.QuickJSBridge（见 android 侧
   QuickJSBridge.kt）。此前这里沿用上游 fqapp 的 com.fqapp.fqapp
   包名，符号与 FindClass 都对不上：nativeEval 一调就
   UnsatisfiedLinkError，eval 全灭（插件 probe 与 JS 蜘蛛同桥
   同病），status 又只看 .so 能否加载、照样报可用，故障被掩盖。 */
JNIEXPORT jstring JNICALL
Java_com_fanrenxiuxianguanyingchuan_QuickJSBridge_nativeEval(JNIEnv *env, jclass clazz, jstring script, jint timeoutMs) {
    /* 加固（不是本次闪退根因）：下面的懒初始化原本无锁，冷启动
       头两个 eval 并发到达时会同时写全局桥类/方法 ID。加一把
       静态互斥锁只锁初始化块；块内只有 FindClass/GetStaticMethodID
       这类 JNI 查询、没有任何 JS 回调，不会重入，锁住安全。 */
    static pthread_mutex_t init_mutex = PTHREAD_MUTEX_INITIALIZER;
    pthread_mutex_lock(&init_mutex);
    if ((*env)->GetJavaVM(env, &g_vm) == 0 && g_bridge_class == NULL) {
        jclass local = (*env)->FindClass(env, "com/fanrenxiuxianguanyingchuan/QuickJSBridge");
        if (local) {
            g_bridge_class = (jclass)(*env)->NewGlobalRef(env, local);
            (*env)->DeleteLocalRef(env, local);
            /* 病因（初始化不清异常）：GetStaticMethodID 失败会留下
               pending 的 NoSuchMethodError，此后 JS 照跑、NewStringUTF
               照调都不在「JNI 异常挂起时的安全调用集」里，进程会被
               ART 带走。所以每个方法 ID 取完立即查 ExceptionCheck：
               失败就清掉异常并把该 ID 置 NULL——call_static_string
               本就对 NULL 方法回 NULL，JS 侧拿到的是失败而不是崩溃。
               FindClass 失败同理，在 else 分支清异常。 */
            g_fetch_method = (*env)->GetStaticMethodID(env, g_bridge_class, "fetch", "(Ljava/lang/String;)Ljava/lang/String;");
            if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); g_fetch_method = NULL; }
            g_request_method = (*env)->GetStaticMethodID(env, g_bridge_class, "requestJson", "(Ljava/lang/String;)Ljava/lang/String;");
            if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); g_request_method = NULL; }
            g_pdfa_method = (*env)->GetStaticMethodID(env, g_bridge_class, "pdfaJson", "(Ljava/lang/String;)Ljava/lang/String;");
            if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); g_pdfa_method = NULL; }
            g_pdfh_method = (*env)->GetStaticMethodID(env, g_bridge_class, "pdfhJson", "(Ljava/lang/String;)Ljava/lang/String;");
            if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); g_pdfh_method = NULL; }
            g_pd_method = (*env)->GetStaticMethodID(env, g_bridge_class, "pdJson", "(Ljava/lang/String;)Ljava/lang/String;");
            if ((*env)->ExceptionCheck(env)) { (*env)->ExceptionClear(env); g_pd_method = NULL; }
        } else if ((*env)->ExceptionCheck(env)) {
            (*env)->ExceptionClear(env);
        }
        huoyi_qjs_set_fetch(jni_fetch);
        huoyi_qjs_set_request(jni_request);
        huoyi_qjs_set_pdfa(jni_pdfa);
        huoyi_qjs_set_pdfh(jni_pdfh);
        huoyi_qjs_set_pd(jni_pd);
    }
    pthread_mutex_unlock(&init_mutex);
    (void)clazz;
    const char *text = script ? (*env)->GetStringUTFChars(env, script, NULL) : NULL;
    /* 下面两个错误信封是纯 ASCII 字面量，本来直喂 NewStringUTF
       也安全；一并走转换助手只是图全文件出向建串口径统一。 */
    if (!text) return new_string_utf(env, "{\"ok\":false,\"error\":\"empty script\"}");
    char *out = huoyi_qjs_eval(text, (int)timeoutMs);
    (*env)->ReleaseStringUTFChars(env, script, text);
    /* out 是 eval 结果信封，内容来自 JS_ToCString 的标准 UTF-8，
       含非 BMP 字符时同 call_static_string 一样必须先转换。 */
    jstring result = new_string_utf(env, out ? out : "{\"ok\":false,\"error\":\"out of memory\"}");
    huoyi_qjs_free(out);
    if (!result) {
        /* 转换助手只在内存分配失败时返回 NULL，此时退回纯 ASCII
           错误信封直建（ASCII 与 Modified UTF-8 字节相同，安全）。 */
        result = (*env)->NewStringUTF(env, "{\"ok\":false,\"error\":\"out of memory\"}");
    }
    return result;
}
