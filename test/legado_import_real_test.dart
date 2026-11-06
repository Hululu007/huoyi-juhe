import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/legado_content.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 真实书源导入实测：用从真实书源网站下载的 JSON（见
/// test/fixtures/legado_import/）调 addLegadoImport / addLegadoRemote，
/// 逐份确认能导入、contentType 分对了类，并在站源管理里按书源/影视源
/// 分两组可见（isBookSourceEntry）。
///
/// 来源（2026-11-05 实测下载）：
/// - XIU2/Yuedu shuyuan（小说 22 条，sourceType 全 0）
/// - suwa-ko/legado-sources bilinovel.json（小说 1 条）
/// - entr0pia/MyLegadoSource bookSource.json（小说 55 条）
/// - Orokapei/BookSource Legado.json（小说 11 条，含拷贝漫画 H5，
///   但其 bookSourceType 也是 0，故仍分到小说——如实记录）
/// - jiwangyihao/source-j-legado zaimanhua.json（再漫画 1 条，
///   漫画站但 bookSourceType 为 0，故分到小说——如实记录）
/// - aoaostar 全量合集抽出的混合子集（小说 2、听书 2、漫画 2，
///   bookSourceType 分别为 0/1/2）
/// 影视（sourceType 4）在公开合集里找不到真源（全量 3907 条里
/// 0 条；luanmuc v2.3 还删了漫画/听书/影视只剩小说），故类型 4
/// 只用内存里的 LegadoSource 验分类映射，不冒充有真实影视源。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // TestWidgetsFlutterBinding 初始化后会把所有 HTTP 请求拦截回 400
  // （不真发请求）。远程导入要真发请求，故把 HttpOverrides 换回
  // 真实 HttpClient；只影响本测试文件。
  HttpOverrides.global = _RealHttpOverrides();
  late Directory temp;

  setUp(() async {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('legado_import_real_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationSupportDirectory') {
        return temp.path;
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<List<SourceEntry>> importFixture(String name) async {
    final text = await File(
      'test/fixtures/legado_import/$name',
    ).readAsString();
    return SourceRegistry.instance.addLegadoImport(text);
  }

  test('分类映射：bookSourceType 0/1/2/4 分到小说/听书/漫画/影视', () {
    LegadoSource sourceWithType(int type) => LegadoSource({
      'bookSourceName': 't$type',
      'bookSourceUrl': 'https://example.test/$type',
      'bookSourceType': type,
    });
    expect(
      contentTypeForLegadoSource(sourceWithType(0)).key,
      'novel',
    );
    expect(
      contentTypeForLegadoSource(sourceWithType(1)).key,
      'audio',
    );
    expect(
      contentTypeForLegadoSource(sourceWithType(2)).key,
      'comic',
    );
    expect(
      contentTypeForLegadoSource(sourceWithType(4)).key,
      'video',
    );
    // 缺字段默认 0 → 小说。
    expect(
      contentTypeForLegadoSource(
        LegadoSource({
          'bookSourceName': 'x',
          'bookSourceUrl': 'https://example.test/x',
        }),
      ).key,
      'novel',
    );
  });

  test('真实源：XIU2 小说合集 22 条全部分到小说（书源组）', () async {
    final entries = await importFixture('xiu2_shuyuan.json');
    expect(entries.length, 22);
    expect(
      entries.map((e) => e.contentType.key).toSet(),
      {'novel'},
    );
    expect(entries.every(isBookSourceEntry), isTrue);
    expect(entries.map((e) => e.name), contains('起点中文'));
  });

  test('真实源：哔哩轻小说 1 条分到小说', () async {
    final entries = await importFixture('suwako_bilinovel.json');
    expect(entries.length, 1);
    expect(entries.single.name, '哔哩轻小说');
    expect(entries.single.contentType.key, 'novel');
    expect(isBookSourceEntry(entries.single), isTrue);
  });

  test('真实源：aoaostar 混合子集按类型分到小说/听书/漫画', () async {
    final entries = await importFixture('aoaostar_mixed_subset.json');
    expect(entries.length, 6);
    final byName = {for (final e in entries) e.name: e.contentType.key};
    expect(byName['起点中文'], 'novel');
    expect(byName['番茄小说2'], 'novel');
    expect(byName['有声小说①'], 'audio');
    expect(byName['恋听网'], 'audio');
    expect(byName['粉丝漫画'], 'comic');
    expect(byName['好看漫画'], 'comic');
    // 六条全是书源（小说/听书/漫画），影视源组 0 条。
    expect(entries.every(isBookSourceEntry), isTrue);
    expect(entries.where((e) => !isBookSourceEntry(e)), isEmpty);
  });

  test('真实源：entr0pia 小说合集 55 条全部分到小说', () async {
    final entries = await importFixture('entr0pia_booksource.json');
    expect(entries.length, 55);
    expect(
      entries.map((e) => e.contentType.key).toSet(),
      {'novel'},
    );
    expect(entries.every(isBookSourceEntry), isTrue);
  });

  test('真实源：Orokapei 11 条全部分到小说（含拷贝漫画 H5，type 0）', () async {
    final entries = await importFixture('orokapei_legado.json');
    expect(entries.length, 11);
    expect(
      entries.map((e) => e.contentType.key).toSet(),
      {'novel'},
    );
    // 拷贝漫画 H5 是漫画站，但 bookSourceType 为 0，按字段分到小说。
    final comic = entries.firstWhere((e) => e.name.contains('漫'));
    expect(comic.contentType.key, 'novel');
  });

  test('真实源：再漫画 1 条（漫画站但 type 0）分到小说', () async {
    final entries = await importFixture('jiwangyihao_zaimanhua.json');
    expect(entries.length, 1);
    expect(entries.single.name, '再漫画');
    expect(entries.single.contentType.key, 'novel');
  });

  test('远程导入：suwa-ko 哔哩轻小说走 addLegadoRemote', () async {
    final entries = await SourceRegistry.instance.addLegadoRemote(
      'https://raw.githubusercontent.com/suwa-ko/legado-sources/main/bilinovel.json',
    );
    expect(entries.length, 1);
    expect(entries.single.name, '哔哩轻小说');
    expect(entries.single.contentType.key, 'novel');
  });

  test('远程导入：XIU2 shuyuan 走 addLegadoRemote', () async {
    final entries = await SourceRegistry.instance.addLegadoRemote(
      'https://raw.githubusercontent.com/XIU2/Yuedu/master/shuyuan',
    );
    expect(entries.length, 22);
    expect(
      entries.map((e) => e.contentType.key).toSet(),
      {'novel'},
    );
  });
}

/// 把 HTTP 交回真实客户端（绕过 TestWidgetsFlutterBinding 的 400 拦截），
/// 仅用于本文件的远程导入实测。
class _RealHttpOverrides extends HttpOverrides {
  // 必须显式 override：super.createHttpClient 直接建真实客户端，
  // 不走 HttpOverrides 链，才能盖掉 TestWidgetsFlutterBinding 的 400 拦截。
  @override
  // ignore: unnecessary_overrides
  HttpClient createHttpClient(SecurityContext? context) =>
      super.createHttpClient(context);
}
