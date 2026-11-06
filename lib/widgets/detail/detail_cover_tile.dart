import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../models/media_item.dart';
import '../home/home_design.dart';
import '../home/home_media_card.dart';

/// 3:4-ish detail cover, tappable to open the zoomable viewer.
///
/// Mockup size is exactly 92×128 at r6 with no shadow, spine or border; e-ink
/// keeps the shape and paints the artwork in grayscale.
///
/// When [onPlay] is given (video detail), a play button sits in the middle
/// of the poster; tapping it starts playback, tapping elsewhere on the
/// poster still opens the zoomable viewer.
class DetailCoverTile extends StatelessWidget {
  final MediaItem item;

  /// 桌面两栏布局：封面放大。
  final bool desktop;
  final bool compact;

  /// Video play action. Null means no play button on the poster.
  final VoidCallback? onPlay;

  const DetailCoverTile({
    super.key,
    required this.item,
    this.desktop = false,
    this.compact = false,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    final width = desktop ? (compact ? 112.0 : 168.0) : 92.0;
    final height = desktop ? width * 4 / 3 : 128.0;
    return SizedBox(
      width: width,
      height: height,
      child: HomePressable(
        key: const Key('detail_cover_button'),
        semanticLabel: '查看《${item.title}》封面',
        onTap: () => showDetailCover(context, item),
        borderRadius: BorderRadius.circular(6),
        child: ExcludeSemantics(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                palette.eink
                    ? ColorFiltered(
                        colorFilter: const ColorFilter.matrix(<double>[
                          0.2126, 0.7152, 0.0722, 0, 0, //
                          0.2126, 0.7152, 0.0722, 0, 0, //
                          0.2126, 0.7152, 0.0722, 0, 0, //
                          0, 0, 0, 1, 0, //
                        ]),
                        child: StoryCover(item: item, cacheWidth: 320),
                      )
                    : StoryCover(item: item, cacheWidth: 320),
                if (onPlay != null)
                  Center(
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        key: const Key('detail_cover_play_button'),
                        customBorder: const CircleBorder(),
                        onTap: onPlay,
                        child: Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.55),
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.85),
                              width: 1.5,
                            ),
                          ),
                          child: const Icon(
                            LucideIcons.play,
                            color: Colors.white,
                            size: 24,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Full-screen zoomable cover viewer. Tapping the cover opens it.
Future<void> showDetailCover(BuildContext context, MediaItem item) =>
    showGeneralDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierLabel: '关闭封面',
      barrierColor: Colors.black.withValues(alpha: 0.92),
      transitionDuration: MediaQuery.disableAnimationsOf(context)
          ? Duration.zero
          : const Duration(milliseconds: 260),
      pageBuilder: (context, animation, secondaryAnimation) => SafeArea(
        child: Material(
          color: Colors.transparent,
          child: Column(
            children: [
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: IconButton(
                    tooltip: '关闭封面',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(LucideIcons.x, color: Colors.white),
                  ),
                ),
              ),
              Expanded(
                child: InteractiveViewer(
                  key: const Key('detail_cover_viewer'),
                  maxScale: 3,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 420),
                        child: AspectRatio(
                          aspectRatio: 5 / 7,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: StoryCover(item: item, cacheWidth: 1000),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
                child: Text(
                  item.title,
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    height: 1.5,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
