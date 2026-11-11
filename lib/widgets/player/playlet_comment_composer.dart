import 'package:flutter/material.dart';

import '../series_detail/moyi_detail_theme.dart';

/// 评论 / 回复 / 弹幕共用的底部输入条。
///
/// - 空内容本地拦下，不发请求；
/// - 发送中禁用输入与按钮，避免重复提交；
/// - 发表层返回的文案（登录提示、服务端报错）直接显示在输入条
///   上方，不静默失败；
/// - 成功后清空输入并回调 [onSent]（面板刷新列表、弹幕页注入本地
///   弹幕、弹窗页关闭都由调用方决定，本组件不替调用方导航）。
class PlayletCommentComposer extends StatefulWidget {
  const PlayletCommentComposer({
    super.key,
    required this.hintText,
    required this.onSend,
    this.onSent,
    this.maxLength = 0,
    this.sendLabel = '发送',
    this.loginHint = '',
  });

  /// 输入框占位文案。
  final String hintText;

  /// 发送：返回 null 表示服务端已接受，返回文案表示失败原因。
  final Future<String?> Function(String text) onSend;

  /// 发送成功后的回调（刷新列表等），带上刚发出去的文本。
  final void Function(String text)? onSent;

  /// 0 = 不限（剧评/回复）；弹幕传 50（官方单条上限）。
  final int maxLength;

  final String sendLabel;

  /// 未登录时的提示行（空串不显示）。
  final String loginHint;

  @override
  State<PlayletCommentComposer> createState() =>
      _PlayletCommentComposerState();
}

class _PlayletCommentComposerState extends State<PlayletCommentComposer> {
  final _controller = TextEditingController();
  bool _sending = false;
  String _error = '';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_sending) return;
    final text = _controller.text.trim();
    if (text.isEmpty) {
      setState(() => _error = '内容不能为空');
      return;
    }
    setState(() {
      _sending = true;
      _error = '';
    });
    final failure = await widget.onSend(text);
    if (!mounted) return;
    setState(() => _sending = false);
    if (failure != null) {
      setState(() => _error = failure);
      return;
    }
    _controller.clear();
    widget.onSent?.call(text);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        color: moyiDarkCardFill,
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.08))),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.loginHint.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                widget.loginHint,
                key: const ValueKey('playlet-composer-login-hint'),
                style: TextStyle(fontSize: 12, color: moyiMutedOnDark),
              ),
            ),
          if (_error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                _error,
                key: const ValueKey('playlet-composer-error'),
                style: const TextStyle(fontSize: 12, color: Color(0xFFFF8A80)),
              ),
            ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('playlet-composer-field'),
                  controller: _controller,
                  enabled: !_sending,
                  maxLength: widget.maxLength > 0 ? widget.maxLength : null,
                  maxLines: 3,
                  minLines: 1,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: InputDecoration(
                    hintText: widget.hintText,
                    hintStyle: TextStyle(color: moyiMutedOnDark),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(18),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 10,
                    ),
                    counterText: '',
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              const SizedBox(width: 8),
              TextButton(
                key: const ValueKey('playlet-composer-send'),
                onPressed: _sending ? null : _send,
                child: _sending
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text(widget.sendLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
