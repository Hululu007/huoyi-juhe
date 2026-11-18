import 'dart:async';

import 'package:flutter/material.dart';

import '../reader/reader_page_curl.dart';

/// 漫画翻页模式的卷页翻页器：与小说 ReaderPagedView 的 curl 模式同一套
/// 交互、同一个 [ReaderPageCurl]（上游漫画没有卷页，这里是适配，不是拉取）：
/// - PageView 本身不滑动（NeverScrollableScrollPhysics），翻页只由覆盖层卷；
/// - 拖拽 6px 后锁定方向，手指位置 1:1 写进卷页进度；
/// - 松手按最后一次移动方向定去留（Legado 规则：往回退了就卷回，否则
///   翻完），无距离阈值、无甩动速度判定；
/// - 动画落定后按值（>0.5）跳页，覆盖层随即撤掉。
///
/// 点按不拦截：识别器只注册水平拖拽，点按照常透传给图块（打开大图）。
/// 首尾边缘拖拽不卷页、不切章（漫画切章走章节栏/目录，不替用户切章）。
class ComicCurlPager extends StatefulWidget {
  const ComicCurlPager({
    super.key,
    required this.controller,
    required this.itemCount,
    required this.itemBuilder,
    required this.onPageChanged,
    this.backgroundColor,
  });

  final PageController controller;
  final int itemCount;
  final Widget Function(int index) itemBuilder;
  final ValueChanged<int> onPageChanged;

  /// 卷页背底：不传则跟随当前主题的 Scaffold 背景色（浅色主题白底、深色
  /// 主题深底），卷起时露出的底色与页面周围一致，不因写死颜色变样。
  final Color? backgroundColor;

  @override
  State<ComicCurlPager> createState() => _ComicCurlPagerState();
}

/// One curl turn: the pages the peel travels between. The progress lives on
/// the animation controller (settle animation) or is written to it directly
/// (drag turns), and the overlay reads it as-is. Same model as the novel
/// pager's curl turn.
class _ComicCurlTurn {
  final int direction;
  final int fromIndex;
  final int toIndex;

  const _ComicCurlTurn({
    required this.direction,
    required this.fromIndex,
    required this.toIndex,
  });
}

