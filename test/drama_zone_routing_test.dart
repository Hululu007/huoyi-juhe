import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/source_registry.dart';

SourceEntry _entry({
  required String id,
  required String name,
  required SourceKind kind,
  Map<String, Object?> extra = const {},
  bool enabled = true,
}) {
  return SourceEntry(
    id: id,
    name: name,
    kind: kind,
    address: '$id.addr',
    detail: '',
    extra: extra,
    enabled: enabled,
  );
}

SourceEntry _seed(String seedId, String name) => _entry(
      id: 'seed_$seedId',
      name: name,
      kind: SourceKind.pyImport,
      extra: {
        'path': 'assets/builtin_sites/$seedId.py',
        'ext': '',
        'contentType': 'video',
        'builtin': true,
        'seedId': seedId,
      },
    );

SourceEntry _jar(String key, String name, String className) => _entry(
      id: 'jar:zakatv:$key',
      name: name,
      kind: SourceKind.jarImport,
      extra: {
        'configId': 'zakatv',
        'className': className,
        'jarUrl': 'asset:assets/jars/zakatv.jar',
        'md5': '0dbb5198da972c207f6d8e1b0029e266',
        'ext': '',
        'contentType': 'video',
        'builtin': true,
      },
    );

Future<void> _seedRegistry() async {
  SharedPreferences.setMockInitialValues({
    'juhe_custom_sources': jsonEncode([
      _seed('ai2026', '🔞2026短剧AI'),
      _seed('ai4k', '🔞4K.AI短剧'),
      _seed('aidj', '🔞AI短剧AV'),
      _seed('aiduanju', '🔞AI短剧网'),
      _seed('aimove', '🔞新黄果短剧'),
      _seed('aisxpc', '🔞Ai小视频┃短剧'),
      _seed('aihi', '🔞AIHI短剧'),
      _seed('aipornx', '🔞AiPorn短剧'),
      _seed('xojav', '🔞XOJAV'),
      _seed('porncgw', '🔞Porn吃瓜网'),
      _seed('x51', '🔞51X'),
      _jar('ZakaHddj', '🔞黄豆短剧┃AI短剧+漫剧',
          'com.github.catvod.spider.ZakaHddjAmns'),
      _jar('ZakaHgdj', '🔞黄果短剧┃AI成人短剧',
          'com.github.catvod.spider.ZakaHgdjAmns'),
    ]),
  });
  await SourceRegistry.instance.load();
}

