import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/source_management_page.dart';
import 'package:fqapp/services/site_library.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/file_text_picker.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 导入本地源“选后链路”诊断复现（修仙版树，不改产品代码）。
///
/// 用户症状（2026-11-25 08:26 + 补充）：文件选择器能打开、能选到文件，
/// 但选完之后没有“导入成功”提示，站点列表里也看不见导入的源。
/// 本文件模拟“已选到文件”这个状态往下走：
/// 读文件 -> 解析 -> 注册 -> 列表可见性 -> 成功提示。
const _videoPy = '''
class Spider:
    def getName(self):
        return "diag-video"
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

/// 只有 novel:// 标记、没有任何视频/音频标记的 py：自动分类会判成小说。
const _novelOnlyPy = '''
class Spider:
    def getName(self):
        return "diag-novel"
    def homeContent(self, filter):
        return {"class": [], "list": []}
    def playerContent(self, flag, id, vipFlags):
        return {"parse": 0, "url": "novel://book/1", "header": {}}
''';

const _minLegadoJson = '''
{"bookSourceName": "诊断书源", "bookSourceUrl": "https://example.test/", "bookSourceType": 0}
''';

const _minXbpqJson = '''
{"base": "https://example.test/", "cateUrl": "https://example.test/cate/{cateId}/{catePg}"}
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('import_diag_');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      // 站点库批（2026-11-27）：管理页初始化会经站点库服务问目录，
      // 三种目录都给临时目录（与 local_file_import 测试同款），
      // 只答 support 时服务加载卡住、页面建不出列表。
      if (call.method == 'getApplicationSupportDirectory' ||
          call.method == 'getApplicationDocumentsDirectory' ||
          call.method == 'getTemporaryDirectory') {
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
    // PyBridge.validate 在本机（非 Android）本就短路返回 null；
    // 但弹窗链路在 widget 测试里走到通道调用时会挂在 FakeAsync 里，
    // mock 一下让它立刻回“桥不可用”，与本机行为一致。
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

  test('py 视频蜘蛛：addPyImport 成功、登记可见、文件落盘', () async {
    final entry = await SourceRegistry.instance.addPyImport(
      '诊断视频站',
      _videoPy,
    );
    expect(entry.kind, SourceKind.pyImport);
    expect(entry.name, '诊断视频站');
    // contentType：含 .m3u8 标记、无小说独占标记 -> 保持 mixed。
    expect(entry.contentType, ContentType.mixed);
    expect(SourceRegistry.instance.custom.any((e) => e.id == entry.id), isTrue);
    final path = entry.extra['path'] as String?;
    expect(path, isNotNull);
    expect(await File(path!).exists(), isTrue);
    expect(await File(path).readAsString(), contains('class Spider'));
    // 站源管理“Python 内容源”组里看得见（按 kind 分组，不过滤类型）。
    final groups = managementTechGroups(SourceRegistry.instance.custom);
    final pyGroup = groups.firstWhere((g) => g.title == 'Python 内容源');
    expect(pyGroup.entries.any((e) => e.id == entry.id), isTrue);
    // 影视区切换弹窗的导入区里也看得见（video/mixed 才进）。
    expect(
      videoPagePlayableSites(SourceRegistry.instance.custom).any(
        (e) => e.id == entry.id,
      ),
      isTrue,
    );
  });

  test('py 小说蜘蛛：注册成功，但影视区看不见（自动分类判成小说）', () async {
    final entry = await SourceRegistry.instance.addPyImport(
      '诊断小说站',
      _novelOnlyPy,
    );
    expect(entry.contentType, ContentType.novel);
    // 站源管理里仍在 Python 组。
    final groups = managementTechGroups(SourceRegistry.instance.custom);
    expect(
      groups
          .firstWhere((g) => g.title == 'Python 内容源')
          .entries
          .any((e) => e.id == entry.id),
      isTrue,
    );
    // 但影视区只留 video/mixed：小说站进不了 videoPagePlayableSites，
    // 也就进不了影视区切换弹窗与影视网格。
    expect(
      videoPagePlayableSites(SourceRegistry.instance.custom).any(
        (e) => e.id == entry.id,
      ),
      isFalse,
    );
  });

  test('读文件步：GBK 编码 py 用 readAsString 抛 FormatException', () async {
    // “测试”两个汉字的 GBK 字节：pickTextFile 里 XFile.readAsString()
    // 默认 utf8 解码，GBK 文件到这里就抛（dart:io 包一层
    // FileSystemException，XFile 直接抛 FormatException），
    // 两个调用点都没有 try/catch。
    final file = File('${temp.path}/gbk.py');
    await file.writeAsBytes([0xB2, 0xE2, 0xCA, 0xD4, 0x0A]);
    expect(file.readAsString(), throwsA(isA<FileSystemException>()));
    // 对照：utf8 文件正常读出。
    final okFile = File('${temp.path}/utf8.py');
    await okFile.writeAsString(_videoPy);
    expect(await okFile.readAsString(), contains('class Spider'));
  });

  test('pickTextFile：无平台实现时直接抛错（调用点无 try/catch）', () {
    // flutter test 里 file_selector 的平台通道未实现；
    // 手机上对应的是系统文件选择器起不来/读不到时抛出的 PlatformException，
    // 两种情况 pickTextFile 都原样往外抛，站源管理页与设置页的
    // “选择文件”按钮都没有接住。
    expect(
      pickTextFile(label: 'Python', extensions: ['py']),
      throwsA(anyOf(isA<MissingPluginException>(), isA<PlatformException>())),
    );
  });

  test('json 书源：addLegadoImport 成功、进阅读书源组', () async {
    final entries = await SourceRegistry.instance.addLegadoImport(
      _minLegadoJson,
    );
    expect(entries.length, 1);
    expect(entries.single.name, '诊断书源');
    expect(entries.single.contentType, ContentType.novel);
    final groups = managementTechGroups(SourceRegistry.instance.custom);
    expect(
      groups
          .firstWhere((g) => g.title == '阅读书源')
          .entries
          .any((e) => e.id == entries.single.id),
      isTrue,
    );
  });

  test('json 坏内容：addLegadoImport 抛错（设置页会弹 SnackBar，管理页无此入口）', () async {
    expect(
      SourceRegistry.instance.addLegadoImport('not json at all'),
      throwsA(isA<FormatException>()),
    );
    // 有 JSON 但缺书源名/地址：不抛格式错，抛“没有可用的书源”。
    expect(
      SourceRegistry.instance.addLegadoImport('{"foo": 1}'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('没有可用的书源'),
        ),
      ),
    );
  });

  test('xbpq 最小规则：addXbpqImport 成功；缺地址抛 StateError', () async {
    final entry = await SourceRegistry.instance.addXbpqImport(
      '诊断 XBPQ',
      _minXbpqJson,
    );
    expect(entry.kind, SourceKind.xbpqImport);
    expect(
      SourceRegistry.instance.addXbpqImport('诊断 XBPQ2', '{"a": 1}'),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('缺少主页地址'),
        ),
      ),
    );
  });

  test('js 最小源码：addJsImport 成功', () async {
    final entry = await SourceRegistry.instance.addJsImport(
      '诊断 JS 站',
      'function homeContent(){ return {}; }',
    );
    expect(entry.kind, SourceKind.jsImport);
    expect(
      SourceRegistry.instance.custom.any((e) => e.id == entry.id),
      isTrue,
    );
  });

  test('空源码：addPyImport 抛“蜘蛛源码不能为空”（页面的 catch 会弹 SnackBar）', () async {
    expect(
      SourceRegistry.instance.addPyImport('空站', '   '),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('蜘蛛源码不能为空'),
        ),
      ),
    );
  });

  test('jar：本机非 Android 抛“jar 桥仅支持 Android”（手机链路本机复现不了）', () async {
    expect(
      SourceRegistry.instance.addJarImport(
        '诊断 Jar',
        'https://example.test/a.jar',
        '',
        '',
        '',
      ),
      throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('jar 桥仅支持 Android'),
        ),
      ),
    );
  });

  testWidgets('站源管理弹窗 A：空源码点“添加”有报错提示', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 站点库批（2026-11-27）：先在真时钟区预热站点库名单缓存，
    // 管理页才建得出列表（与 local_file_import 测试同款）。
    await tester.runAsync(() => SiteLibraryService.instance.roster());
    await tester.pumpWidget(
      const MaterialApp(home: SourceManagementPage()),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 站点库批（2026-11-27）：未导入态页面多了 639 行未激活名单组，
    // 导入入口被推到名单组之后，滚动次数放大。
    await tester.scrollUntilVisible(
      find.text('导入 Python / Jar / JS / XBPQ'),
      500,
      maxScrolls: 250,
    );
    await tester.pumpAndSettle();
    // scrollUntilVisible 只保证“可见”，按钮可能贴在视口底边、中心点
    // 在 600 高之外导致 tap 脱靶；再 ensureVisible 一次让它完整进视口。
    await tester.ensureVisible(find.text('导入 Python / Jar / JS / XBPQ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 Python / Jar / JS / XBPQ'));
    await tester.pumpAndSettle();
    expect(find.text('导入蜘蛛'), findsOneWidget);

    // 空源码点“添加”：有 SnackBar 报错（失败反馈是有的）。
    // 注意：“添加”点了就关弹窗（先 pop 再在页里调 addPyImport），
    // 所以报错 SnackBar 是落在页上、弹窗已关。
    await tester.tap(find.text('添加'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('蜘蛛源码不能为空'), findsOneWidget);
    expect(find.text('导入蜘蛛'), findsNothing);
  });

  testWidgets('站源管理弹窗 B：有源码导入成功，有成功提示（含分区）', (tester) async {
    SharedPreferences.setMockInitialValues({});
    // 站点库批（2026-11-27）：先在真时钟区预热站点库名单缓存，
    // 管理页才建得出列表（与 local_file_import 测试同款）。
    await tester.runAsync(() => SiteLibraryService.instance.roster());
    await tester.pumpWidget(
      const MaterialApp(home: SourceManagementPage()),
    );
    await tester.pump(const Duration(milliseconds: 200));
    // 站点库批（2026-11-27）：未导入态页面多了 639 行未激活名单组，
    // 导入入口被推到名单组之后，滚动次数放大。
    await tester.scrollUntilVisible(
      find.text('导入 Python / Jar / JS / XBPQ'),
      500,
      maxScrolls: 250,
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('导入 Python / Jar / JS / XBPQ'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导入 Python / Jar / JS / XBPQ'));
    await tester.pumpAndSettle();
    expect(find.text('导入蜘蛛'), findsOneWidget);

    // 模拟“已选到文件”：把最小 py 源码填进框里（跳过真机文件选择器）。
    // 弹窗里 TextField 顺序：0=名称，1=蜘蛛源码。600 高的测试视口里
    // 源码框（maxLines 8）在折叠区下面，enterText 前先滚进视口，
    // 否则点按聚焦脱靶、文字落不进框，添加时会被当成空源码。
    await tester.ensureVisible(find.byType(TextField).at(0));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), '诊断弹窗站');
    await tester.ensureVisible(find.byType(TextField).at(1));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(1), _videoPy);
    await tester.tap(find.text('添加'));
    // 按钮点的后续链路里有真实文件 I/O 与平台通道调用：在 FakeAsync
    // 里它们要靠真时间片 + pump 交替推进；真时间轮询等登记里出现新站
    // （最多约 5 秒真时间），不等死。
    for (var i = 0; i < 15; i++) {
      if (SourceRegistry.instance.custom.any(
        (e) => e.name == '诊断弹窗站',
      )) {
        break;
      }
      await tester.runAsync(
        () => Future.delayed(const Duration(milliseconds: 300)),
      );
      await tester.pump();
    }
    // 导入成功：弹窗关了、登记里有了新站 …
    // 先推 500ms 让弹窗退出动画走完，再断言。
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('导入蜘蛛'), findsNothing);
    expect(
      SourceRegistry.instance.custom.any((e) => e.name == '诊断弹窗站'),
      isTrue,
    );
    // … 成功提示也有了（2026-11-25 统一入口批修掉的死因一）：
    // SnackBar 写清站名与分区（视频 py → 影视区）。
    expect(find.byType(SnackBar), findsOneWidget);
    expect(find.textContaining('已导入'), findsOneWidget);
    // 站点库批（2026-11-27）：页面滚得更远后批量导入区的说明文案
    // （含「影视区」）也进了 widget 树，裸 textContaining 会撞两个；
    // 分区断言收窄到 SnackBar 内部。
    expect(
      find.descendant(
        of: find.byType(SnackBar),
        matching: find.textContaining('影视区'),
      ),
      findsOneWidget,
    );
  });
}
