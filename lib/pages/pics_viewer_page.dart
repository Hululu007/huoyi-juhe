import 'package:flutter/material.dart';

import '../models/media_item.dart';

class PicsViewerPage extends StatefulWidget {
  const PicsViewerPage({
    super.key,
    required this.seriesTitle,
    required this.episodes,
    required this.startIndex,
    required this.resolve,
  });

  final String seriesTitle;
  final List<Chapter> episodes;
  final int startIndex;
  final Future<List<String>> Function(Chapter episode) resolve;

  @override
  State<PicsViewerPage> createState() => _PicsViewerPageState();
}

class _PicsViewerPageState extends State<PicsViewerPage> {
  late int _index = widget.startIndex.clamp(0, widget.episodes.length - 1);
  List<String> _urls = [];
  String? _error;
  bool _loading = false;
  int _page = 0;
  final PageController _controller = PageController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    if (widget.episodes.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
      _page = 0;
    });
    try {
      final urls = await widget.resolve(widget.episodes[_index]);
      if (!mounted) return;
      setState(() {
        _urls = urls;
        _loading = false;
      });
      if (_controller.hasClients) _controller.jumpToPage(0);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error.toString();
        _loading = false;
      });
    }
  }

  void _jump(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.episodes.length) return;
    setState(() => _index = next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episodes.isEmpty ? null : widget.episodes[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(episode?.title ?? widget.seriesTitle),
        actions: [
          if (_urls.isNotEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Text('${_page + 1} / ${_urls.length}'),
              ),
            ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? Center(child: Text('加载失败：$_error'))
                    : _urls.isEmpty
                        ? const Center(child: Text('本章没有图片'))
                        : PageView.builder(
                            controller: _controller,
                            itemCount: _urls.length,
                            onPageChanged: (page) =>
                                setState(() => _page = page),
                            itemBuilder: (_, i) => InteractiveViewer(
                              child: Center(
                                child: Image.network(
                                  _urls[i],
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, _, _) =>
                                      const Text('图片加载失败'),
                                ),
                              ),
                            ),
                          ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  TextButton(
                    onPressed: _index > 0 ? () => _jump(-1) : null,
                    child: const Text('上一章'),
                  ),
                  Expanded(
                    child: Text(
                      widget.episodes.isEmpty
                          ? ''
                          : '${_index + 1} / ${widget.episodes.length}',
                      textAlign: TextAlign.center,
                    ),
                  ),
                  TextButton(
                    onPressed: _index < widget.episodes.length - 1
                        ? () => _jump(1)
                        : null,
                    child: const Text('下一章'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
