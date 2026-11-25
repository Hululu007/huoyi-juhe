import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../services/site_thumb_cache.dart';

/// 站点透视缩图（魔蚁同步批 C1）：卡片里 16:9 的封面区。
///
/// 宫格是 shrinkWrap 嵌在外层 ListView 里，首帧全区卡片都会建出来，
/// 只靠 initState 拉取会在打开瞬间打遍全区站点——所以多一道可见性
/// gate：卡片进入最外层滚动视口（含上下 200px 预取边距）才触发
/// 取数；不可见时在外层滚动位置上挂一次监听，滚动后再查。
///
/// 任一环失败（取数回 null、图片加载失败）回落 [fallback]（站标 /
/// 首字块），卡片形状不变、不塌、不挂假图；失败不记缓存，下次打开
/// 弹窗重试，本次弹窗内靠 _done 不再重拉。
class SiteThumbImage extends StatefulWidget {
  const SiteThumbImage({
    super.key,
    required this.siteId,
    required this.fallback,
    this.cache,
    this.fetcher,
    this.imageBuilder,
  });

  final String siteId;

  /// 无图时的回落形态（站名首字块等），由调用方按自家卡片样式给。
  final Widget fallback;

  /// 封面地址缓存；与 [fetcher] 都传才拉缩图，缺一即只显示回落。
  final SiteThumbCache? cache;
  final SiteThumbFetcher? fetcher;

  /// 图片渲染缝（测试 / 预览注入假图用）；为空走 CachedNetworkImage。
  final Widget Function(String url)? imageBuilder;

  @override
  State<SiteThumbImage> createState() => _SiteThumbImageState();
}

class _SiteThumbImageState extends State<SiteThumbImage> {
  String? _url;
  bool _started = false;
  bool _done = false;
  ScrollPosition? _listenedPosition;

  @override
  void initState() {
    super.initState();
    _url = widget.cache?.cachedUrl(widget.siteId);
    if (_url != null) {
      _done = true;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
  }

  @override
  void didUpdateWidget(SiteThumbImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.siteId != widget.siteId ||
        !identical(oldWidget.cache, widget.cache) ||
        !identical(oldWidget.fetcher, widget.fetcher)) {
      _detachScrollListener();
      _url = widget.cache?.cachedUrl(widget.siteId);
      _started = false;
      _done = _url != null;
      if (_url == null) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
      }
    }
  }

  @override
  void dispose() {
    _detachScrollListener();
    super.dispose();
  }

  void _detachScrollListener() {
    _listenedPosition?.removeListener(_onScroll);
    _listenedPosition = null;
  }

  /// 沿 Scrollable 祖先逐层往外找，取最外层的滚动位置：宫格自己
  /// 的 Scrollable 从不滚动，用它判可见是错的。
  ScrollPosition? _outerScrollPosition() {
    ScrollPosition? outermost;
    var element = context as Element;
    // 从当前上下文向上遍历祖先，收集所有 Scrollable 的 position。
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Scrollable) {
        final state = ancestor is StatefulElement
            ? ancestor.state
            : null;
        if (state is ScrollableState) {
          outermost = state.position;
        }
      }
      return true;
    });
    return outermost;
  }

  bool _isVisible() {
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final position = _outerScrollPosition();
    if (position == null) return true;
    final viewportObject =
        position.context.notificationContext?.findRenderObject();
    if (viewportObject is! RenderBox || !viewportObject.hasSize) return true;
    final topLeft = renderObject.localToGlobal(Offset.zero);
    final viewportTopLeft = viewportObject.localToGlobal(Offset.zero);
    const margin = 200.0;
    final cardTop = topLeft.dy;
    final cardBottom = cardTop + renderObject.size.height;
    final viewTop = viewportTopLeft.dy - margin;
    final viewBottom = viewportTopLeft.dy + viewportObject.size.height + margin;
    return cardBottom >= viewTop && cardTop <= viewBottom;
  }

  void _onScroll() {
    // 通知到达时布局还是滚前那帧，排到下一帧布局完成再查位置。
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeFetch());
  }

  void _maybeFetch() {
    if (!mounted || _started || _done) return;
    final cache = widget.cache;
    final fetcher = widget.fetcher;
    if (cache == null || fetcher == null) {
      _done = true;
      return;
    }
    final cached = cache.cachedUrl(widget.siteId);
    if (cached != null) {
      setState(() {
        _url = cached;
        _done = true;
      });
      return;
    }
    if (!_isVisible()) {
      final position = _outerScrollPosition();
      if (position != null && !identical(position, _listenedPosition)) {
        _detachScrollListener();
        _listenedPosition = position;
        position.addListener(_onScroll);
      }
      return;
    }
    _detachScrollListener();
    _started = true;
    unawaited(_load(cache, fetcher));
  }

  Future<void> _load(SiteThumbCache cache, SiteThumbFetcher fetcher) async {
    final url = await cache.thumbUrlFor(widget.siteId, fetcher);
    if (!mounted) return;
    setState(() {
      _url = url;
      _done = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = _url;
    if (url == null || url.isEmpty) return widget.fallback;
    final builder = widget.imageBuilder;
    if (builder != null) return builder(url);
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      placeholder: (context, _) => widget.fallback,
      errorWidget: (context, _, _) => widget.fallback,
    );
  }
}
