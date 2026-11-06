import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

/// 网页引擎取页：给程序化客户端过不去的指纹门站点用（目前只有伍果）。
/// 原理是真浏览器指纹：把地址放进系统 WebView 里跑 JS，再把渲染后的
/// 整页 HTML 拿回来，交给原有解析逻辑。WebView 必须挂在界面树里才能
/// 加载，所以取页时往全局导航的 Overlay 里插一个 1 像素的离屏页，
/// 取完即摘掉，不跳转、不打扰当前页面。
/// 主树在启动时用 [bind] 把导航键交过来；没绑定时取页直接报错，
/// 不静默回落到会被 403 的程序化请求。
class WebViewPageFetcher {
  WebViewPageFetcher._();

  static GlobalKey<NavigatorState>? _navigatorKey;

  static void bind(GlobalKey<NavigatorState> key) {
    _navigatorKey = key;
  }

  static Future<String> fetch(String url) async {
    final overlay = _navigatorKey?.currentState?.overlay;
    if (overlay == null) {
      throw StateError('网页引擎未就绪');
    }
    try {
      return await _fetchWithOverlay(overlay, url);
    } on MissingPluginException {
      throw StateError('当前平台不支持网页引擎');
    }
  }

  static Future<String> _fetchWithOverlay(OverlayState overlay, String url) async {
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted);
    final loaded = Completer<void>();
    Object? loadError;
    controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (_) {
          if (!loaded.isCompleted) loaded.complete();
        },
        onWebResourceError: (error) {
          loadError ??= StateError('网页加载失败：${error.description}');
          if (!loaded.isCompleted) loaded.complete();
        },
      ),
    );
    await controller.loadRequest(Uri.parse(url));
    final entry = OverlayEntry(
      builder: (_) => Positioned(
        left: -10,
        top: -10,
        width: 1,
        height: 1,
        child: WebViewWidget(controller: controller),
      ),
    );
    overlay.insert(entry);
    try {
      await loaded.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () {
          throw StateError('网页加载超时：$url');
        },
      );
      if (loadError != null) throw loadError!;
      final result = await controller.runJavaScriptReturningResult(
        'document.documentElement.outerHTML',
      );
      if (result is! String || result.isEmpty) {
        throw StateError('网页未返回内容');
      }
      // Android 侧字符串结果可能包一层 JSON 引号，做一次还原。
      if (result.length >= 2 &&
          result.startsWith('"') &&
          result.endsWith('"')) {
        try {
          final decoded = jsonDecode(result);
          if (decoded is String && decoded.isNotEmpty) return decoded;
        } catch (_) {
          // 不是 JSON 编码，原样返回。
        }
      }
      return result;
    } finally {
      entry.remove();
    }
  }
}
