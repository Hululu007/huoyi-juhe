// 适配层：女优库模块在魔蚁侧依赖的 pushPlayer（原 lib/player_picker.dart）。
//
// 魔蚁 pushPlayer 把 DramaDetail 推给魔蚁播放器（可换线、可重试探活）。
// 修仙版等价物是 PlayerPage（pages/player_page.dart）：contentLoader
// 回 {video_url} 即播（EpisodeSource.fromResponse 认 video_url /
// main_url）。本文件把 DramaDetail 的集转成 Chapter，取流走仓储
// resolve（库直链直接回地址；站内集调站 playSource + 本地代理），
// 再推 PlayerPage。
//
// 差异（诚实记录）：
// - 换线回调 onPlaybackExhausted / onRetryProbe：修仙版 PlayerPage
//   没有对应入口，参数照收但暂不接线，播失败时由播放器自身报错页
//   处理；女优库点播链本身是“库里多条逐条验活、首条活的进播放器”，
//   播放器内换线不是主链路；
// - 选集：PlayerPage 的 eps 就是详情的集表，切集走仓储 resolve；
// - shortSeries=false：女优库是横屏影视（电影形态），不用短剧竖屏形态；
// - bookId 前缀 'actress:'：播放进度/历史键与正片隔离，不混进书架；
// - cultivationCategory=video：修为记账按影视记。
// - 注意：本入口不另收元宝（影视区详情页进片收 20 元宝是详情页的扣费
//   点；女优库点播是否收、收多少是产品口径，合并工程不定，见报告）。

import 'package:flutter/material.dart';

import '../models/media_item.dart' show Chapter;
import '../pages/player_page.dart' show PlayerPage;
import '../services/cultivation.dart' show CultivationCategory;
import '../services/native_player.dart' show NativePlayer;
import 'actress_adapter_models.dart'
    show AppFailure, DramaDetail, Episode, PlaybackPlan;
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_adapter_store.dart' show LocalStore;

Future<T?> pushPlayer<T>(
  BuildContext context, {
  required DramaDetail detail,
  required int initialIndex,
  required AppRepository repository,
  required LocalStore store,
  void Function(BuildContext)? onPlaybackExhausted,
  Future<bool> Function(BuildContext)? onRetryProbe,
  // 测试/预览注入播放器实现：默认走真 NativePlayer；单元测试传
  // test/support/controlled_player.dart 的 ControlledNativePlayer。
  NativePlayer Function()? playerFactory,
}) async {
  // onPlaybackExhausted / onRetryProbe：修仙版 PlayerPage 暂无对应
  // 入口（见文件头差异说明），这里只收下不接线。
  final episodes = detail.episodes;
  if (episodes.isEmpty) throw AppFailure('这条没有可播地址');
  final safeIndex = initialIndex.clamp(0, episodes.length - 1);
  final chapters = [
    for (var i = 0; i < episodes.length; i++)
      Chapter(
        itemId: episodes[i].id,
        title: episodes[i].title,
        volumeName: '',
      ),
  ];

  Future<Map<String, dynamic>> contentLoader(Chapter chapter) async {
    final index = chapters.indexWhere((c) => c.itemId == chapter.itemId);
    final episode = index >= 0 ? episodes[index] : episodes[safeIndex];
    final plan = await _resolveEpisode(repository, detail, episode);
    return {'video_url': plan.url, 'key_hex': ''};
  }

  return Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => PlayerPage(
        bookId: 'actress:${detail.drama.id}',
        kind: 'video',
        title: detail.drama.title,
        cover: detail.drama.cover,
        eps: chapters,
        startIndex: safeIndex,
        shortSeries: false,
        cultivationCategory: CultivationCategory.video,
        contentLoader: contentLoader,
        playerFactory: playerFactory,
      ),
    ),
  );
}

/// 单集取流：直链直接回；站内集走仓储 resolve（内含本地代理）。
/// 集 id 本身就是地址时不再调站客户端。
Future<PlaybackPlan> _resolveEpisode(
  AppRepository repository,
  DramaDetail detail,
  Episode episode,
) async {
  return repository.resolve(detail.drama, episode);
}
