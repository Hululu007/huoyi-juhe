// 演员库错误文案中文化边界（2026-11-27 用户令）：模块内所有
// 会上屏的错误提示一律中文人话，异常原文（英文异常类名/消息，
// 如「Bad state: 详情为空」）绝不直出到界面。UI 层拿错误时一律
// 过本文件的映射：
// - [AppFailure]：其 message 本就是中文人话（适配层/在线源统一
//   约定），原样用；
// - 其余任何异常/错误字符串：吞掉原文，回调用方给的中文兜底。
import 'actress_adapter_models.dart' show AppFailure;

/// 把任意错误映射成可上屏的中文文案。[fallback] 是本场景的
/// 中文兜底（如「详情没拉到，点按重试」）。
String actressErrorText(Object? error, {required String fallback}) {
  if (error is AppFailure) {
    final message = error.message.trim();
    if (message.isNotEmpty) return message;
    return fallback;
  }
  return fallback;
}

/// 库查询结果里的 error 字段同样过界：只放行中文文案，含英文字
/// 母的原文（异常类名、堆栈片段等）一律换成 [fallback]。
String actressDbErrorText(Object? raw, {required String fallback}) {
  final text = (raw ?? '').toString().trim();
  if (text.isEmpty) return fallback;
  if (RegExp(r'[A-Za-z]').hasMatch(text)) return fallback;
  return text;
}