void main() {
  setUpAll(_seedRegistry);

  test('短剧区药丸：裸站只列一次，种子/jar 重复行不再出现', () {
    final sites = SourceRegistry.instance.visibleDramaSites(
      types: {ContentType.video, ContentType.mixed},
    );
    final ids = [for (final site in sites) site.id];
    for (final bare in [
      'ai2026',
      'ai4k',
      'aidj',
      'aiduanju',
      'aimove',
      'aisxpc',
      'aihi',
      'aipornx',
      'hddj',
      'hgdj',
    ]) {
      expect(ids.where((id) => id == bare).length, 1, reason: bare);
    }
    expect(ids.any((id) => id.startsWith('seed_')), isFalse);
    expect(ids.any((id) => id == 'jar:zakatv:ZakaHddj'), isFalse);
    expect(ids.any((id) => id == 'jar:zakatv:ZakaHgdj'), isFalse);
    expect(
      sites.firstWhere((site) => site.id == 'aisxpc').name,
      '🔞Ai小视频┃短剧',
    );
  });

  test('短剧区裸站都有客户端：hddj 走 jar、种子站走 py、hgdj 走核心', () {
    final registry = SourceRegistry.instance;
    expect(registry.hasDramaContentClient('hddj'), isTrue);
    expect(registry.hasDramaContentClient('ai2026'), isTrue);
    expect(registry.hasDramaContentClient('aihi'), isTrue);
    expect(registry.hasDramaContentClient('aipornx'), isTrue);
    expect(registry.hasDramaContentClient('hgdj'), isTrue);
    expect(registry.hasDramaContentClient('no_such_station_xyz'), isFalse);
    expect(
      registry.backingEntryForDramaSite('hddj')?.id,
      'jar:zakatv:ZakaHddj',
    );
    expect(
      registry.backingEntryForDramaSite('ai2026')?.id,
      'seed_ai2026',
    );
    expect(registry.backingEntryForDramaSite('no_such_station_xyz'),
        isNull);
  });

  test('clientFor：种子短剧站裸 id 能取到 py 客户端', () async {
    final registry = SourceRegistry.instance;
    expect(await registry.clientFor('ai2026'), isNotNull);
    expect(await registry.clientFor('aihi'), isNotNull);
    expect(await registry.clientFor('aipornx'), isNotNull);
    expect(await registry.clientFor('no_such_station_xyz'), isNull);
  });

  test('jar key 归一化：Zaka 前缀去掉再小写，别名表兜底', () {
    expect(adultJarKeyToCoreId('ZakaHddj'), 'hddj');
    expect(adultJarKeyToCoreId('ZakaHgdj'), 'hgdj');
    expect(adultJarKeyToCoreId('ZakaHgdjV'), 'hgdjv');
    expect(adultJarKeyToCoreId('hgdj58'), 'hgdj58');
    expect(adultJarKeyToCoreId('ZakaTxfans'), 'txfans');
    expect(adultJarKeyToCoreId('ZakaJavverse'), 'javverse');
  });

  test('影视区不再出现短剧站：种子/jar 短剧站全被名字过滤掉', () {
    final entries = SourceRegistry.instance.custom;
    final unified = unifiedVideoZoneSites(entries);
    final ids = {for (final site in unified) site.id};
    for (final shortDrama in [
      'seed_ai2026',
      'seed_ai4k',
      'seed_aidj',
      'seed_aiduanju',
      'seed_aimove',
      'seed_aisxpc',
      'seed_aihi',
      'seed_aipornx',
      'jar:zakatv:ZakaHddj',
      'jar:zakatv:ZakaHgdj',
    ]) {
      expect(ids.contains(shortDrama), isFalse, reason: shortDrama);
    }
    expect(ids.contains('seed_xojav'), isTrue);
    expect(ids.contains('seed_porncgw'), isTrue);
    expect(ids.contains('seed_x51'), isTrue);
  });

  test('午夜区分档：xojav/porncgw 第 2 档、x51 第 4 档，未解锁时隐藏', () {
    // 门禁开关测试期默认就是开的（正式恢复只改初值）；要验“未解锁隐藏”，
    // 先关掉再测，测完恢复（与 video_page_tier_test 同款做法）。
    final wasDisabled = cultivationAdultTierGateDisabledForTesting;
    cultivationAdultTierGateDisabledForTesting = false;
    try {
      final entries = SourceRegistry.instance.custom;
      final locked = visibleVideoZoneSites(entries, 0);
      final lockedIds = {for (final site in locked) site.id};
      expect(lockedIds.contains('seed_xojav'), isFalse);
      expect(lockedIds.contains('seed_porncgw'), isFalse);
      expect(lockedIds.contains('seed_x51'), isFalse);
      final unlocked = visibleVideoZoneSites(entries, 30000);
      final unlockedIds = {for (final site in unlocked) site.id};
      expect(unlockedIds.contains('seed_xojav'), isTrue);
      expect(unlockedIds.contains('seed_porncgw'), isTrue);
      expect(unlockedIds.contains('seed_x51'), isTrue);
    } finally {
      cultivationAdultTierGateDisabledForTesting = wasDisabled;
    }
    expect(adultTierForSiteId('seed_xojav', adultVideoSiteOrder), 1);
    expect(adultTierForSiteId('seed_porncgw', adultVideoSiteOrder), 1);
    expect(adultTierForSiteId('seed_x51', adultVideoSiteOrder), 3);
    expect(adultTierForSiteId('hddj', adultVideoSiteOrder), 0);
    expect(adultTierForSiteId('hgdj', adultVideoSiteOrder), 2);
  });

  test('短剧区站表里有 aihi/aipornx，影视区站表里没有', () {
    expect(dramaSites.any((site) => site.id == 'aihi'), isTrue);
    expect(dramaSites.any((site) => site.id == 'aipornx'), isTrue);
    final entries = SourceRegistry.instance.custom;
    final unified = unifiedVideoZoneSites(entries);
    final ids = {for (final site in unified) site.id};
    expect(ids.contains('seed_aihi'), isFalse);
    expect(ids.contains('seed_aipornx'), isFalse);
    expect(ids.contains('aihi'), isFalse);
    expect(ids.contains('aipornx'), isFalse);
  });
}
