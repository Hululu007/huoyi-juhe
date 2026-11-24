import 'package:flutter/material.dart';

import 'actress_film_library.dart';
import 'actress_models.dart';
import 'actress_adapter_models.dart';

/// 无头像占位用的渐变色板：按名字哈希确定性取一对，同人同渐变。
const _actressPlaceholderGradients = <(Color, Color)>[
  (Color(0xFF7C4DFF), Color(0xFF18FFFF)),
  (Color(0xFFFF6E40), Color(0xFFFFD740)),
  (Color(0xFF00BFA5), Color(0xFF64FFDA)),
  (Color(0xFFFF4081), Color(0xFF7C4DFF)),
  (Color(0xFF2979FF), Color(0xFF00E5FF)),
  (Color(0xFF76FF03), Color(0xFF00BFA5)),
];

/// 人物头像：圆图；无头像/加载中/加载失败时显示渐变底 + 姓氏大字
/// （名字首字），不用人物图标。头像 URL 直接走 `Image.network`
/// （全局代理出口已接管图片请求）。
class ActressAvatar extends StatelessWidget {
  const ActressAvatar({
    super.key,
    required this.avatarUrl,
    this.name = '',
    this.radius = 24,
  });

  final String avatarUrl;
  final String name;
  final double radius;

  Widget _placeholder(BuildContext context) {
    final initial = name.isEmpty ? '' : String.fromCharCode(name.runes.first);
    final hash = name.runes.fold(0, (sum, rune) => sum + rune);
    final colors =
        _actressPlaceholderGradients[hash %
            _actressPlaceholderGradients.length];
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          colors: [colors.$1, colors.$2],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          fontSize: radius * 0.95,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final placeholder = _placeholder(context);
    if (avatarUrl.isEmpty) return placeholder;
    return ClipOval(
      child: Image.network(
        avatarUrl,
        width: radius * 2,
        height: radius * 2,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => placeholder,
        loadingBuilder: (_, child, progress) =>
            progress == null ? child : placeholder,
      ),
    );
  }
}

/// 作品卡片用的 Drama：与站内视频卡片同一形态（DramaTile）。
///
/// - 有封面：用搜索命中原站的 Drama（source/id/cover 均来自命中），
///   封面解析才能走通；站源身份只在这里内部流转，界面不显示；
/// - 无封面：id 留空，DramaCover 直接画渐变占位（不走封面请求，
///   不会出现“重试海报”按钮），标题与副标题照常显示。
Drama actressWorkDrama(ActressWork work) {
  if (work.hasCover) {
    return Drama(
      id: work.coverDramaId,
      // 2026-11-22 修：coverSource 是库里的 vod_play_from 原样
      //（whos.tv / mjv011），取封面只认归一化站 id（whos / mjv），
      // 不归一化就取不到图——作品网格整片灰块就是这么来的。
      source: filmSiteId(work.coverSource),
      title: work.displayTitle,
      cover: work.coverUrl,
    );
  }
  return Drama(id: '', source: '', title: work.displayTitle);
}

/// 作品卡片副标题：日期 + 番号（标题已是番号时只剩日期）。
String actressWorkSubtitle(ActressWork work) => work.displaySubtitle;

/// 性别 chip 文案：未知性别显示为空（只在“全部”里出现）。
String actressSexLabel(String sex) => switch (sex) {
  'female' => '女',
  'male' => '男',
  _ => '',
};
