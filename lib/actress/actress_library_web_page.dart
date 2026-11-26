import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/media_item.dart' show Chapter;
import '../pages/player_page.dart' show PlayerPage;
import '../services/cultivation.dart' show CultivationCategory;
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_adapter_store.dart' show LocalStore;
import 'actress_library_bridge.dart';

/// 合并演员库页的 WebView 宿主页：载入合并页 HTML、注入自家
/// fm 垫片（[kActressLibraryShim]）、把桥调用分发给
/// [ActressLibraryBridge]、把播放请求推给应用播放器
/// （[PlayerPage]，与原生女优库点播同一个播放器）。
///
/// 本页无自有顶栏：演员库 tab 在壳层已有框架，页面本体自带
/// 品牌栏/源切换条。播放请求里的 headers 目前播放器接不住
/// （PlayerPage 取流响应无 headers 字段），库内直链不需要
/// headers；个别在线站若依赖 Referer 起播，可能播不了——
/// 已知限制，见同步批报告。
class ActressLibraryWebPage extends StatefulWidget {
  const ActressLibraryWebPage({
    super.key,
    required this.html,
    required this.repository,
    required this.store,
    this.bridge,
    this.viewBuilder,
  });

  /// 合并页 HTML 全文（入口页从资源载入后传入）。
  final String html;

  /// 与原生页同口径的仓储/站表（本页当前只透传给播放记账，
  /// 保留参数是为了与原生入口签名一致、回退切换无感）。
  final AppRepository repository;
  final LocalStore store;

  /// 测试注入假桥；为空时按真播放 handler 现建。
  final ActressLibraryBridge? bridge;

  /// 测试/预览注入平台视图替身；为空时建真 WebView。
  final Widget Function(BuildContext context)? viewBuilder;

  @override
  State<ActressLibraryWebPage> createState() => _ActressLibraryWebPageState();
}

class _ActressLibraryWebPageState extends State<ActressLibraryWebPage> {
  WebViewController? _controller;
  late final ActressLibraryBridge _bridge =
      widget.bridge ?? ActressLibraryBridge(playHandler: _openPlayer);

  @override
  void initState() {
    super.initState();
    if (widget.viewBuilder != null) return;
    final controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(
        'XiuxianActressHost',
        onMessageReceived: _onBridgeMessage,
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) => _injectShim(),
          onPageFinished: (_) => _injectShim(),
        ),
      );
    _controller = controller;
    controller.loadHtmlString(widget.html);
  }

  void _injectShim() {
    _controller?.runJavaScript(kActressLibraryShim).catchError((_) {});
  }

  Future<void> _onBridgeMessage(JavaScriptMessage message) async {
    String? id;
    try {
      final decoded = jsonDecode(message.message);
      if (decoded is! Map) return;
      id = decoded['id']?.toString();
      final method = (decoded['method'] ?? '').toString();
      final rawParams = decoded['params'];
      final params = rawParams is Map
          ? Map<String, dynamic>.from(rawParams)
          : <String, dynamic>{};
      final result = await _bridge.dispatch(method, params);
      await _resolve(id, {'ok': true, 'result': result});
    } on ActressLibBridgeException catch (error) {
      await _resolve(id, {'ok': false, 'error': error.message});
    } catch (error) {
      await _resolve(id, {'ok': false, 'error': error.toString()});
    }
  }

  Future<void> _resolve(String? id, Map<String, dynamic> payload) async {
    if (id == null || id.isEmpty) return;
    final controller = _controller;
    if (controller == null) return;
    final text = jsonEncode(payload);
    await controller
        .runJavaScript(
          'window.__xiuxianActressResolve('
          '${jsonEncode(id)}, ${jsonEncode(text)})',
        )
        .catchError((_) {});
  }

  /// 播放请求 → 应用播放器：集表就是请求里的直链表，取流直接
  /// 回地址（与原生女优库点播同一条 contentLoader 形态）。
  Future<void> _openPlayer(ActressLibPlayRequest request) async {
    if (!mounted) return;
    final episodes = request.episodes;
    if (episodes.isEmpty) return;
    final chapters = [
      for (var i = 0; i < episodes.length; i++)
        Chapter(
          itemId: 'web-ep-$i',
          title: episodes[i].name.isEmpty ? '正片' : episodes[i].name,
          volumeName: '',
        ),
    ];
    final urlByChapter = {
      for (var i = 0; i < episodes.length; i++) 'web-ep-$i': episodes[i].url,
    };
    final bookKey = request.vodId.isNotEmpty
        ? request.vodId
        : '${request.title}-${episodes.first.url.hashCode}';
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlayerPage(
          bookId: 'actress-web:$bookKey',
          kind: 'video',
          title: request.title.isEmpty ? '女优库' : request.title,
          cover: request.pic,
          eps: chapters,
          startIndex: 0,
          shortSeries: false,
          cultivationCategory: CultivationCategory.video,
          contentLoader: (chapter) async => {
            'video_url': urlByChapter[chapter.itemId] ?? episodes.first.url,
            'key_hex': '',
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final seam = widget.viewBuilder;
    if (seam != null) return seam(context);
    final controller = _controller;
    if (controller == null) {
      return const ColoredBox(
        color: Colors.black,
        child: Center(child: CircularProgressIndicator()),
      );
    }
    return ColoredBox(
      color: Colors.black,
      child: WebViewWidget(controller: controller),
    );
  }
}
