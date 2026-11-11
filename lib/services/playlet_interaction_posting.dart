import 'api_client.dart';
import 'hongguo_account_sync.dart';
import '../widgets/player/playlet_danmaku_layer.dart'
    show danmakuLengthError, danmakuMaxLength;

/// 发评论 / 回复 / 弹幕的发表结果。
enum InteractionPostStatus {
  /// 服务端已接受。
  ok,

  /// 需要登录红果账号：调用方须向用户明说，别静默失败。
  needsLogin,

  /// 其他失败（文案可直接显示）。
  failed,
}

class InteractionPostResult {
  const InteractionPostResult(this.status, [this.message = '']);

  final InteractionPostStatus status;

  /// [needsLogin]/[failed] 时的显示文案；[ok] 时为空。
  final String message;

  bool get isOk => status == InteractionPostStatus.ok;

  static const ok = InteractionPostResult(InteractionPostStatus.ok);
}

/// 发评论 / 回复 / 弹幕的发表层。
///
/// 读评论、读弹幕早已接好（`ApiClient.playletComments` /
/// `playletDanmaku`），但发的那三个接口（`addPlayletComment` /
/// `replyPlayletComment` / `addPlayletDanmaku`）在界面层一直没有
/// 调用方——本类就是那个调用方，供评论面板、回复面板与播放页的
/// 发弹幕入口共用。
///
/// 登录口径：发表走后端会话，是否要求红果账号登录由服务端在每次
/// 请求里判定，本类不自造门槛——未登录时仍尝试发送，服务端以
/// 401/403 或「请登录」类文案拒绝时才报 [InteractionPostStatus.needsLogin]，
/// 界面据此给明确提示；绝不静默失败。
class PlayletInteractionPosting {
  PlayletInteractionPosting({
    Future<void> Function({
      required String seriesId,
      required String text,
    })? postComment,
    Future<void> Function({
      required String commentId,
      required String seriesId,
      required String text,
      String replyToReplyId,
      String replyToUserId,
    })? postReply,
    Future<void> Function({
      required String vid,
      required String seriesId,
      required String text,
      required int offsetMs,
    })? postDanmaku,
    this.isSignedIn,
  }) : _postComment =
           postComment ??
           (({required String seriesId, required String text}) =>
               ApiClient.instance.addPlayletComment(seriesId, text)),
       _postReply =
           postReply ??
           (({
             required String commentId,
             required String seriesId,
             required String text,
             String replyToReplyId = '',
             String replyToUserId = '',
           }) => ApiClient.instance.replyPlayletComment(
             commentId,
             seriesId: seriesId,
             text: text,
             replyToReplyId: replyToReplyId,
             replyToUserId: replyToUserId,
           )),
       _postDanmaku =
           postDanmaku ??
           (({
             required String vid,
             required String seriesId,
             required String text,
             required int offsetMs,
           }) => ApiClient.instance.addPlayletDanmaku(
             vid,
             seriesId: seriesId,
             text: text,
             offsetMs: offsetMs,
           ));

  /// 默认实现：走 `ApiClient` 的三个发表接口，登录态读登录组。
  factory PlayletInteractionPosting.defaults() => PlayletInteractionPosting(
    isSignedIn: () => HongguoAccountService.instance.signedIn,
  );

  final Future<void> Function({
    required String seriesId,
    required String text,
  })
  _postComment;
  final Future<void> Function({
    required String commentId,
    required String seriesId,
    required String text,
    String replyToReplyId,
    String replyToUserId,
  })
  _postReply;
  final Future<void> Function({
    required String vid,
    required String seriesId,
    required String text,
    required int offsetMs,
  })
  _postDanmaku;

  /// 登录态探针（默认实现传登录组的 `signedIn`，未注入时视为未知，
  /// 不拦发表）。
  final bool Function()? isSignedIn;

  /// 当前是否已登录红果账号（未注入时视为未知，不拦发表）。
  bool get signedIn => isSignedIn?.call() ?? true;

  /// 未登录时的提示行（已登录时为空串，界面不显示）。
  String get loginHint =>
      signedIn ? '' : '未登录红果账号，发送失败时会提示登录';

  /// 发一条剧评。空内容直接拦下，不发请求。
  Future<InteractionPostResult> postComment({
    required String seriesId,
    required String text,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const InteractionPostResult(
        InteractionPostStatus.failed,
        '评论内容不能为空',
      );
    }
    try {
      await _postComment(seriesId: seriesId, text: trimmed);
      return InteractionPostResult.ok;
    } catch (e) {
      return _mapError(e, '发评论');
    }
  }

  /// 回复一条剧评。
  Future<InteractionPostResult> postReply({
    required String commentId,
    required String seriesId,
    required String text,
    String replyToReplyId = '',
    String replyToUserId = '',
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const InteractionPostResult(
        InteractionPostStatus.failed,
        '回复内容不能为空',
      );
    }
    try {
      await _postReply(
        commentId: commentId,
        seriesId: seriesId,
        text: trimmed,
        replyToReplyId: replyToReplyId,
        replyToUserId: replyToUserId,
      );
      return InteractionPostResult.ok;
    } catch (e) {
      return _mapError(e, '发回复');
    }
  }

  /// 发一条弹幕。官方单条上限 50 字（`danmakuMaxLength`），超了
  /// 在本地拦下，不发请求。
  Future<InteractionPostResult> postDanmaku({
    required String vid,
    required String seriesId,
    required String text,
    required int offsetMs,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      return const InteractionPostResult(
        InteractionPostStatus.failed,
        '弹幕内容不能为空',
      );
    }
    final lengthError = danmakuLengthError(
      trimmed.length,
      min: 1,
      max: danmakuMaxLength,
    );
    if (lengthError.isNotEmpty) {
      return InteractionPostResult(InteractionPostStatus.failed, lengthError);
    }
    try {
      await _postDanmaku(
        vid: vid,
        seriesId: seriesId,
        text: trimmed,
        offsetMs: offsetMs,
      );
      return InteractionPostResult.ok;
    } catch (e) {
      return _mapError(e, '发弹幕');
    }
  }

  InteractionPostResult _mapError(Object error, String action) {
    if (error is ApiException) {
      final status = error.statusCode;
      final message = error.message.trim();
      if (status == 401 ||
          status == 403 ||
          message.contains('登录') ||
          message.contains('未登录')) {
        return InteractionPostResult(
          InteractionPostStatus.needsLogin,
          message.isEmpty ? '请先登录红果账号后再$action' : message,
        );
      }
      return InteractionPostResult(
        InteractionPostStatus.failed,
        message.isEmpty ? '$action失败，请稍后重试' : message,
      );
    }
    return InteractionPostResult(
      InteractionPostStatus.failed,
      '$action失败，请稍后重试',
    );
  }
}
