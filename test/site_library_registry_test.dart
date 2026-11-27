import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/source_management_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/idj_plugin_store.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/services/zakatv_builtin.dart';

/// 站点库注册链验收：buildSqlSiteEntries 纯函数建行、syncSqlSites
/// 对账增删（只动 sqlManaged 行）、旧内置行一次性迁移清理、原生
/// 门禁闸（gated 未导入 clientFor 回 null、original 恒放行）。
/// SiteLibraryService 用 SourceRegistry 上的 debug override 接缝
/// 注入假状态，不碰真库文件。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final registry = SourceRegistry.instance;
  late Directory supportDir;

  const fakeStations = <SiteLibraryStation>[
    SiteLibraryStation(
      siteId: 'seed_missav',
      canonId: 'missav',
      name: '🔞MissAV',
      kind: 'pyImport',
      zone: 'video',
      contentType: 'video',
      isAdult: true,
      sortOrder: 1,
      fileName: 'missav.py',
      codeSha256: 'aa',
      codeFilePath: '/tmp/sql/missav.py',
    ),
    SiteLibraryStation(
      siteId: 'seed_legado1',
      canonId: 'legado1',
      name: '测试书源',
      kind: 'legadoImport',
      zone: 'novel',
      contentType: 'novel',
      isAdult: false,
      sortOrder: 2,
      verifyNote: '出口未验',
      fileName: 'legado_legado1.json',
      codeSha256: 'bb',
      codeFilePath: '/tmp/sql/legado_legado1.json',
    ),
    SiteLibraryStation(
      siteId: 'jar:zakatv:ZakaTest',
      canonId: 'test',
      name: '测试 jar 站',
      kind: 'jarImport',
      zone: 'video',
      contentType: 'video',
      isAdult: false,
      sortOrder: 3,
      className: 'com.github.catvod.spider.ZakaTest',
      jarAssetId: 'jar:zakatv',
      ext: '{"a":1}',
    ),
    SiteLibraryStation(
      siteId: 'jar:youtube:YouTube',
      canonId: 'youtube',
      name: 'YouTube',
      kind: 'jarImport',
      zone: 'video',
      contentType: 'video',
      isAdult: false,
      sortOrder: 4,
      className: 'com.github.catvod.spider.YouTube',
      jarAssetId: 'jar:youtube',
      extFilePath: '/tmp/sql/youtube3.json',
    ),
    SiteLibraryStation(
      siteId: 'hongguo',
      canonId: 'hongguo',
      name: '红果',
      kind: 'nativeGate',
      zone: 'drama',
      contentType: 'video',
      isAdult: false,
      sortOrder: 5,
    ),
  ];

  setUpAll(() async {
    supportDir = Directory.systemTemp.createTempSync('sql_reg_support');
    // 名单资产假件：roster.json 尚未进 pubspec 资产声明时真名单读
    // 不到，渲染测试要确定性——只对名单键回一份小名单，其余资产
    // 键回 null（各读取方都是 fail-soft）。必须在首次 load 前装，
    // SiteLibraryService 的名单缓存只读一次。
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMessageHandler('flutter/assets', (message) async {
          final key = message == null
              ? ''
              : utf8.decode(message.buffer.asUint8List());
          if (key != 'assets/site_library/roster.json') return null;
          return ByteData.sublistView(
            utf8.encode(
              jsonEncode({
                'stations': [
                  {
                    'id': 'hongguo',
                    'name': '红果',
                    'zone': 'drama',
                    'adult': false,
                    'sort': 0,
                    'kind': 'nativeGate',
                  },
                  {
                    'id': 'sqlplain',
                    'name': '名单普通站',
                    'zone': 'video',
                    'adult': false,
                    'sort': 1,
                    'kind': 'pyImport',
                  },
                  {
                    'id': 'missav',
                    'name': '🔞MissAV名单',
                    'zone': 'video',
                    'adult': true,
                    'sort': 2,
                    'kind': 'pyImport',
                  },
                ],
              }),
            ),
          );
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async {
            switch (call.method) {
              case 'getApplicationDocumentsDirectory':
              case 'getApplicationSupportDirectory':
              case 'getTemporaryDirectory':
                return supportDir.path;
              default:
                return null;
            }
          },
        );
    Map<String, dynamic> row(
      String id,
      String kind,
      Map<String, dynamic> extra,
    ) => {
      'id': id,
      'name': id,
      'kind': kind,
      'address': '',
      'detail': '',
      'enabled': true,
      'extra': extra,
    };
    SharedPreferences.setMockInitialValues({
      'juhe_custom_sources': jsonEncode([
        // 用户自导 py（builtin 不为 true）：迁移与对账都不许动。
        row('import_user1', 'pyImport', {
          'path': '/tmp/user/one.py',
          'ext': '',
          'contentType': 'video',
        }),
        // 用户自导 jar（builtin 不为 true）：同上。
        row('import_userjar', 'jarImport', {
          'configId': 'custom1',
          'className': 'com.example.User',
          'jarUrl': 'https://example.com/u.jar',
          'md5': '',
          'ext': '',
          'contentType': 'video',
        }),
        // 旧内置种子行（builtin+seedId）：迁移摘除。
        row('seed_oldpy', 'pyImport', {
          'path': '/tmp/seed/old.py',
          'ext': '',
          'contentType': 'video',
          'builtin': true,
          'seedId': 'oldpy',
        }),
        // 旧内置 jar 行（builtin+jarImport）：迁移摘除。
        row('jar:zakatv:ZakaOld', 'jarImport', {
          'configId': 'zakatv',
          'className': 'com.github.catvod.spider.ZakaOld',
          'jarUrl': 'asset:assets/jars/zakatv.jar',
          'md5': zakatvJarMd5,
          'ext': '',
          'contentType': 'video',
          'builtin': true,
        }),
      ]),
    });
    await registry.load();
  });

  tearDown(() {
    registry.debugSqlStationsOverride = null;
    registry.debugSqlImportedOverride = null;
    registry.debugGatedNativeOverride = null;
  });

  test('一次性迁移：旧内置种子/jar 行摘除，用户自导行保留', () {
    final ids = registry.custom.map((e) => e.id).toSet();
    expect(ids.contains('seed_oldpy'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaOld'), isFalse);
    expect(ids.contains('import_user1'), isTrue);
    expect(ids.contains('import_userjar'), isTrue);
  });

  test('buildSqlSiteEntries：py/legado/jar 建行，nativeGate 不建行', () {
    final entries = buildSqlSiteEntries(fakeStations);
    expect(entries, hasLength(4));
    final byId = {for (final e in entries) e.id: e};

    final py = byId['seed_missav']!;
    expect(py.kind, SourceKind.pyImport);
    expect(py.address, 'missav.py');
    expect(py.extra['path'], '/tmp/sql/missav.py');
    expect(py.extra['ext'], '');
    expect(py.extra['contentType'], 'video');
    expect(py.extra['builtin'], isFalse);
    expect(py.extra['sqlManaged'], isTrue);
    expect(py.extra['sqlCanon'], 'missav');
    expect(py.extra.containsKey('hasExplore'), isFalse);

    final legado = byId['seed_legado1']!;
    expect(legado.kind, SourceKind.legadoImport);
    expect(legado.extra['hasExplore'], isTrue);
    expect(legado.extra['verifyNote'], '出口未验');

    final jar = byId['jar:zakatv:ZakaTest']!;
    expect(jar.kind, SourceKind.jarImport);
    expect(jar.extra['configId'], 'zakatv');
    expect(jar.extra['className'], 'com.github.catvod.spider.ZakaTest');
    expect(jar.extra['jarUrl'], 'asset:assets/jars/zakatv.jar');
    expect(jar.extra['md5'], zakatvJarMd5);
    expect(jar.extra['ext'], '{"a":1}');
    expect(jar.extra.containsKey('extPath'), isFalse);
    expect(jar.extra['sqlManaged'], isTrue);

    final yt = byId['jar:youtube:YouTube']!;
    expect(yt.extra['configId'], 'youtube');
    expect(yt.extra['jarUrl'], 'asset:assets/jars/youtube.jar');
    expect(yt.extra['md5'], youtubeJarMd5);
    expect(yt.extra['ext'], '');
    expect(yt.extra['extPath'], '/tmp/sql/youtube3.json');

    expect(byId.containsKey('hongguo'), isFalse);
  });

  test('syncSqlSites：导入建 SQL 行、未导入全撤，用户行不动', () async {
    registry.debugSqlStationsOverride = fakeStations;
    registry.debugSqlImportedOverride = true;
    await registry.syncSqlSites();
    var ids = registry.custom.map((e) => e.id).toSet();
    expect(ids.contains('seed_missav'), isTrue);
    expect(ids.contains('seed_legado1'), isTrue);
    expect(ids.contains('jar:zakatv:ZakaTest'), isTrue);
    expect(ids.contains('jar:youtube:YouTube'), isTrue);
    expect(ids.contains('import_user1'), isTrue);
    expect(ids.contains('import_userjar'), isTrue);

    // 用户关掉的 SQL 站，对账不复活。
    await registry.setCustomEnabled('seed_missav', false);
    await registry.syncSqlSites();
    expect(registry.customById('seed_missav')!.enabled, isFalse);
    await registry.setCustomEnabled('seed_missav', true);

    registry.debugSqlImportedOverride = false;
    await registry.syncSqlSites();
    ids = registry.custom.map((e) => e.id).toSet();
    expect(ids.contains('seed_missav'), isFalse);
    expect(ids.contains('seed_legado1'), isFalse);
    expect(ids.contains('jar:zakatv:ZakaTest'), isFalse);
    expect(ids.contains('jar:youtube:YouTube'), isFalse);
    expect(ids.contains('import_user1'), isTrue);
    expect(ids.contains('import_userjar'), isTrue);
  });

  test('边界：站点库未导入时自导行与插件行不受影响，SQL 行不在', () async {
    // 远程插件站照旧走 syncIdjPluginSites 装好登记（与站点库无关）。
    IdjPluginStore.probeHandler =
        ({
          required String pluginId,
          required String script,
          required Map<String, dynamic> manifest,
        }) async {};
    IdjPluginStore.siteKeyTaken = null;
    try {
      await registry.idjStore.installBundleText(_idjBundleText());
      await registry.syncIdjPluginSites();
      expect(registry.customById('idj_demo'), isNotNull);

      // 站点库未导入（版本不符未激活时 service.imported 同样为
      // false，走同一条名单态路径）：SQL 行全不在，但存量行原样。
      registry.debugSqlStationsOverride = fakeStations;
      registry.debugSqlImportedOverride = false;
      await registry.syncSqlSites();

      expect(
        registry.custom.where((e) => e.extra['sqlManaged'] == true),
        isEmpty,
      );
      expect(registry.customById('seed_missav'), isNull);
      // 用户自导行还在且 clientFor 可达（注册表层）。
      expect(registry.customById('import_user1'), isNotNull);
      expect(registry.customById('import_userjar'), isNotNull);
      expect(await registry.clientFor('import_user1'), isNotNull);
      // 插件行还在且 clientFor 可达。
      expect(registry.customById('idj_demo'), isNotNull);
      expect(await registry.clientFor('idj_demo'), isNotNull);
    } finally {
      await registry.idjStore.uninstall('com.idj.ext.demo');
      await registry.syncIdjPluginSites();
      IdjPluginStore.probeHandler = null;
    }
  });

  test('门禁闸：gated 未导入回 null，original 恒放行，导入后放行', () async {
    registry.debugGatedNativeOverride = (_) => true;
    registry.debugSqlImportedOverride = false;
    expect(registry.sqlGateBlocks('hongguo'), isTrue);
    // original 保险：哪怕假件把所有 id 都报 gated 也不拦番茄。
    expect(registry.sqlGateBlocks('original'), isFalse);
    expect(await registry.clientFor('hongguo'), isNull);
    expect(registry.hasDramaContentClient('hongguo'), isFalse);
    expect(await registry.clientFor('original'), isNotNull);

    registry.debugSqlImportedOverride = true;
    expect(registry.sqlGateBlocks('hongguo'), isFalse);
    expect(await registry.clientFor('hongguo'), isNotNull);
    expect(registry.hasDramaContentClient('hongguo'), isTrue);
  });

  unimportedGroup();
}

/// 未导入态整组验收（用户 21:36 令：未导入当一等状态测）：
/// 全新态加载、名单态渲染、点未激活/gated 裸行的中文提示、
/// 番茄不被门禁误伤、界面无英文异常原文。
void unimportedGroup() {
  final registry = SourceRegistry.instance;
  const promptText =
      '站点库还没导入，这个站暂时看不了。去『我的 → 数据库导入』导入『站点库.sql』后就能用。';

  test('unimported_fresh_state：空偏好 load 不抛、无 SQL 行无旧内置行', () async {
    registry.debugResetForTest();
    SharedPreferences.setMockInitialValues({});
    await registry.load();
    await registry.syncSqlSites();
    expect(SiteLibraryService.instance.imported, isFalse);
    expect(
      registry.custom.where((e) => e.extra['sqlManaged'] == true),
      isEmpty,
    );
    expect(
      registry.custom.where(
        (e) =>
            e.extra['builtin'] == true &&
            (e.extra['seedId'] != null || e.kind == SourceKind.jarImport),
      ),
      isEmpty,
    );
    expect(registry.custom, isEmpty);
  });

  test('unimported_roster_filtering：成人按 xp 隐藏、已列/gated 裸行代表排除', () {
    const roster = <SiteLibraryRosterEntry>[
      SiteLibraryRosterEntry(
        id: 'missav',
        name: '🔞MissAV',
        zone: 'video',
        adult: true,
        sort: 2,
        kind: 'pyImport',
      ),
      SiteLibraryRosterEntry(
        id: 'plainone',
        name: '普通站',
        zone: 'video',
        adult: false,
        sort: 1,
        kind: 'pyImport',
      ),
      SiteLibraryRosterEntry(
        id: 'hongguo',
        name: '红果',
        zone: 'drama',
        adult: false,
        sort: 0,
        kind: 'nativeGate',
      ),
      SiteLibraryRosterEntry(
        id: 'listedone',
        name: '已在册',
        zone: 'novel',
        adult: false,
        sort: 3,
        kind: 'legadoImport',
      ),
    ];
    final atZero = inactiveRosterEntries(
      roster: roster,
      listedIds: {'listedone'},
      gatedNativeIds: {'hongguo'},
      bareRepresentedIds: {'hongguo'},
      xp: 0,
    );
    // missav 是第 4 档成人站，xp 0 整行隐藏；hongguo 已由裸行代表
    // 不重复列；listedone 已在册排除；只剩普通站。
    expect(atZero.map((e) => e.id), ['plainone']);
    final atFull = inactiveRosterEntries(
      roster: roster,
      listedIds: {'listedone'},
      gatedNativeIds: {'hongguo'},
      bareRepresentedIds: {'hongguo'},
      xp: 99999,
    );
    expect(atFull.map((e) => e.id), ['plainone', 'missav']);
  });

  test(
    'unimported_original_and_gate：番茄可达、gated 回 null、自导行可达',
    () async {
      // 与边界回归同口径：未导入态下 original 恒放行。
      registry.debugGatedNativeOverride = (_) => true;
      registry.debugSqlImportedOverride = false;
      expect(await registry.clientFor('original'), isNotNull);
      expect(registry.sqlGateBlocks('original'), isFalse);
      expect(await registry.clientFor('hongguo'), isNull);
      registry.debugGatedNativeOverride = null;
      registry.debugSqlImportedOverride = null;
    },
  );

  testWidgets('unimported_roster_rows_render：管理页未导入渲染名单行不抛', (
    tester,
  ) async {
    registry.debugSqlImportedOverride = false;
    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(bonusXp: 99999);
    try {
      await tester.runAsync(() => SiteLibraryService.instance.roster());
      await tester.pumpWidget(
        const MaterialApp(home: SourceManagementPage()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(
        find.text('未激活（站点库未导入）'),
        500,
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('未激活（站点库未导入）'), findsOneWidget);
      // 名单行：站名与分区都在（副标题「影视 · 未激活」），界面无
      // 英文异常原文。
      expect(find.text('名单普通站'), findsOneWidget);
      expect(find.text('影视 · 未激活'), findsWidgets);
      expect(find.textContaining('Exception'), findsNothing);
      expect(find.textContaining('Bad state'), findsNothing);
      expect(tester.takeException(), isNull);
    } finally {
      CultivationService.instance.snapshotNotifier.value =
          CultivationSnapshot.empty;
      registry.debugSqlImportedOverride = null;
    }
  });

  testWidgets('unimported_tap_inactive_row：点未激活行弹中文导入提示', (
    tester,
  ) async {
    registry.debugSqlImportedOverride = false;
    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(bonusXp: 99999);
    try {
      await tester.runAsync(() => SiteLibraryService.instance.roster());
      await tester.pumpWidget(
        const MaterialApp(home: SourceManagementPage()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(find.text('名单普通站'), 500);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('名单普通站'));
      await tester.pump(const Duration(milliseconds: 300));
      // 弹的是中文导入提示，不是打开流程也不是英文报错。
      expect(find.text(promptText), findsOneWidget);
      expect(find.text('去导入'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('知道了'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(promptText), findsNothing);
    } finally {
      CultivationService.instance.snapshotNotifier.value =
          CultivationSnapshot.empty;
      registry.debugSqlImportedOverride = null;
    }
  });

  testWidgets('unimported_tap_gated_bare_row：gated 裸行点出同一中文提示', (
    tester,
  ) async {
    registry.debugGatedNativeOverride = (id) => id == 'hongguo';
    registry.debugSqlImportedOverride = false;
    try {
      await tester.runAsync(() => SiteLibraryService.instance.roster());
      await tester.pumpWidget(
        const MaterialApp(home: SourceManagementPage()),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.scrollUntilVisible(find.text('红果'), 500);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('红果'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text(promptText), findsOneWidget);
      expect(find.text('去导入'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('知道了'));
      await tester.pump(const Duration(milliseconds: 300));
    } finally {
      registry.debugGatedNativeOverride = null;
      registry.debugSqlImportedOverride = null;
    }
  });
}

/// 演示插件包（与 source_registry_idj_test 同款最小包）。
String _idjBundleText() => jsonEncode({
  'manifest': {
    'schema': 1,
    'id': 'com.idj.ext.demo',
    'name': '演示插件',
    'version': '1.0.0',
    'entry': 'main.js',
    'type': 'video',
    'adult': false,
    'capabilities': ['home', 'category', 'detail', 'play'],
    'permissions': {
      'http': ['example.com'],
      'media': ['example.com'],
      'cloudflare': false,
      'storage': false,
      'login': false,
    },
  },
  'files': {'main.js': 'export default {};'},
});
