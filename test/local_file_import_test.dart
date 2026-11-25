import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/source_management_page.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/file_text_picker.dart';
import 'package:fqapp/services/local_file_import.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地文件批量导入统一入口测试（修仙版树）。
///
/// 覆盖：多选批量（成功 + 失败混合、失败不中断、汇总内容正确）、
/// GBK 文件、小说 py 的分区提示、选文件失败有提示、三种 JSON 的
/// 内容嗅探分流、本地 TVBox 配置展开、HTML 最小可用版、导入 id
/// 同毫秒不撞、分区文案与 videoPagePlayableSites 一致。
const _videoPy = '''
class Spider:
    def getName(self):
        return "batch-video"
    def homeContent(self, filter):
        return {"class": [{"type_id": "1", "type_name": "电影"}], "list": []}
    def homeVideoContent(self):
        return {"list": [{"vod_id": "1", "vod_name": "片", "vod_pic": "https://example.test/a.jpg", "vod_remarks": "正片", "vod_play_url": "https://example.test/a.m3u8"}]}
    def categoryContent(self, tid, pg, filter, extend):
        return {"list": [], "page": 1, "pagecount": 1, "limit": 20, "total": 0}
    def detailContent(self, ids):
        return {"list": []}
    def searchContent(self, key, quick, pg):
        return {"list": []}
    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": "https://example.test/a.m3u8", "header": {}}
    def isVideoFormat(self, url):
        return True
    def manualVideoCheck(self):
        return True
    def localProxy(self, param):
        return [200, "text/plain", None, ""]
''';

/// 只有 novel:// 标记的 py：自动分类判成小说，进不了影视区。
const _novelPy = '''
class Spider:
    def getName(self):
        return "batch-novel"
    def homeContent(self, filter):
        return {"class": [], "list": []}
    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": "novel://book/1", "header": {}}
''';

const _legadoJson = '''
{"bookSourceName": "批量书源", "bookSourceUrl": "https://example.test/", "bookSourceType": 0}
''';

const _xbpqJson = '''
{"base": "https://example.test/", "cateUrl": "https://example.test/cate/{cateId}/{catePg}"}
''';

/// 本地 TVBox 配置：一个接口站（不联网）+ 一个内联规则的 XBPQ 站。
const _tvboxJson = '''
{"sites": [
  {"key": "a1", "name": "接口站", "api": "https://example.test/api.php"},
  {"key": "x1", "name": "规则站", "api": "csp_XBPQ", "ext": "{\\"base\\": \\"https://example.test/\\", \\"cateUrl\\": \\"https://example.test/cate\\"}"}
]}
''';

