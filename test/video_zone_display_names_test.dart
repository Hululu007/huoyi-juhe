import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/video_zone_display_names.dart';

import 'embedded_test_entries.dart';

/// 弹窗四列格实测宽度模型（见 site_grid_dialog.dart）：格宽约 73px，
/// 内边距各 4px 后文字宽约 65px、13 号字、最多两行，预算 130px。
/// 中文 13px、拉丁/数字 7px、· 7px、🔞 这类 emoji 16px。
int _displayWidth(String name) {
  var width = 0;
  for (final rune in name.runes) {
    if (rune >= 0x1F000) {
      width += 16;
    } else if ((rune >= 0x2E80 && rune <= 0x9FFF) ||
        (rune >= 0x3041 && rune <= 0x30FF) ||
        (rune >= 0xAC00 && rune <= 0xD7A3) ||
        (rune >= 0xFF01 && rune <= 0xFF5E)) {
      width += 13;
    } else {
      width += 7;
    }
  }
  return width;
}

void main() {
  test('短名表全是修仙词·短名两段式，重名只许 whos/wohs 同站共用，弹窗两行看得全', () {
    expect(videoZoneDisplayNames.length, 216);
    final values = videoZoneDisplayNames.values.toList();
    // 唯一重名：种子 whos 与 jar wohs 是同一站（whos识图）共用
    // '炼虚·识图'；种子 id 不走 jar 别名，表里只能写两条。
    final dupes =
        values.where((v) => values.where((x) => x == v).length > 1).toSet();
    expect(dupes, {'炼虚·识图'}, reason: '短名重名只允许 whos/wohs 同站共用');
    for (final entry in videoZoneDisplayNames.entries) {
      final name = entry.value;
      expect(name.contains('┃'), isFalse, reason: '${entry.key} 仍带 ┃ 后缀');
      expect(name.contains('🆕'), isFalse, reason: '${entry.key} 仍带 🆕');
      expect(name.contains('·'), isTrue, reason: '${entry.key} 不是两段式：$name');
      expect(
        _displayWidth(name),
        lessThanOrEqualTo(130),
        reason: '${entry.key} 短名仍超宽：$name',
      );
    }
  });

  test('成人站保留 🔞，低端影视与 whos识图不加 🔞', () {
    expect(videoZoneDisplayName('jar:zakatv:ZakaMjv011', 'x'), '🔞黄枫谷·mjv011');
    expect(videoZoneDisplayName('seed_javverse', 'x'), '🔞天渊城·Verse');
    // 低端影视与 whos识图原名本来就没有 🔞（内容也不是成人向），不新增；
    // 它俩虽在分档表里，但那是分档登记口径，不是展示口径。
    expect(videoZoneDisplayName('seed_ddys', 'x'), '真仙·低端');
    expect(videoZoneDisplayName('jar:zakatv:ZakaWhos', 'x'), '炼虚·识图');
    expect(videoZoneDisplayName('jar:youtube:youtube', 'x'), '青元诀·油管');
    // 同站 jar 行与种子行共用一个短名。
    expect(
      videoZoneDisplayName('jar:zakatv:zakajavverse', 'x'),
      videoZoneDisplayName('seed_javverse', 'x'),
    );
    // 不在表里的站回落原名。
    expect(videoZoneDisplayName('seed_new_site', '新站原名'), '新站原名');
  });

  test('统一表 377 行全走短名，去重后 301 个站名', () {
    final sites = unifiedVideoZoneSites(embeddedTestEntries());
    expect(sites.length, 377);
    final names = sites.map((site) => site.name).toSet();
    // 站点库批（2026-11-27）：行数 386 → 377、去重站名 308 → 301，
    // 随站集变化（工具行 3 剔除、zy360 未进库、legado 按真实分区
    // 计入、重复 canon 同名合并），逐项与生成器 ACCOUNT 对过。
    expect(names.length, 301);
    for (final site in sites) {
      expect(
        _displayWidth(site.name),
        lessThanOrEqualTo(130),
        reason: '${site.id} 仍超宽：${site.name}',
      );
    }
  });
}
