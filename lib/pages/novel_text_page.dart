import 'package:flutter/material.dart';

import '../models/media_item.dart';
import '../services/nonvideo_play.dart';

class NovelTextPage extends StatefulWidget {
  const NovelTextPage({
    super.key,
    required this.seriesTitle,
    required this.episodes,
    required this.startIndex,
    required this.resolve,
    this.onIndexChanged,
    this.onAddToShelf,
    this.onSwitchSource,
  });

  final String seriesTitle;
  final List<Chapter> episodes;
  final int startIndex;
  final Future<NovelPayload> Function(Chapter episode) resolve;
  final void Function(int index)? onIndexChanged;
  final VoidCallback? onAddToShelf;
  final void Function(int index)? onSwitchSource;

  @override
  State<NovelTextPage> createState() => _NovelTextPageState();
}

class _NovelTextPageState extends State<NovelTextPage> {
  late int _index = widget.startIndex.clamp(0, widget.episodes.length - 1);
  NovelPayload? _payload;
  String? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (widget.episodes.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final payload = await widget.resolve(widget.episodes[_index]);
      if (!mounted) return;
      setState(() {
        _payload = payload;
        _loading = false;
      });
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
    widget.onIndexChanged?.call(next);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final episode = widget.episodes.isEmpty ? null : widget.episodes[_index];
    return Scaffold(
      appBar: AppBar(
        title: Text(episode?.title ?? widget.seriesTitle),
        actions: [
          if (widget.onAddToShelf != null)
            IconButton(
              icon: const Icon(Icons.bookmark_add_outlined),
              tooltip: '加入书架',
              onPressed: widget.onAddToShelf,
            ),
          if (widget.onSwitchSource != null)
            IconButton(
              icon: const Icon(Icons.swap_horiz),
              tooltip: '换源',
              onPressed: () => widget.onSwitchSource!(_index),
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
                    : SingleChildScrollView(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            if ((_payload?.title ?? '').isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  _payload!.title,
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                              ),
                            SelectableText(
                              _payload?.content ?? '',
                              style: const TextStyle(fontSize: 16, height: 1.7),
                            ),
                          ],
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
