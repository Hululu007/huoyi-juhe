import 'package:shared_preferences/shared_preferences.dart';

import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'midnight_gate.dart';
import 'source_registry.dart';

/// 影视 tab 的一站标签数据：本站分类 + 提取的标签/主题/角色/情节。
/// 不同站的数据不同：分类来自本站注册/提取结果，主题/角色/情节来自
/// 提取后写进 entry.extra['videoTags'] 的结果（暂未提取到的站该组为空，
/// 分类页只留组头位置，不硬编假标签）。
class VideoCategoryData {
  const VideoCategoryData({
    required this.siteId,
    required this.siteName,
    required this.hotTags,
    required this.themes,
    required this.roles,
    required this.plots,
  });

  final String siteId;
  final String siteName;

  /// 热门标签：本站分类（去掉「全部」）+ 成人站追加的「熟女」。
  final List<String> hotTags;
  final List<String> themes;
  final List<String> roles;
  final List<String> plots;
}

/// 影视页当前站的持久化键（与 VideoPage 的 _videoZoneSiteKey 同值，
/// 分类页无站号传入时按它找当前站）。
const videoZoneSitePreferenceKey = 'video_zone_site_id';

Future<String?> currentVideoZoneSiteId() async {
  try {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getString(videoZoneSitePreferenceKey);
  } catch (_) {
    return null;
  }
}

List<String> _tagList(Map<String, dynamic> extra, String key) {
  final tags = extra['videoTags'];
  if (tags is! Map) return const [];
  final raw = tags[key];
  if (raw is! List) return const [];
  return [
    for (final item in raw)
      if ('$item'.trim().isNotEmpty) '$item'.trim(),
  ];
}

/// 取一站的影视 tab 数据：
///
/// * 定制站：先读注册时持久化的提取分类；仍只有「全部」时现场提取一次
///   （走 SourceRegistry.extractSiteCategories，会写回 extra 并持久化）。
/// * 内置站：先读 drama_sites 的登记分类；仍只有「全部」时现取一次
///   客户端 categories()（不持久化，内置站无登记条目可写）。
/// * 热门标签 = 本站分类（去「全部」）+ 成人站追加「熟女」
///   （MidnightGate.isAdultName 判站名，非成人站不加）。
Future<VideoCategoryData> loadVideoCategoryData(String siteId) async {
  await SourceRegistry.instance.load();
  final entry = SourceRegistry.instance.customById(siteId);
  final siteName = entry?.name ?? dramaSiteById(siteId).name;
  var cats = entry == null
      ? dramaSiteById(siteId).categories
      : SourceRegistry.categoriesFromExtra(entry.extra);
  final onlyAll = cats.length == 1 && cats.first.id == 'all';
  if (cats.isEmpty || onlyAll) {
    try {
      if (entry != null) {
        final extracted =
            await SourceRegistry.instance.extractSiteCategories(siteId);
        final valid = [
          for (final c in extracted)
            if (c.id != 'all') c,
        ];
        if (valid.isNotEmpty) cats = valid;
      } else {
        final client = dramaSiteContentClient(siteId) ??
            await SourceRegistry.instance.clientFor(siteId);
        if (client != null) {
          final live = await client
              .categories()
              .timeout(const Duration(seconds: 30));
          final valid = [
            for (final c in live)
              if (c.id.trim().isNotEmpty && c.name.trim().isNotEmpty) c,
          ];
          if (valid.isNotEmpty) cats = valid;
        }
      }
    } catch (_) {}
  }
  final hot = <String>{};
  for (final c in cats) {
    final name = c.name.trim();
    if (name.isEmpty || name == '全部') continue;
    hot.add(name);
  }
  if (MidnightGate.isAdultName(siteName)) hot.add('熟女');
  final extra = entry?.extra ?? const <String, dynamic>{};
  return VideoCategoryData(
    siteId: siteId,
    siteName: siteName,
    hotTags: hot.toList(),
    themes: _tagList(extra, 'theme'),
    roles: _tagList(extra, 'role'),
    plots: _tagList(extra, 'plot'),
  );
}
