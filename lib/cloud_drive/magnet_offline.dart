/// 磁力点按 → 115 离线提交的判定单元（演员库详情页下载链接区用）。
///
/// 只做判定与文案组装，不碰网络、不碰 BuildContext：登录判据与
/// 提交函数都由调用方注入（生产走引擎的 pan115LoggedIn /
/// pan115OfflineClient().submitOffline，测试注入假件）。详情页
/// 拿到结果后自己负责弹提示/弹登录引导/管提交中状态。
library;

import 'cloud_115_offline.dart';
import 'cloud_providers.dart';

/// 一次磁力点按的结果分类。
enum MagnetTapOutcome {
  /// 已提交成功。
  submitted,

  /// 提交失败（结果带可直接上屏的中文原因文案）。
  failed,

  /// 未登录 115：调用方弹「未登录 115 网盘」引导弹窗。
  notLoggedIn,

  /// 已有一次提交在飞：本次点按被防重复点拦下，调用方忽略。
  busy,
}

/// 磁力点按结果：分类 + 上屏文案（notLoggedIn/busy 时为空，
/// 文案由调用方按各自口径出）。
class MagnetTapResult {
  const MagnetTapResult(this.outcome, [this.message = '']);

  final MagnetTapOutcome outcome;
  final String message;
}

/// 磁力离线提交器：防重复点（提交在飞时后续点按回 busy、
/// 不重复发请求）也收在这里，页面只需按结果出提示。
class MagnetOfflineSubmitter {
  MagnetOfflineSubmitter({
    required this.isLoggedIn,
    required this.submit,
  });

  /// 115 是否已登录（与引擎 pan115LoggedIn 同口径：凭证存储
  /// 里 pan115 的 cookie 非空）。
  final Future<bool> Function() isLoggedIn;

  /// 提交一条磁力到 115 离线下载。
  final Future<Pan115SubmitResult> Function(String url) submit;

  bool _busy = false;

  /// 是否有提交在飞（页面据此给对应条目转圈/禁用）。
  bool get busy => _busy;

  static const successMessage = '已提交到 115 离线下载';
  static const genericFailureMessage = '提交失败，请稍后重试';

  /// 失败文案：异常自带中文信息（CloudDriveException）优先，
  /// 拼成「提交失败：<原因>」；拿不到就用通用兜底，不许静默、
  /// 不把异常原文（可能带请求地址）糊上屏。
  static String failureMessageOf(Object error) {
    if (error is CloudDriveException && error.message.isNotEmpty) {
      return '提交失败：${error.message}';
    }
    return genericFailureMessage;
  }

  Future<MagnetTapResult> tap(String url) async {
    if (_busy) return const MagnetTapResult(MagnetTapOutcome.busy);
    bool loggedIn;
    try {
      loggedIn = await isLoggedIn();
    } catch (_) {
      // 登录判据本身读不出来，按未登录引导处理，不静默。
      loggedIn = false;
    }
    if (!loggedIn) {
      return const MagnetTapResult(MagnetTapOutcome.notLoggedIn);
    }
    _busy = true;
    try {
      final result = await submit(url);
      if (result.ok) {
        return const MagnetTapResult(
          MagnetTapOutcome.submitted,
          successMessage,
        );
      }
      // 接口明确回失败又没给原因：用通用兜底文案。
      return const MagnetTapResult(
        MagnetTapOutcome.failed,
        genericFailureMessage,
      );
    } catch (e) {
      return MagnetTapResult(MagnetTapOutcome.failed, failureMessageOf(e));
    } finally {
      _busy = false;
    }
  }
}