/// “# 测试蜘蛛”打头的 py：注释里的四个汉字取 GBK 字节，
/// 其余 ASCII 部分两种编码相同。
List<int> _gbkPyBytes() => [
  ...'# '.codeUnits,
  0xB2, 0xE2, // 测
  0xCA, 0xD4, // 试
  0xD6, 0xA9, // 蜘
  0xD6, 0xEB, // 蛛
  ...'\nclass Spider:\n    def getName(self):\n        return "gbk-site"\n    def playerContent(self, flag, id, vipFlags):\n        return {"parse": 0, "url": "https://example.test/a.m3u8", "header": {}}\n'
      .codeUnits,
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('local_import_');
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
    const pyChannel = MethodChannel('juhe/pybridge');
    messenger.setMockMethodCallHandler(pyChannel, (call) async {
      if (call.method == 'status') {
        return jsonEncode({'available': false});
      }
      if (call.method == 'validate') {
        return jsonEncode({
          'ok': true,
          'hasSpider': true,
          'missing': [],
          'error': '',
        });
      }
      return null;
    });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(pyChannel, null);
    });
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('读文件解码：UTF-8 正常；GBK 回落解出中文；BOM 去掉', () {
    expect(decodePickedText(utf8.encode('hello 蜘蛛')), 'hello 蜘蛛');
    expect(
      decodePickedText([0xB2, 0xE2, 0xCA, 0xD4, 0x0A]),
      '测试\n',
    );
    expect(
      decodePickedText([0xEF, 0xBB, 0xBF, ...utf8.encode('abc')]),
      'abc',
    );
    // 全坏字节也不抛错（宽容 UTF-8 兜底）。
    expect(() => decodePickedText([0xFF, 0xFE, 0xFD]), returnsNormally);
  });

  test('JSON 嗅探：三种 JSON 各归其位，认不出返回 null', () {
    expect(
      sniffJsonKind(jsonDecode(_legadoJson)),
      LocalJsonKind.legado,
    );
    expect(
      sniffJsonKind(jsonDecode(
        '[{"bookSourceName": "甲", "bookSourceUrl": "https://a.test/"}]',
      )),
      LocalJsonKind.legado,
    );
    expect(sniffJsonKind(jsonDecode(_tvboxJson)), LocalJsonKind.tvbox);
    expect(
      sniffJsonKind(jsonDecode(
        '[{"key": "a", "name": "甲", "api": "https://a.test/"}]',
      )),
      LocalJsonKind.tvbox,
    );
    expect(sniffJsonKind(jsonDecode(_xbpqJson)), LocalJsonKind.xbpq);
    expect(sniffJsonKind(jsonDecode('{"foo": 1}')), isNull);
    expect(sniffJsonKind(jsonDecode('[1, 2]')), isNull);
    expect(sniffJsonKind('plain'), isNull);
  });

  test('文件分流：扩展名优先，扩展名外的内容嗅探兜底', () {
    expect(classifyLocalImportFile('a.py', 'whatever'), LocalImportKind.py);
    expect(classifyLocalImportFile('a.js', 'whatever'), LocalImportKind.js);
    expect(
      classifyLocalImportFile('a.html', '<html></html>'),
      LocalImportKind.html,
    );
    expect(
      classifyLocalImportFile('a.htm', '<html></html>'),
      LocalImportKind.html,
    );
    expect(
      classifyLocalImportFile('a.json', _legadoJson),
      LocalImportKind.jsonLegado,
    );
    expect(
      classifyLocalImportFile('a.json', _tvboxJson),
      LocalImportKind.jsonTvbox,
    );
    expect(
      classifyLocalImportFile('a.json', _xbpqJson),
      LocalImportKind.jsonXbpq,
    );
    expect(
      () => classifyLocalImportFile('a.json', '{"foo": 1}'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('无法识别'),
        ),
      ),
    );
    expect(
      () => classifyLocalImportFile('a.json', '{"broken": '),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('不是有效的 JSON'),
        ),
      ),
    );
    // 无扩展名 / .txt：内容嗅探。
    expect(
      classifyLocalImportFile('noext', _videoPy),
      LocalImportKind.py,
    );
    expect(
      classifyLocalImportFile('note.txt', '<html><body>x</body></html>'),
      LocalImportKind.html,
    );
    expect(
      () => classifyLocalImportFile('note.txt', 'hello world'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('无法识别'),
        ),
      ),
    );
  });

  test('批量混合：失败不中断整批，汇总写清成功/失败数与失败原因', () async {
    final result = await LocalFileImportService.instance.importPickedFiles([
      (
        name: 'video_site.py',
        bytes: utf8.encode(_videoPy),
        error: null,
      ),
      (name: 'bad.json', bytes: utf8.encode('{"broken": '), error: null),
      (name: 'novel_site.py', bytes: utf8.encode(_novelPy), error: null),
      (name: 'book.json', bytes: utf8.encode(_legadoJson), error: null),
      (name: 'note.txt', bytes: utf8.encode('hello world'), error: null),
    ]);
    expect(result.successCount, 3);
    expect(result.failureCount, 2);
    // 失败在中间，后面的小说 py 与书源照样导进来了。
    final registry = SourceRegistry.instance;
    expect(registry.custom.any((e) => e.name == 'novel_site'), isTrue);
    expect(registry.custom.any((e) => e.name == '批量书源'), isTrue);
    expect(registry.custom.any((e) => e.name == 'video_site'), isTrue);
    expect(result.summaryText, contains('成功 3 个，失败 2 个'));
    expect(result.summaryText, contains('bad.json'));
    expect(result.summaryText, contains('不是有效的 JSON'));
    expect(result.summaryText, contains('note.txt'));
    expect(result.summaryText, contains('无法识别'));
    // 每个站的分区都写在汇总里。
    expect(result.summaryText, contains('video_site（影视区）'));
    expect(result.summaryText, contains('novel_site（小说区）'));
    expect(result.summaryText, contains('批量书源（小说区）'));
    // 读不到字节的文件也进汇总、不掀整批。
    final unreadable = await LocalFileImportService.instance
        .importPickedFiles([
          (name: 'gone.py', bytes: null, error: '读不到文件'),
          (
            name: 'video_site2.py',
            bytes: utf8.encode(_videoPy),
            error: null,
          ),
        ]);
    expect(unreadable.successCount, 1);
    expect(unreadable.failureCount, 1);
    expect(unreadable.summaryText, contains('gone.py'));
    expect(unreadable.summaryText, contains('读不到文件'));
  });

  test('GBK 文件：批量导入解出中文、落盘文件含中文注释', () async {
    final result = await LocalFileImportService.instance.importPickedFiles([
      (name: 'gbk_site.py', bytes: _gbkPyBytes(), error: null),
    ]);
    expect(result.successCount, 1);
    final entry = SourceRegistry.instance.custom.firstWhere(
      (e) => e.name == 'gbk_site',
    );
    final path = entry.extra['path'] as String;
    expect(await File(path).readAsString(), contains('测试蜘蛛'));
  });

  test('小说 py 分区：汇总写小说区，且与影视区切换表一致', () async {
    final result = await LocalFileImportService.instance.importPickedFiles([
      (name: 'video_zone.py', bytes: utf8.encode(_videoPy), error: null),
      (name: 'novel_zone.py', bytes: utf8.encode(_novelPy), error: null),
    ]);
    expect(result.successCount, 2);
    expect(result.hasVideoZoneSite, isTrue);
    final registry = SourceRegistry.instance;
    final video = registry.custom.firstWhere((e) => e.name == 'video_zone');
    final novel = registry.custom.firstWhere((e) => e.name == 'novel_zone');
    expect(zoneLabelForEntry(video), '影视区');
    expect(zoneLabelForEntry(novel), '小说区');
    // 分区文案与影视区切换弹窗的判定一致：视频站在表里、小说站不在。
    expect(videoPagePlayableSites([video]).length, 1);
    expect(videoPagePlayableSites([novel]), isEmpty);
    expect(result.summaryText, contains('video_zone（影视区）'));
    expect(result.summaryText, contains('novel_zone（小说区）'));
  });

  test('本地 TVBox 配置：接口站 + XBPQ 站展开，同名重导不重复建站', () async {
    final first = await LocalFileImportService.instance.importPickedFiles([
      (name: 'mytvbox.json', bytes: utf8.encode(_tvboxJson), error: null),
    ]);
    expect(first.successCount, 1);
    final registry = SourceRegistry.instance;
    final parent = registry.custom.firstWhere(
      (e) => e.id == 'localtvbox_mytvbox',
    );
    expect(parent.kind, SourceKind.remoteJson);
    expect(parent.detail, contains('已展开 2 个站'));
    final children = [
      for (final e in registry.custom)
        if (e.extra['remoteConfigId'] == parent.id) e,
    ];
    expect(children.map((e) => e.name), containsAll(['接口站', '规则站']));
    expect(first.summaryText, contains('接口站（影视区）'));
    expect(first.summaryText, contains('规则站（影视区）'));
    // 同名文件再导一次：子站 id 不变、只出现一次（替换不是追加）。
    await LocalFileImportService.instance.importPickedFiles([
      (name: 'mytvbox.json', bytes: utf8.encode(_tvboxJson), error: null),
    ]);
    expect(
      registry.custom.where((e) => e.id == 'localtvbox_mytvbox_a1').length,
      1,
    );
    expect(
      registry.custom.where((e) => e.id == 'localtvbox_mytvbox_x1').length,
      1,
    );
    expect(
      registry.custom.where((e) => e.id == 'localtvbox_mytvbox').length,
      1,
    );
  });

  test('本地 TVBox 配置：没有可展开的站时报清原因', () async {
    expect(
      SourceRegistry.instance.addLocalTvboxConfig(
        '{"sites": []}',
        fileName: 'empty.json',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('没有可展开的站点'),
        ),
      ),
    );
    expect(
      SourceRegistry.instance.addLocalTvboxConfig(
        'not json',
        fileName: 'bad.json',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('不是有效的 JSON'),
        ),
      ),
    );
  });

  test('HTML 最小可用版：登记本地网页条目、文件落盘、不进影视区', () async {
    final result = await LocalFileImportService.instance.importPickedFiles([
      (
        name: 'page.html',
        bytes: utf8.encode('<html><body>你好</body></html>'),
        error: null,
      ),
    ]);
    expect(result.successCount, 1);
    final entry = SourceRegistry.instance.custom.firstWhere(
      (e) => e.name == 'page',
    );
    expect(entry.kind, SourceKind.htmlImport);
    expect(entry.contentType, ContentType.mixed);
    expect(zoneLabelForEntry(entry), '站源管理可见');
    expect(videoPagePlayableSites([entry]), isEmpty);
    final path = entry.extra['path'] as String;
    expect(await File(path).exists(), isTrue);
    expect(await File(path).readAsString(), contains('你好'));
    expect(result.summaryText, contains('page（站源管理可见）'));
    // 站源管理“本地网页”组里看得见。
    final groups = managementTechGroups(SourceRegistry.instance.custom);
    expect(
      groups
          .firstWhere((g) => g.title == '本地网页')
          .entries
          .any((e) => e.id == entry.id),
      isTrue,
    );
    // 删站时本地副本一起清掉。
    await SourceRegistry.instance.removeCustom(entry.id);
    expect(await File(path).exists(), isFalse);
  });

  test('批量同毫秒导入：id 不撞', () async {
    final result = await LocalFileImportService.instance.importPickedFiles([
      (name: 'same1.py', bytes: utf8.encode(_videoPy), error: null),
      (name: 'same2.py', bytes: utf8.encode(_videoPy), error: null),
      (name: 'same3.py', bytes: utf8.encode(_videoPy), error: null),
    ]);
    expect(result.successCount, 3);
    final ids = [
      for (final e in SourceRegistry.instance.custom)
        if (e.name.startsWith('same')) e.id,
    ];
    expect(ids.length, 3);
    expect(ids.toSet().length, 3);
  });

  test('导入区一次性标记：写一次、读一次、再读没有', () async {
    expect(await consumeSiteGridOpenImportZoneOnce(), isFalse);
    await markSiteGridOpenImportZoneOnce();
    expect(await consumeSiteGridOpenImportZoneOnce(), isTrue);
    expect(await consumeSiteGridOpenImportZoneOnce(), isFalse);
  });

  testWidgets('批量导入按钮：选文件器起不来时弹“选文件失败”', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 测试环境里 file_selector 没有平台实现：mock 通道直接抛
    // MissingPluginException（与真机上选择器起不来同款错误），
    // 验页里接住后弹 SnackBar，不静默。
    const selectorChannel = MethodChannel('plugins.flutter.io/file_selector');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(selectorChannel, (call) async {
          throw MissingPluginException(
            'No implementation found for method ${call.method} on channel plugins.flutter.io/file_selector',
          );
        });
    addTearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance
          .defaultBinaryMessenger
          .setMockMethodCallHandler(selectorChannel, null);
    });
    await tester.pumpWidget(
      const MaterialApp(home: SourceManagementPage()),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await tester.scrollUntilVisible(
      find.text('批量导入本地文件（.py / .json / .html）'),
      500,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.text('批量导入本地文件（.py / .json / .html）'),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('批量导入本地文件（.py / .json / .html）'));
    // 测试环境里 file_selector 没有平台实现，openFiles 抛错；
    // 页里接住后弹 SnackBar，不静默。
    for (var i = 0; i < 10; i++) {
      if (find.textContaining('选文件失败').evaluate().isNotEmpty) break;
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.textContaining('选文件失败'), findsOneWidget);
  });
}
