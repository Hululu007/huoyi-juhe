import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/chapter_media.dart';
import '../../services/audio_floating_routes.dart';
import '../series_detail/moyi_detail_theme.dart';
import 'comic_image_tile.dart';

/// 漫画大图查看器（点单页进入，可双指缩放）。
///
/// chrome 走魔蚁深紫蓝渐变底、白字；关闭键用 Lucide x。官方
/// PreviewImageActivity 会隐藏悬浮播放胶囊，这里保持。
class ComicImageViewer extends StatelessWidget {
  final ComicImage image;
  final int pageNumber;
  final double aspectRatio;
  final ImageProvider<Object> Function(ComicImage image)? providerFactory;

  const ComicImageViewer({
    super.key,
    required this.image,
    required this.pageNumber,
    required this.aspectRatio,
    this.providerFactory,
  });

  @override
  Widget build(BuildContext context) {
    AudioFloatingRouteScope.configure(context, hidden: true);
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          '第 $pageNumber 页',
          style: const TextStyle(color: Colors.white),
        ),
        leading: IconButton(
          tooltip: '关闭大图',
          color: Colors.white,
          icon: const Icon(LucideIcons.x, size: 22),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: MoyiPageBackground(
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final width = constraints.maxWidth;
              return InteractiveViewer(
                key: const ValueKey('comic-image-zoom'),
                constrained: false,
                minScale: 1,
                maxScale: 5,
                child: SizedBox(
                  width: width,
                  height: math.max(width / aspectRatio, constraints.maxHeight),
                  child: ComicImageTile(
                    image: image,
                    pageNumber: pageNumber,
                    providerFactory: providerFactory,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}
