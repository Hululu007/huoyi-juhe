#ifndef HUOYI_QUICKJS_H
#define HUOYI_QUICKJS_H

#ifdef __cplusplus
extern "C" {
#endif

typedef char *(*HuoyiFetchFunc)(const char *url);
typedef char *(*HuoyiStringFunc)(const char *arg);

void huoyi_qjs_set_fetch(HuoyiFetchFunc fn);
void huoyi_qjs_set_request(HuoyiStringFunc fn);
void huoyi_qjs_set_pdfa(HuoyiStringFunc fn);
void huoyi_qjs_set_pdfh(HuoyiStringFunc fn);
void huoyi_qjs_set_pd(HuoyiStringFunc fn);
char *huoyi_qjs_eval(const char *script, int timeout_ms);
void huoyi_qjs_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif
