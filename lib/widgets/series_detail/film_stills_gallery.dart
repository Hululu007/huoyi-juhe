import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../services/api_client.dart';
import 'moyi_detail_theme.dart';

/// 影视区剧照全览页：网格看全部剧照，点一张进全屏看图。
///
/// 入参 [stills] 是已算好的生效剧照（站详情 + 补全合并去重后），
/// 本页只展示、不再取数；地址相对时走 [ApiClient.absoluteUrl] 补全，
/// 与详情页剧照横排同一口径。
class FilmStillsGalleryPage extends StatelessWidget {
  const FilmStillsGalleryPage({
    super.key,
    required this.stills,
    required this.title,
  });

  final List<String> stills;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const ValueKey('film-stills-gallery-page'),
      backgroundColor: const Color(0xFF0E0724),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        foregroundColor: Colors.white,
        elevation: 0,
        title: Text(
          title.isEmpty ? '本片剧照' : title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 16, color: Colors.white),
        ),
      ),
      body: GridView.builder(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
          crossAxisCount: 2,
          crossAxisSpacing: 10,
          mainAxisSpacing: 10,
          childAspectRatio: 16 / 10,
        ),
        itemCount: stills.length,
        itemBuilder: (_, i) {
          final url = ApiClient.instance.absoluteUrl(stills[i]);
          return GestureDetector(
            key: ValueKey('film-stills-gallery-item-$i'),
            onTap: () => _openStill(context, url),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: moyiPurple.withValues(alpha: 0.55),
                  width: 1,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.cover,
                placeholder: (_, _) =>
                    const ColoredBox(color: Color(0xFF262543)),
                errorWidget: (_, _, _) => const ColoredBox(
                  color: Color(0xFF262543),
                  child: Icon(Icons.broken_image, color: Colors.white54),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  /// 全屏看图（与详情页 `_openStill` 同一套做法）：黑底弹窗 +
  /// 可缩放 + 右上角关闭。
  void _openStill(BuildContext context, String url) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.black,
        insetPadding: const EdgeInsets.all(16),
        child: Stack(
          children: [
            InteractiveViewer(
              child: CachedNetworkImage(
                imageUrl: url,
                fit: BoxFit.contain,
                errorWidget: (_, _, _) => const Padding(
                  padding: EdgeInsets.all(32),
                  child: Text('剧照加载失败', style: TextStyle(color: Colors.white)),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.pop(dialogContext),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
