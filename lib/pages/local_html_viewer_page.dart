import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../widgets/series_detail/moyi_detail_theme.dart';

/// 本地 HTML 查看页：只负责把已导入的本地 HTML 文件在应用内浏览器里
/// 打开看原文。不是站、不解析、不进影视区、不提供分类与播放。
class LocalHtmlViewerPage extends StatefulWidget {
  const LocalHtmlViewerPage({
    super.key,
    required this.title,
    required this.filePath,
  });

  final String title;
  final String filePath;

  @override
  State<LocalHtmlViewerPage> createState() => _LocalHtmlViewerPageState();
}

class _LocalHtmlViewerPageState extends State<LocalHtmlViewerPage> {
  WebViewController? _controller;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final controller = WebViewController()
        ..setJavaScriptMode(JavaScriptMode.unrestricted);
      await controller.loadFile(widget.filePath);
      if (mounted) setState(() => _controller = controller);
    } catch (e) {
      if (mounted) setState(() => _error = '打不开本地网页：$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: Text(widget.title),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
        ),
        body: _error != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: moyiBodyOnDark),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : _controller == null
            ? const Center(child: CircularProgressIndicator())
            : WebViewWidget(controller: _controller!),
      ),
    );
  }
}
