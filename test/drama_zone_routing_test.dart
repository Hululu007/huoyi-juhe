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
      _seed('yaguo', '芽果'),
      _seed('aiyinhang', '🔞AI淫航'),
      _seed('sexaix', '🔞幻影AI'),
      _seed('xandaskday', '🔞AI不用钱'),
      _seed('huangguomanju', '🔞黄果漫剧'),
      _seed('xojav', '🔞XOJAV'),
      _seed('porncgw', '🔞Porn吃瓜网'),
      _seed('x51', '🔞51X'),
      _jar('ZakaHddj', '🔞黄豆短剧┃AI短剧+漫剧',
          'com.github.catvod.spider.ZakaHddjAmns'),
      _jar('ZakaHgdj', '🔞黄果短剧┃AI成人短剧',
          'com.github.catvod.spider.ZakaHgdjAmns'),
      _jar('zakaqmdj', '🔞七猫短剧┃VIP破解',
          'com.github.catvod.spider.ZakaQmdjAmns'),
      _jar('ZakaHgdjApp', '🆕🔞黄果短剧App┃App网关',
          'com.github.catvod.spider.ZakaHgdjAppAmns'),
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

  test('短剧区药丸不再含影视站：只留短剧站', () {
    final sites = SourceRegistry.instance.visibleShortDramaSites(
      types: {ContentType.video, ContentType.mixed},
    );
    final ids = {for (final site in sites) site.id};
    // 短剧站都在：果站（名字里没有「短剧」也算）、名字带短剧的站。
    for (final shortDrama in [
      'original',
      'hongguo',
      'hgtv',
      'hgtvmirror',
      'huangdou',
      'huangju',
      'yeguo',
      'yaguo',
      'maoguo',
      'fanguo',
      'guanguo',
      'heguo',
      'xingguo',
      'huaguo',
      'niuguo',
      'wangguo',
      'faguo',
      'wuguo',
      'huangdou_yh',
      'hddj',
      'hgdj',
      'aihi',
      'aipornx',
      'aiyinhang',
      'sexaix',
      // 2026-11-09 复核补的漏站：AI不用钱（纯 AI 短剧，名字不带短剧）、
      // 黄果漫剧（纯漫剧，名字带「漫剧」）、七猫短剧与黄果短剧App
      // （jar 独占站，此前两区都不可见，裸行占位后才进短剧药丸）。
      'xandaskday',
      'huangguomanju',
      'qmdj',
      'hgdjapp',
    ]) {
      expect(ids.contains(shortDrama), isTrue, reason: shortDrama);
    }
    // 影视站一个都不进短剧区药丸。
    for (final film in [
      'mjv011',
      'missav',
      'pornhub',
      'javrate',
      'ddys',
      'xojav',
      'porncgw',
      'x51',
      'av18av',
      'hl365',
    ]) {
      expect(ids.contains(film), isFalse, reason: film);
    }
    expect(ids.any((id) => id.startsWith('seed_')), isFalse);
    expect(ids.any((id) => id.startsWith('jar:')), isFalse);
  });

  test('影视区不再出现短剧站：种子/jar 短剧站全被共用判据拦掉', () {
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
      // 名字里不带「短剧」的短剧站：以前只靠名字过滤会漏进来，
      // 现在行 id 先归一化成裸 id 再按短剧集判。
      'seed_yaguo',
      'seed_aiyinhang',
      'seed_sexaix',
      'seed_xandaskday',
      'seed_huangguomanju',
      'jar:zakatv:ZakaHddj',
      'jar:zakatv:ZakaHgdj',
      // jar 独占短剧站：七猫短剧与黄果短剧App，名字带短剧、
      // 裸行是 qmdj/hgdjapp，影视区统一表里同样不出现。
      'jar:zakatv:zakaqmdj',
      'jar:zakatv:ZakaHgdjApp',
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
    // hgdj 是期望过时、不是分档真错：登记表里 hgdj 下标 100、总数
    // 201，100*4~/201 = 1（第 2 档）。AOXX69 摘站后总数 202→201，
    // hgdj 由 tier 2 回到 tier 1，cultivation.dart 的表头注释与
    // adult_tier_embedded_test（hgdj: 1）都是 1，只有这里还写 2。
    expect(adultTierForSiteId('hgdj', adultVideoSiteOrder), 1);
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

  test('影视判据：果站与带前缀的行 id 都按裸 id 判', () {
    // 12 个名字里没有「短剧」的果站都是短剧站，不是影视站。
    for (final entry in const [
      ('hongguo', '红果'),
      ('hgtv', 'HGTV'),
      ('hgtvmirror', '红果镜像'),
      ('maoguo', '猫果'),
      ('fanguo', '饭果'),
      ('guanguo', '观果'),
      ('heguo', '河果'),
      ('xingguo', '星果'),
      ('huaguo', '花果'),
      ('wangguo', '网果'),
      ('faguo', '发果'),
      ('wuguo', '伍果'),
    ]) {
      expect(isFilmVideoSite(entry.$1, entry.$2), isFalse, reason: entry.$1);
    }
    // 种子/jar 行 id 先归一化再判，不再只靠名字兜底。
    expect(isFilmVideoSite('seed_yaguo', '芽果'), isFalse);
    expect(isFilmVideoSite('seed_aiyinhang', '🔞AI淫航'), isFalse);
    expect(isFilmVideoSite('seed_sexaix', '🔞幻影AI'), isFalse);
    expect(isFilmVideoSite('jar:zakatv:ZakaHddj', '🔞黄豆短剧'), isFalse);
    expect(isFilmVideoSite('seed_xojav', '🔞XOJAV'), isTrue);
    expect(isFilmVideoSite('jar:zakatv:ZakaXxx', '🔞X站'), isTrue);
  });

  test('短剧判据补漏：漫剧算短剧，混合站不算', () {
    // 名字带「漫剧」即短剧站：黄果漫剧 3 个分类全是短剧/漫剧。
    expect(isShortDramaSite('huangguomanju', '🔞黄果漫剧'), isTrue);
    expect(isFilmVideoSite('seed_huangguomanju', '🔞黄果漫剧'), isFalse);
    // 名字不带短剧/漫剧的纯短剧站靠 id 集：AI不用钱全部分类都是
    // AI 成人短剧/漫剧。
    expect(isShortDramaSite('xandaskday', '🔞AI不用钱'), isTrue);
    expect(isFilmVideoSite('seed_xandaskday', '🔞AI不用钱'), isFalse);
    // 反例：只含一个短剧分类的混合影视站仍归影视区，不误判成短剧。
    expect(isShortDramaSite('91sanji', '🔞91三级'), isFalse);
    expect(isShortDramaSite('guzhuang', '🔞古装AI'), isFalse);
    expect(isShortDramaSite('dingjiaseku', '🔞顶级AI色库'), isFalse);
    expect(isShortDramaSite('thdh', '🔞探花短视频'), isFalse);
    expect(isShortDramaSite('muzi', '🔞母子视频'), isFalse);
    expect(isFilmVideoSite('seed_91sanji', '🔞91三级'), isTrue);
    expect(isFilmVideoSite('seed_guzhuang', '🔞古装AI'), isTrue);
  });

  test('jar 独占短剧站有客户端：qmdj/hgdjapp 走 jar 兜底', () {
    final registry = SourceRegistry.instance;
    expect(registry.hasDramaContentClient('qmdj'), isTrue);
    expect(registry.hasDramaContentClient('hgdjapp'), isTrue);
    expect(
      registry.backingEntryForDramaSite('qmdj')?.id,
      'jar:zakatv:zakaqmdj',
    );
    expect(
      registry.backingEntryForDramaSite('hgdjapp')?.id,
      'jar:zakatv:ZakaHgdjApp',
    );
    // 裸行占位后药丸里只出现一次裸 id，不再出现 jar 行。
    final sites = registry.visibleShortDramaSites(
      types: {ContentType.video, ContentType.mixed},
    );
    final ids = [for (final site in sites) site.id];
    expect(ids.where((id) => id == 'qmdj').length, 1);
    expect(ids.where((id) => id == 'hgdjapp').length, 1);
    expect(ids.any((id) => id == 'jar:zakatv:zakaqmdj'), isFalse);
    expect(ids.any((id) => id == 'jar:zakatv:ZakaHgdjApp'), isFalse);
  });

  test('影视区用户网格：用户自导的短剧站不进，只留影视站', () {
    final entries = [
      _entry(
        id: 'import_user_dj',
        name: '用户导入的短剧站',
        kind: SourceKind.pyImport,
      ),
      _entry(
        id: 'import_user_manju',
        name: '用户导入的漫剧站',
        kind: SourceKind.pyImport,
      ),
      _entry(
        id: 'import_user_film',
        name: '用户导入的影视站',
        kind: SourceKind.pyImport,
      ),
      _entry(
        id: 'jar:user_jar:ZakaHddj',
        name: '用户导入的黄豆短剧 jar 站',
        kind: SourceKind.jarImport,
      ),
    ];
    final visible = visibleVideoPagePlayableSites(entries, 30000);
    final ids = {for (final entry in visible) entry.id};
    expect(ids.contains('import_user_dj'), isFalse);
    expect(ids.contains('import_user_manju'), isFalse);
    expect(ids.contains('jar:user_jar:ZakaHddj'), isFalse);
    expect(ids.contains('import_user_film'), isTrue);
    // 底函数 videoPagePlayableSites 本身不管分区（只管“用户导入”），
    // 分区过滤只在页面实际用的 visibleVideoPagePlayableSites 里做。
    expect(videoPagePlayableSites(entries).length, 4);
  });
}
