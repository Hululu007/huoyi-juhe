import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'actress_adapter_http.dart' show ContentHttp;
import 'actress_javdb_api.dart' show javdbDecryptImageBytes, javdbIsImageUrl;

/// 演员库通用网络图：JavDB 图床（jdbstatic.com /
/// spfcas.com）的图字节带
/// XOR 加密，必须先取字节解密再显示（普通 Image.network 解
/// 不出）；其余图走 Image.network。两种路径都带加载占位与
/// 失败占位（失败显示深色块 + 可选点按重试），不许出现「看
/// 起来像没图」的无声空白（2026-11-27 sigl-020 海报实报：
/// 地址完好、弱网卡在加载中，旧页没进度没重试像没封面）。
class ActressNetImage extends StatelessWidget {
  const ActressNetImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.onRetry,
  });

  final String url;
  final BoxFit fit;

  /// 失败占位上的点按回调（海报位传重载，其余可不传）。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return const _ImagePlaceholder();
    if (javdbIsImageUrl(url)) {
      return _JavdbDecodedImage(url: url, fit: fit, onRetry: onRetry);
    }
    return Image.network(
      url,
      fit: fit,
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const _ImagePlaceholder(loading: true);
      },
      errorBuilder: (context, error, stack) =>
          _ImagePlaceholder(onRetry: onRetry),
    );
  }
}

class _ImagePlaceholder extends StatelessWidget {
  const _ImagePlaceholder({this.loading = false, this.onRetry});

  final bool loading;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onRetry,
      child: Container(
        color: const Color(0xFF1B1426),
        alignment: Alignment.center,
        child: loading
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                onRetry == null
                    ? Icons.image_not_supported_outlined
                    : Icons.refresh_rounded,
                color: Colors.white24,
                size: 26,
              ),
      ),
    );
  }
}

/// JavDB 图床图：取原始字节 → XOR 解密 → 内存图。进程内简
/// 单缓存（同一地址不重复取）。
class _JavdbDecodedImage extends StatefulWidget {
  const _JavdbDecodedImage({
    required this.url,
    required this.fit,
    this.onRetry,
  });

  final String url;
  final BoxFit fit;
  final VoidCallback? onRetry;

  @override
  State<_JavdbDecodedImage> createState() => _JavdbDecodedImageState();
}

class _JavdbDecodedImageState extends State<_JavdbDecodedImage> {
  static final _cache = <String, Uint8List>{};
  static ContentHttp? _http;

  Uint8List? _bytes;
  var _failed = false;
  var _stamp = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(_JavdbDecodedImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) _load();
  }

  Future<void> _load() async {
    final url = widget.url;
    final cached = _cache[url];
    if (cached != null) {
      setState(() {
        _bytes = cached;
        _failed = false;
      });
      return;
    }
    final stamp = ++_stamp;
    try {
      final http = _http ??= ContentHttp();
      // 取图带 Referer（jar 版 picProxy 口径）：图床认来源，
      // 不带可能直接回绝。超时 10 秒封顶：死地址不许让占位
      // 转圈转到底（与头像补全链同口径）。
      final raw = await http.getRaw(
        url,
        headers: const {'Referer': 'https://javdb.com/'},
        timeout: const Duration(seconds: 10),
      );
      if (!mounted || stamp != _stamp) return;
      if (raw.statusCode < 200 || raw.statusCode >= 300) {
        setState(() => _failed = true);
        return;
      }
      final decoded = javdbDecryptImageBytes(raw.bodyBytes);
      _cache[url] = decoded;
      setState(() {
        _bytes = decoded;
        _failed = false;
      });
    } catch (_) {
      if (!mounted || stamp != _stamp) return;
      setState(() => _failed = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bytes = _bytes;
    if (bytes != null) {
      return Image.memory(
        bytes,
        fit: widget.fit,
        errorBuilder: (context, error, stack) =>
            _ImagePlaceholder(onRetry: widget.onRetry),
      );
    }
    if (_failed) {
      return _ImagePlaceholder(
        onRetry:
            widget.onRetry ??
            () {
              setState(() => _failed = false);
              _load();
            },
      );
    }
    return const _ImagePlaceholder(loading: true);
  }
}
