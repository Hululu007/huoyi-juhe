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
  test('短名表全是修仙词·短名两段式，无重名，弹窗两行看得全', () {
    expect(videoZoneDisplayNames.length, 214);
    final values = videoZoneDisplayNames.values.toList();
    expect(values.toSet().length, values.length, reason: '短名全表无重名');
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

  test('统一表 289 行全走短名，去重后 214 个站名', () {
    final sites = unifiedVideoZoneSites(embeddedTestEntries());
    expect(sites.length, 289);
    final names = sites.map((site) => site.name).toSet();
    expect(names.length, 214);
    for (final site in sites) {
      expect(
        _displayWidth(site.name),
        lessThanOrEqualTo(130),
        reason: '${site.id} 仍超宽：${site.name}',
      );
    }
  });
}