class _ComicCurlPagerState extends State<ComicCurlPager>
    with SingleTickerProviderStateMixin {
  late final AnimationController _curlAnimation;
  _ComicCurlTurn? _curlTurn;
  bool _turning = false;
  bool _curlDragging = false;
  double _curlDragStartDx = 0;
  double _curlDragLastDx = 0;
  bool _curlDragLocked = false;
  bool _curlDragCancelled = false;

  @override
  void initState() {
    super.initState();
    _curlAnimation = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    )..addStatusListener(_onCurlStatus);
  }

  @override
  void didUpdateWidget(ComicCurlPager oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.controller, oldWidget.controller) ||
        widget.itemCount != oldWidget.itemCount) {
      // 换章/换控制器：进行中的卷页作废，动画复位。
      _curlTurn = null;
      _turning = false;
      _curlDragging = false;
      _curlDragLocked = false;
      _curlDragCancelled = false;
      _curlAnimation.reset();
    }
  }

  @override
  void dispose() {
    _curlAnimation
      ..removeStatusListener(_onCurlStatus)
      ..dispose();
    super.dispose();
  }

  /// Ends a curl turn. Decided by VALUE, not by status: the controller's
  /// terminal status follows its sticky direction (last forward/reverse),
  /// not the value it settled at. Drags only write `.value`, so a cancel
  /// `animateTo(0)` still reports `completed` — jumping on status alone
  /// would turn the page even when the curl visibly settled back to 0.
  /// Same guard as the novel pager.
  void _onCurlStatus(AnimationStatus status) {
    final turn = _curlTurn;
    if (turn == null || _curlDragging) return;
    if (status == AnimationStatus.completed ||
        status == AnimationStatus.dismissed) {
      if (_curlAnimation.value > 0.5) {
        widget.controller.jumpToPage(turn.toIndex);
      }
      // Settled at 1: the jump already tells the host to rebuild;
      // settled at 0: a cancelled drag curl, nothing else rebuilds, so
      // the overlay is dropped here.
      _curlTurn = null;
      _turning = false;
      if (mounted) setState(() {});
    }
  }

  int get _currentPage {
    final controller = widget.controller;
    if (controller.hasClients) {
      final page = controller.page;
      if (page != null && page.isFinite) return page.round();
    }
    return controller.initialPage;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth > 0 ? constraints.maxWidth : 1.0;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (details) {
            if (_turning) return;
            _curlDragStartDx = details.globalPosition.dx;
            _curlDragLastDx = details.globalPosition.dx;
            _curlDragLocked = false;
            _curlDragCancelled = false;
          },
          onHorizontalDragUpdate: (details) {
            // 动画中的卷页不接受拖拽转向。
            if (_curlTurn != null && !_curlDragging) return;
            final dx = details.globalPosition.dx;
            final prevDx = _curlDragLastDx;
            _curlDragLastDx = dx;
            final delta = dx - _curlDragStartDx;
            if (!_curlDragLocked) {
              if (delta.abs() < 6) return;
              final direction = delta < 0 ? 1 : -1;
              final current = _currentPage;
              final target = current + direction;
              _curlDragLocked = true;
              if (target < 0 || target >= widget.itemCount) {
                // 首尾边缘：不卷页（也不切章）。
                return;
              }
              _curlDragging = true;
              _turning = true;
              setState(() {
                _curlTurn = _ComicCurlTurn(
                  direction: direction,
                  fromIndex: current,
                  toIndex: target,
                );
              });
            }
            if (_curlTurn == null) return;
            final progress = (delta.abs() / width).clamp(0.0, 1.0);
            // Legado's isCancel, recomputed on every move from the finger's
            // absolute x: forward turns retreat when dx grows, backward
            // turns when dx shrinks. A retreat flips it on, a renewed
            // advance flips it back off. The 2px deadband absorbs touch
            // jitter. Same as the novel pager.
            final direction = _curlTurn!.direction;
            final retreated = direction > 0 ? dx > prevDx + 2 : dx < prevDx - 2;
            final advanced = direction > 0 ? dx < prevDx - 2 : dx > prevDx + 2;
            if (retreated) {
              _curlDragCancelled = true;
            } else if (advanced) {
              _curlDragCancelled = false;
            }
            // Painted as-is: no easing between the finger and the fold.
            _curlAnimation.value = progress;
          },
          onHorizontalDragEnd: (_) {
            final turn = _curlTurn;
            if (turn == null || !_curlDragging) return;
            _curlDragging = false;
            // Legado: no distance threshold, no fling velocity — the
            // release completes unless the last move retreated.
            final complete = !_curlDragCancelled;
            final progress = _curlAnimation.value;
            final remaining = complete ? 1 - progress : progress;
            // Duration scales with the remaining distance (same as the
            // novel pager: 300ms across the full width, clamped 60-300ms).
            final duration = Duration(
              milliseconds: (remaining * 300).round().clamp(60, 300),
            );
            unawaited(
              _curlAnimation.animateTo(
                complete ? 1 : 0,
                duration: duration,
                curve: Curves.linear,
              ),
            );
          },
          onHorizontalDragCancel: () {
            // 拖拽被打断（如手势冲突）：卷回原页，不留半卷的覆盖层。
            final turn = _curlTurn;
            if (turn == null || !_curlDragging) return;
            _curlDragging = false;
            unawaited(
              _curlAnimation.animateTo(
                0,
                duration: const Duration(milliseconds: 200),
                curve: Curves.linear,
              ),
            );
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              PageView.builder(
                key: const ValueKey('comic-reader-paged-view'),
                controller: widget.controller,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: widget.itemCount,
                onPageChanged: widget.onPageChanged,
                itemBuilder: (context, index) => widget.itemBuilder(index),
              ),
              if (_curlTurn != null)
                Positioned.fill(
                  child: IgnorePointer(child: _buildCurlOverlay()),
                ),
            ],
          ),
        );
      },
    );
  }

  /// 卷页覆盖层：去页卷到目标页上。
  Widget _buildCurlOverlay() {
    final turn = _curlTurn;
    if (turn == null) return const SizedBox.shrink();
    return AnimatedBuilder(
      animation: _curlAnimation,
      builder: (context, _) => ReaderPageCurl(
        outgoing: widget.itemBuilder(turn.fromIndex),
        incoming: widget.itemBuilder(turn.toIndex),
        progress: _curlAnimation.value,
        forward: turn.direction >= 0,
        backgroundColor:
            widget.backgroundColor ?? Theme.of(context).scaffoldBackgroundColor,
      ),
    );
  }
}
