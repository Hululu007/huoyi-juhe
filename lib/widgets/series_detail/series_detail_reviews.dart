import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/book_detail.dart' show formatCounter;
import '../../models/playlet_comment.dart';
import '../../services/api_client.dart';
import '../home/home_cell_blocks.dart' show HomeBlockMore;
import '../home/home_design.dart';
import 'series_detail_common.dart';

/// 剧评：头部 `剧评 · 952` + 右侧「全部 ›」与折叠钮（展开/收起，照火蚁TV
/// 详情页可折叠区块的做法），下面是竖排的评论行。
///
/// 展开时评论行放在定高的竖向列表里，区内上下滑动翻评论，不依赖整页
/// 滚动；点折叠钮把列表收到只剩头部。完整浏览（含筛选/回复）仍走头部
/// 「全部」打开的评论面板。版式稿：行内 22dp 头像 + 12sp 昵称 + 紧跟其后
/// 的 12sp 相对时间（8dp 间距，不推到右边缘），正文 13/1.5 最多 4 行，
/// 行间 1px 分隔线。桌面只保留最大宽度，不铺满整屏。
class SeriesDetailReviews extends StatefulWidget {
  const SeriesDetailReviews({
    super.key,
    required this.comments,
    required this.total,
    required this.loading,
    required this.failed,
    required this.onRetry,
    required this.onShowAll,
  });

  static const maxListWidth = 420.0;

  /// 展开时区内列表的高度：约放 3–4 条评论，区内上下滑动翻其余评论。
  static const expandedHeight = 360.0;

  final List<PlayletComment> comments;
  final int total;
  final bool loading;
  final bool failed;
  final VoidCallback onRetry;
  final VoidCallback onShowAll;

  @override
  State<SeriesDetailReviews> createState() => _SeriesDetailReviewsState();
}

class _SeriesDetailReviewsState extends State<SeriesDetailReviews> {
  var _expanded = true;

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final comments = widget.comments;
    return SeriesSection(
      key: const ValueKey('series-detail-comment-section'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SeriesSectionHeader(
            title: widget.total > 0
                ? '剧评 · ${formatCounter('${widget.total}')}' : '剧评',
            action: comments.isEmpty
                ? null
                : Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      HomeBlockMore(
                        key: const ValueKey('series-detail-comments-all'),
                        onTap: widget.onShowAll,
                        label: '全部',
                      ),
                      const SizedBox(width: 12),
                      GestureDetector(
                        key: const ValueKey('series-detail-comments-fold'),
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(() => _expanded = !_expanded),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _expanded ? '收起' : '展开',
                              style: TextStyle(
                                fontSize: 12,
                                height: 1.2,
                                color: palette.muted,
                              ),
                            ),
                            const SizedBox(width: 2),
                            Icon(
                              _expanded
                                  ? LucideIcons.chevron_up
                                  : LucideIcons.chevron_down,
                              size: 13,
                              color: palette.muted,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
          if (_expanded) _body(palette),
        ],
      ),
    );
  }

  Widget _body(HomePalette palette) {
    if (widget.loading) return const SeriesDetailSkeleton();
    if (widget.failed) {
      return SeriesRetryInline(
        message: '剧评加载失败',
        onRetry: widget.onRetry,
      );
    }
    if (widget.comments.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          '暂无剧评',
          key: const ValueKey('series-detail-comments-empty'),
          style: TextStyle(fontSize: 13, color: palette.muted),
        ),
      );
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(
        maxWidth: SeriesDetailReviews.maxListWidth,
      ),
      child: SizedBox(
        height: SeriesDetailReviews.expandedHeight,
        child: ListView.builder(
          key: const ValueKey('series-detail-comment-list'),
          itemCount: widget.comments.length,
          itemBuilder: (context, index) => _row(
            palette,
            widget.comments[index],
            last: index == widget.comments.length - 1,
          ),
        ),
      ),
    );
  }

  Widget _row(
    HomePalette palette,
    PlayletComment comment, {
    required bool last,
  }) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10),
    decoration: BoxDecoration(
      border: last ? null : Border(bottom: BorderSide(color: palette.line)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                color: palette.soft,
                shape: BoxShape.circle,
                border: palette.eink ? Border.all(color: palette.line) : null,
              ),
              clipBehavior: Clip.antiAlias,
              alignment: Alignment.center,
              child: comment.userAvatar.isEmpty
                  ? _initial(palette, comment)
                  : CachedNetworkImage(
                      imageUrl: ApiClient.instance.absoluteUrl(
                        comment.userAvatar,
                      ),
                      fit: BoxFit.cover,
                      errorWidget: (_, _, _) => _initial(palette, comment),
                    ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                comment.userName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: palette.ink),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              relativeTime(comment.createdAt),
              style: TextStyle(fontSize: 12, color: palette.muted),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          comment.text,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, height: 1.5, color: palette.ink),
        ),
      ],
    ),
  );

  Widget _initial(HomePalette palette, PlayletComment comment) => Text(
    comment.userName.isEmpty
        ? '?'
        : String.fromCharCode(comment.userName.runes.first),
    style: TextStyle(fontSize: 11, color: palette.ink),
  );
}

/// 相对时间：刚刚 / N 分钟前 / N 小时前 / N 天前，超过 30 天给日期。
String relativeTime(DateTime? time) {
  if (time == null) return '';
  final local = time.toLocal();
  final diff = DateTime.now().difference(local);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)}';
}
