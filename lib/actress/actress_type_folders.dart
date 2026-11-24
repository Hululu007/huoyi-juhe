import 'package:flutter/material.dart';

import 'actress_film_library.dart';
import 'actress_neon.dart';

/// 类型文件夹网格（2026-11-24 文件夹视图）：照用户给的百合DB
/// 截图——三列文件夹卡片，每卡一个黄色文件夹图标 + “共N条” +
/// 类型名；点卡进该类型视频。颜色走本模块霓虹主题（深紫底 +
/// 紫边），只有文件夹图标沿用参考图的黄色。
/// 文件夹就是 videos.type_name 分组计数，与 video_category
/// 主分类（有码/无码/国产…）是两套维度，别混。
class ActressTypeFolderGrid extends StatelessWidget {
  const ActressTypeFolderGrid({
    super.key,
    required this.folders,
    required this.onOpen,
    this.covers = const {},
  });

  /// （类型名，作品数），按作品数倒序。
  final List<(String, int)> folders;

  /// 点文件夹：传类型名，调用方进该类型的视频列表。
  final ValueChanged<String> onOpen;

  /// 每个类型的封面（2026-11-24 文件夹卡片用封面）：类型名 →
  /// 该类型视频列表第一条视频的 pic_url（服务
  /// [FilmLibraryService.typeFolderCovers] 给的）；没封面的
  /// 类型不在 map 里、或值为空，卡片回落文件夹图标。
  final Map<String, String> covers;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(0, 4, 0, 4),
      itemCount: folders.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 12,
        crossAxisSpacing: 10,
        childAspectRatio: 0.78,
      ),
      itemBuilder: (context, index) {
        final folder = folders[index];
        return _FolderCard(
          name: folder.$1,
          count: folder.$2,
          coverUrl: covers[folder.$1] ?? '',
          onTap: () => onOpen(folder.$1),
        );
      },
    );
  }
}

/// 文件夹回落图标：没封面、或封面加载失败时都显示它（原来那
/// 个通用黄色文件夹图标，只在没封面时出现）。
const _folderIcon = Center(
  child: Icon(
    Icons.folder_rounded,
    size: 52,
    color: Color(0xFFFFC93C),
  ),
);

class _FolderCard extends StatelessWidget {
  const _FolderCard({
    required this.name,
    required this.count,
    required this.onTap,
    this.coverUrl = '',
  });

  final String name;
  final int count;
  final VoidCallback onTap;

  /// 该类型视频列表第一条视频的封面；空 = 没封面，回落图标。
  final String coverUrl;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('type-folder-$name'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: Neon.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Neon.violet.withValues(alpha: .45)),
        ),
        // 封面图要裁进圆角卡片里（不 clip 的话图角会顶出圆角）。
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              // 封面加载走本页视频卡同一路子（Image.network，
              // 不另起下载逻辑）；加载失败进 errorBuilder 回落
              // 图标。图片是异步解码，列表滚动不卡在这上面。
              child: coverUrl.isEmpty
                  ? _folderIcon
                  : Image.network(
                      coverUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      errorBuilder: (_, _, _) => _folderIcon,
                    ),
            ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 3),
              decoration: BoxDecoration(
                color: Neon.violet.withValues(alpha: .35),
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(0),
                ),
              ),
              child: Text(
                '共$count条',
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Neon.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Neon.text,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 文件夹里的视频卡（海报网格用）：封面 + 标题，照本页作品卡
/// （_workCard）同一版式；点卡由调用方打开 FilmDetailPage
/// （影视库条目直接播，不绕站点取流）。视频区占位如实写：
/// 没封面时显示番号/类型名占位，不编假图。
class ActressFolderVideoCard extends StatelessWidget {
  const ActressFolderVideoCard({
    super.key,
    required this.entry,
    required this.onTap,
  });

  final FilmLibraryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      key: ValueKey('folder-video-${entry.vodId}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Container(
              decoration: actressNeonCardDecoration(radius: 10),
              clipBehavior: Clip.antiAlias,
              child: Container(
                color: Neon.surface,
                width: double.infinity,
                height: double.infinity,
                child: entry.coverUrl.isEmpty
                    ? Center(
                        child: Text(
                          entry.code.isEmpty ? 'NV' : entry.code,
                          style: const TextStyle(
                            color: Neon.textDim,
                            fontSize: 12,
                          ),
                        ),
                      )
                    : Image.network(
                        entry.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      ),
              ),
            ),
          ),
          const SizedBox(height: 5),
          Text(
            entry.displayTitle,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Neon.text,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
