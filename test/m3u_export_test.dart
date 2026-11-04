import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/m3u_export.dart';
import 'package:fqapp/services/m3u_export_db.dart';
import 'package:fqapp/services/m3u_export_download.dart';
import 'package:fqapp/services/one_click_py.dart';
import 'package:fqapp/services/source_registry.dart';

class _FakePyClient extends DramaSiteContentClient {
  _FakePyClient({
    required this.categoryList,
    required this.pages,
    required this.details,
    required this.plays,
  });

  final List<DramaSiteCategory> categoryList;
  final Map<String, List<DramaSiteItem>> pages;
  final Map<String, DramaSiteDetail> details;
  final Map<String, String> plays;
  final requestedPages = <String>[];

  @override
  Future<List<DramaSiteCategory>> categories() async => categoryList;

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    requestedPages.add('$categoryId/$page');
    final items = pages['$categoryId/$page'] ?? const <DramaSiteItem>[];
    return DramaSiteCatalogPage(items: items, hasMore: false);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final detail = details[seriesId];
    if (detail == null) throw StateError('无详情');
    return detail;
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    final url = plays[episode.videoId];
    if (url == null) throw StateError('取流失败');
    return DramaPlaySource(url: url);
  }
}

class _FakeM3uSink implements OneClickDownloadSink {
  String? savedFileName;
  String? savedText;

  @override
  Future<String> saveText({
    required String fileName,
    required String text,
  }) async {
    savedFileName = fileName;
    savedText = text;
    return '/storage/emulated/0/Download/$fileName';
  }
}

SourceEntry _pyEntry(String name) {
  return SourceEntry(
    id: 'import_m3u',
    name: name,
    kind: SourceKind.pyImport,
    address: 'example.py',
    extra: {'path': '/tmp/imported_py/example.py', 'contentType': 'mixed'},
  );
}

class _FakeDownloader implements VideoDownloader {
  _FakeDownloader({this.failWhenUrlContains = const {}});

  final Set<String> failWhenUrlContains;
  final downloadedUrls = <String>[];
  var calls = 0;

  @override
  Future<String> downloadVideo({
    required String url,
    required Map<String, String> headers,
    required Directory targetDir,
    VideoDownloadProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    calls++;
    if (failWhenUrlContains.any(url.contains)) {
      throw StateError('下载失败');
    }
    downloadedUrls.add(url);
    onProgress?.call(1, 1);
    return '/local/video_$calls.m3u8';
  }
}

class _ThrowingDbSink implements M3uExportDbSink {
  @override
  Future<void> saveExport({
    required String siteId,
    required String siteName,
    required List<M3uExportCategoryInfo> categories,
    required List<M3uExportVideoRecord> videos,
  }) async {
    throw StateError('数据库写失败');
  }

  @override
  Future<List<M3uExportVideoRecord>> listVideos({
    required bool gateOpen,
    String? siteId,
    String? categoryId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<M3uExportCategoryInfo>> listCategories({
    required bool gateOpen,
    String? siteId,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<M3uExportVideoRecord?> getVideo({
    required bool gateOpen,
    required String siteId,
    required String videoId,
  }) async {
    throw UnimplementedError();
  }
}

DramaSiteItem _item(String id, String title, {String cover = ''}) {
  return DramaSiteItem(id: id, title: title, cover: cover);
}

void main() {
  group('m3u8 判定', () {
    test('只认 http(s) 且路径以 .m3u8 结尾', () {
      expect(isExportableM3u8('https://cdn.example.com/a.m3u8'), isTrue);
      expect(
        isExportableM3u8('https://cdn.example.com/a.m3u8?token=abc'),
        isTrue,
      );
      expect(isExportableM3u8('https://cdn.example.com/A.M3U8'), isTrue);
      expect(isExportableM3u8('https://cdn.example.com/a.mp4'), isFalse);
      expect(isExportableM3u8('novel://abc'), isFalse);
      expect(isExportableM3u8(''), isFalse);
    });
  });

  group('文件名', () {
    test('非法字符改下划线，全非法时回落 site', () {
      expect(m3uFileNameForSite('甲站/乙：丙'), '甲站_乙：丙.m3u');
      expect(m3uFileNameForSite('///'), 'site.m3u');
      expect(m3uFileNameForSite('  '), 'site.m3u');
    });
  });

  group('导出流程', () {
    test('全部分类 1:1，翻页到空页为止', () async {
      final client = _FakePyClient(
        categoryList: const [
          DramaSiteCategory('1', '电影'),
          DramaSiteCategory('2', '剧集'),
        ],
        pages: {
          '1/1': [_item('v1', '片一'), _item('v2', '片二')],
          '1/2': [_item('v3', '片三')],
          '2/1': [_item('v4', '剧一')],
        },
        details: const {},
        plays: {
          '\u0001v1': 'https://cdn.example.com/v1.m3u8',
          '\u0001v2': 'https://cdn.example.com/v2.m3u8',
          '\u0001v3': 'https://cdn.example.com/v3.m3u8',
          '\u0001v4': 'https://cdn.example.com/v4.m3u8',
        },
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        gateOpen: true,
      );
      expect(result.successCount, 4);
      expect(result.skippedCount, 0);
      expect(result.categoriesTotal, 2);
      expect(result.emptyCategories, isEmpty);
      expect(result.downloadPath, '/storage/emulated/0/Download/测试站.m3u');
      expect(sink.savedFileName, '测试站.m3u');
      final text = sink.savedText!;
      expect(text.startsWith('#EXTM3U\n'), isTrue);
      for (final title in ['片一', '片二', '片三', '剧一']) {
        expect(text, contains('#EXTINF:-1,$title\n'));
      }
      expect(text, contains('https://cdn.example.com/v4.m3u8'));
    });

    test('只收 m3u8：mp4 与取流失败跳过，详情兜底能救回', () async {
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [
            _item('mp4', '直链片'),
            _item('fallback', '兜底片'),
            _item('query', '带参片'),
            _item('novel', '小说条目'),
            _item('dead', '死链片'),
          ],
        },
        details: {
          'fallback': DramaSiteDetail(
            id: 'fallback',
            title: '兜底片',
            cover: '',
            episodes: const [
              DramaSiteEpisode(
                videoId: '线路\u0001ep1',
                title: '第1集',
                seriesId: 'fallback',
              ),
            ],
          ),
        },
        plays: {
          '\u0001mp4': 'https://cdn.example.com/a.mp4',
          '\u0001query': 'https://cdn.example.com/q.m3u8?sign=1',
          '\u0001novel': 'novel://abc',
          '线路\u0001ep1': 'https://cdn.example.com/ep1.m3u8',
        },
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        gateOpen: true,
      );
      expect(result.successCount, 2);
      expect(result.skippedCount, 3);
      expect(sink.savedText, contains('https://cdn.example.com/ep1.m3u8'));
      expect(sink.savedText, contains('https://cdn.example.com/q.m3u8?sign=1'));
      expect(sink.savedText, isNot(contains('a.mp4')));
      expect(sink.savedText, isNot(contains('novel://')));
    });

    test('重复页停，不无限翻页', () async {
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [_item('v1', '片一')],
          '1/2': [_item('v1', '片一')],
        },
        details: const {},
        plays: {'\u0001v1': 'https://cdn.example.com/v1.m3u8'},
      );
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: _FakeM3uSink(),
        gateOpen: true,
      );
      expect(result.successCount, 1);
      expect(client.requestedPages, ['1/1', '1/2']);
    });

    test('空分类记入无可用分类，标题换行清洗', () async {
      final client = _FakePyClient(
        categoryList: const [
          DramaSiteCategory('1', '空分类'),
          DramaSiteCategory('2', '有片'),
        ],
        pages: {
          '2/1': [_item('v1', '片一\n第二行')],
        },
        details: const {},
        plays: {'\u0001v1': 'https://cdn.example.com/v1.m3u8'},
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        gateOpen: true,
      );
      expect(result.successCount, 1);
      expect(result.emptyCategories, ['空分类']);
      expect(sink.savedText, contains('#EXTINF:-1,片一 第二行\n'));
    });

    test('取消后不保存', () async {
      final cancellation = M3uExportCancellation()..cancel();
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: _FakePyClient(
          categoryList: const [DramaSiteCategory('1', '电影')],
          pages: const {},
          details: const {},
          plays: const {},
        ),
        downloadSink: sink,
        gateOpen: true,
        cancellation: cancellation,
      );
      expect(result.cancelled, isTrue);
      expect(result.downloadPath, isNull);
      expect(sink.savedText, isNull);
    });
  });

  group('午夜门禁', () {
    test('午夜未开时成人站导出直接抛错', () async {
      await expectLater(
        exportSiteM3u(
          siteId: 'test_site',
          siteName: '🔞测试站',
          client: _FakePyClient(
            categoryList: const [],
            pages: const {},
            details: const {},
            plays: const {},
          ),
          downloadSink: _FakeM3uSink(),
          gateOpen: false,
        ),
        throwsStateError,
      );
    });

    test('站点筛选：只留已开启、有副本的 py 站，午夜未开滤掉成人站', () {
      final entries = [
        _pyEntry('普通站'),
        _pyEntry('🔞成人站'),
        const SourceEntry(
          id: 'jar1',
          name: 'jar 站',
          kind: SourceKind.jarImport,
          extra: {'path': '/tmp/x.jar'},
        ),
        SourceEntry(
          id: 'disabled',
          name: '已关站',
          kind: SourceKind.pyImport,
          enabled: false,
          extra: {'path': '/tmp/y.py'},
        ),
        const SourceEntry(
          id: 'nopath',
          name: '无副本',
          kind: SourceKind.pyImport,
          extra: {},
        ),
      ];
      expect(
        [for (final e in filterM3uExportSites(entries, false)) e.name],
        ['普通站'],
      );
      expect(
        [for (final e in filterM3uExportSites(entries, true)) e.name],
        ['普通站', '🔞成人站'],
      );
    });

    test('筛选放开到全部影视站：采集/JS/规则/书源视频站进，非视频内容类型不进', () {
      final entries = [
        const SourceEntry(
          id: 'maccms1',
          name: '采集站',
          kind: SourceKind.customMaccms,
          address: 'https://example.test',
          extra: {'contentType': 'video'},
        ),
        const SourceEntry(
          id: 'js1',
          name: 'JS 站',
          kind: SourceKind.jsImport,
          extra: {'path': '/tmp/x.js', 'contentType': 'video'},
        ),
        const SourceEntry(
          id: 'xbpq1',
          name: '规则站',
          kind: SourceKind.xbpqImport,
          extra: {'path': '/tmp/x.json', 'contentType': 'mixed'},
        ),
        const SourceEntry(
          id: 'legado1',
          name: '书源站',
          kind: SourceKind.legadoImport,
          extra: {'path': '/tmp/x.json', 'contentType': 'video'},
        ),
        const SourceEntry(
          id: 'js_novel',
          name: 'JS 小说站',
          kind: SourceKind.jsImport,
          extra: {'path': '/tmp/n.js', 'contentType': 'novel'},
        ),
        const SourceEntry(
          id: 'maccms_noaddr',
          name: '无地址采集站',
          kind: SourceKind.customMaccms,
          extra: {'contentType': 'video'},
        ),
      ];
      expect(
        [for (final e in filterM3uExportSites(entries, true)) e.name],
        ['采集站', 'JS 站', '规则站', '书源站'],
      );
    });

    test('内置站导出目标：除番茄短剧外全进，午夜未开滤成人站，红果放行非 m3u8', () {
      const sites = [
        DramaSite('original', '番茄短剧'),
        DramaSite('hongguo', '红果'),
        DramaSite('fanguo', '饭果'),
        DramaSite('🔞adult', '🔞成人站'),
      ];
      final open = m3uExportBuiltinTargets(sites, (_) => true, true);
      expect(
        [for (final t in open) t.siteId],
        ['hongguo', 'fanguo', '🔞adult'],
      );
      expect(
        open.firstWhere((t) => t.siteId == 'hongguo').allowNonM3u8,
        isTrue,
      );
      expect(
        open.firstWhere((t) => t.siteId == 'fanguo').allowNonM3u8,
        isFalse,
      );
      final closed = m3uExportBuiltinTargets(sites, (_) => true, false);
      expect(
        [for (final t in closed) t.siteId],
        ['hongguo', 'fanguo'],
      );
      final disabled = m3uExportBuiltinTargets(
        sites,
        (id) => id != 'fanguo',
        true,
      );
      expect(
        [for (final t in disabled) t.siteId],
        ['hongguo', '🔞adult'],
      );
    });

    test('jar 站筛选：配齐三件才进，includeJar 关时不进', () {
      const jarReady = SourceEntry(
        id: 'jar_ok',
        name: 'jar 站',
        kind: SourceKind.jarImport,
        extra: {
          'className': 'com.example.Spider',
          'configId': 'cfg',
          'jarUrl': 'asset:jars/x.jar',
        },
      );
      const jarBroken = SourceEntry(
        id: 'jar_bad',
        name: '缺配 jar 站',
        kind: SourceKind.jarImport,
        extra: {'configId': 'cfg', 'jarUrl': 'asset:jars/x.jar'},
      );
      const jarAdult = SourceEntry(
        id: 'jar_adult',
        name: '🔞jar 成人站',
        kind: SourceKind.jarImport,
        extra: {
          'className': 'com.example.Spider',
          'configId': 'cfg',
          'jarUrl': 'asset:jars/x.jar',
        },
      );
      final entries = [jarReady, jarBroken, jarAdult];
      expect(
        [
          for (final e in filterM3uExportSites(entries, true)) e.name,
        ],
        ['jar 站', '🔞jar 成人站'],
      );
      expect(
        [
          for (final e in filterM3uExportSites(
            entries,
            true,
            includeJar: false,
          ))
            e.name,
        ],
        isEmpty,
      );
      expect(
        [
          for (final e in filterM3uExportSites(entries, false)) e.name,
        ],
        ['jar 站'],
      );
    });
  });

  group('非 m3u8 直链模式（红果）', () {
    test('控制字符地址不认，http 直链认', () {
      expect(isHttpPlayableUrl('https://cdn.example.com/a.mp4'), isTrue);
      expect(isHttpPlayableUrl('novel://abc'), isFalse);
      expect(
        isHttpPlayableUrl('https://cdn.example.com/\u0001a.mp4'),
        isFalse,
      );
      expect(
        isExportableM3u8('https://cdn.example.com/\u0001a.m3u8'),
        isFalse,
      );
    });

    test('allowNonM3u8 时 mp4 计入成功并单列非 m3u8 条数', () async {
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [_item('mp4', '直链片'), _item('m3u8', '清单片')],
        },
        details: const {},
        plays: {
          '\u0001mp4': 'https://cdn.example.com/a.mp4',
          '\u0001m3u8': 'https://cdn.example.com/b.m3u8',
        },
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '红果',
        client: client,
        downloadSink: sink,
        gateOpen: true,
        allowNonM3u8: true,
      );
      expect(result.successCount, 2);
      expect(result.nonM3u8Count, 1);
      expect(result.skippedCount, 0);
      expect(sink.savedText, contains('https://cdn.example.com/a.mp4'));
    });

    test('跨分类同视频去重，不重复写行', () async {
      final client = _FakePyClient(
        categoryList: const [
          DramaSiteCategory('all', '全部'),
          DramaSiteCategory('real-drama', '真人剧'),
        ],
        pages: {
          'all/1': [_item('v1', '片一')],
          'real-drama/1': [_item('v1', '片一')],
        },
        details: const {},
        plays: {'\u0001v1': 'https://cdn.example.com/v1.m3u8'},
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '红果',
        client: client,
        downloadSink: sink,
        gateOpen: true,
        allowNonM3u8: true,
      );
      expect(result.successCount, 1);
      expect(result.duplicateCount, 1);
      expect('https://cdn.example.com/v1.m3u8'.allMatches(sink.savedText!).length, 1);
    });
  });

  group('本地数据库（一次爬取、两份产出）', () {
    test('导出同时写库：标题、地址、封面、简介、站点、分类齐全', () async {
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [
            _item('v1', '有详情片'),
            _item('v2', '无详情片', cover: 'list_cover.jpg'),
          ],
        },
        details: {
          'v1': const DramaSiteDetail(
            id: 'v1',
            title: '有详情片',
            cover: 'detail_cover.jpg',
            synopsis: '<p>简介文字</p>',
            extra: {'vod_actor': '演员A', 'vod_year': '2024'},
            episodes: [
              DramaSiteEpisode(
                videoId: 'flag\u0001ep1',
                title: '第1集',
                seriesId: 'v1',
              ),
            ],
          ),
        },
        plays: {
          'flag\u0001ep1': 'https://cdn.example.com/v1.m3u8',
          '\u0001v2': 'https://cdn.example.com/v2.m3u8',
        },
      );
      final sink = _FakeM3uSink();
      final db = MemoryM3uExportDb();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        dbSink: db,
        gateOpen: true,
      );
      expect(result.successCount, 2);
      expect(result.dbVideoCount, 2);
      expect(result.dbError, isNull);
      expect(sink.savedText, contains('https://cdn.example.com/v1.m3u8'));
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.length, 2);
      final withDetail = rows.firstWhere((row) => row.videoId == 'v1');
      expect(withDetail.title, '有详情片');
      expect(withDetail.url, 'https://cdn.example.com/v1.m3u8');
      expect(withDetail.cover, 'detail_cover.jpg');
      expect(withDetail.synopsis, '简介文字');
      expect(withDetail.siteName, '测试站');
      expect(withDetail.categoryName, '电影');
      expect(withDetail.categoryPath, '电影');
      expect(withDetail.extra['vod_actor'], '演员A');
      expect(withDetail.extra['vod_year'], '2024');
      expect(withDetail.episodeCount, 1);
      final withoutDetail = rows.firstWhere((row) => row.videoId == 'v2');
      expect(withoutDetail.cover, 'list_cover.jpg');
      expect(withoutDetail.synopsis, isEmpty);
      expect(withoutDetail.extra, isEmpty);
      expect(withoutDetail.episodeCount, 0);
      expect(db.categories.length, 1);
      expect(db.categories.values.first.categoryName, '电影');
      expect(db.categories.values.first.categoryPath, '电影');
    });

    test('重复导出按视频唯一标识更新，不重复插', () async {
      final plays = <String, String>{'\u0001v1': 'https://cdn.example.com/old.m3u8'};
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [_item('v1', '片一')],
        },
        details: const {},
        plays: plays,
      );
      final db = MemoryM3uExportDb();
      await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: _FakeM3uSink(),
        dbSink: db,
        gateOpen: true,
      );
      plays['\u0001v1'] = 'https://cdn.example.com/new.m3u8';
      await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: _FakeM3uSink(),
        dbSink: db,
        gateOpen: true,
      );
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.length, 1);
      expect(rows.first.url, 'https://cdn.example.com/new.m3u8');
    });

    test('午夜未开时库里成人条目不露，午夜开了才露', () async {
      final db = MemoryM3uExportDb();
      await db.saveExport(
        siteId: 'adult_site',
        siteName: '🔞成人站',
        categories: const [
          M3uExportCategoryInfo(
            siteId: 'adult_site',
            siteName: '🔞成人站',
            categoryId: '1',
            categoryName: '电影',
            updatedAt: 1,
          ),
        ],
        videos: const [
          M3uExportVideoRecord(
            siteId: 'adult_site',
            siteName: '🔞成人站',
            categoryId: '1',
            categoryName: '电影',
            videoId: 'v1',
            title: '片一',
            url: 'https://cdn.example.com/v1.m3u8',
            cover: '',
            synopsis: '',
            updatedAt: 1,
          ),
        ],
      );
      expect(await db.listVideos(gateOpen: false), isEmpty);
      expect((await db.listVideos(gateOpen: true)).length, 1);
      expect(
        (await db.listVideos(gateOpen: true, siteId: 'other_site')),
        isEmpty,
      );
      expect(
        (await db.listVideos(gateOpen: true, categoryId: '2')),
        isEmpty,
      );
    });

    test('数据库写失败不丢 m3u，结果里带警告', () async {
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [_item('v1', '片一')],
        },
        details: const {},
        plays: {'\u0001v1': 'https://cdn.example.com/v1.m3u8'},
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        dbSink: _ThrowingDbSink(),
        gateOpen: true,
      );
      expect(result.successCount, 1);
      expect(result.dbVideoCount, 0);
      expect(result.dbError, contains('数据库写失败'));
      expect(sink.savedText, contains('https://cdn.example.com/v1.m3u8'));
    });
  });

  group('本地下载（范围与失败回落）', () {
    _FakePyClient twoCategoryClient() {
      return _FakePyClient(
        categoryList: const [
          DramaSiteCategory('1', '电影'),
          DramaSiteCategory('2', '剧集'),
        ],
        pages: {
          '1/1': [_item('v1', '片一')],
          '2/1': [_item('v2', '剧一')],
        },
        details: const {},
        plays: {
          '\u0001v1': 'https://cdn.example.com/v1.m3u8',
          '\u0001v2': 'https://cdn.example.com/v2.m3u8',
        },
      );
    }

    M3uExportDownloadOptions optionsFor(
      _FakeDownloader downloader,
      M3uExportDownloadScope scope, {
      String? categoryId,
      String? videoId,
    }) {
      return M3uExportDownloadOptions(
        scope: scope,
        categoryId: categoryId,
        videoId: videoId,
        downloader: downloader,
        directoryResolver: () async => Directory.systemTemp,
      );
    }

    test('整站范围：全部视频走本地路径，m3u 与 db 一致', () async {
      final downloader = _FakeDownloader();
      final sink = _FakeM3uSink();
      final db = MemoryM3uExportDb();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: twoCategoryClient(),
        downloadSink: sink,
        dbSink: db,
        downloadOptions: optionsFor(downloader, M3uExportDownloadScope.site),
        gateOpen: true,
      );
      expect(result.downloadedCount, 2);
      expect(result.downloadFailedCount, 0);
      expect(downloader.downloadedUrls.length, 2);
      expect(sink.savedText, contains('/local/video_1.m3u8'));
      expect(sink.savedText, contains('/local/video_2.m3u8'));
      expect(
        sink.savedText,
        contains('#ONLINE-URL:https://cdn.example.com/v1.m3u8'),
      );
      final rows = await db.listVideos(gateOpen: true);
      expect(rows.length, 2);
      expect(
        rows.every((row) => row.localPath.startsWith('/local/')),
        isTrue,
      );
      expect(
        rows.every((row) => row.url.startsWith('https://cdn.example.com/')),
        isTrue,
      );
    });

    test('按分类范围：只下选中分类，其他分类仍用在线地址', () async {
      final downloader = _FakeDownloader();
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: twoCategoryClient(),
        downloadSink: sink,
        downloadOptions: optionsFor(
          downloader,
          M3uExportDownloadScope.category,
          categoryId: '2',
        ),
        gateOpen: true,
      );
      expect(result.downloadedCount, 1);
      expect(
        downloader.downloadedUrls,
        ['https://cdn.example.com/v2.m3u8'],
      );
      expect(sink.savedText, contains('https://cdn.example.com/v1.m3u8'));
      expect(sink.savedText, contains('/local/video_1.m3u8'));
    });

    test('按单视频范围：只下选中视频', () async {
      final downloader = _FakeDownloader();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: twoCategoryClient(),
        downloadSink: _FakeM3uSink(),
        downloadOptions: optionsFor(
          downloader,
          M3uExportDownloadScope.video,
          videoId: 'v1',
        ),
        gateOpen: true,
      );
      expect(result.downloadedCount, 1);
      expect(
        downloader.downloadedUrls,
        ['https://cdn.example.com/v1.m3u8'],
      );
    });

    test('下载失败：该条回落在线地址并计失败，其他条照常本地', () async {
      final downloader = _FakeDownloader(failWhenUrlContains: {'fail'});
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [_item('v1', '片一'), _item('v2', '片二')],
        },
        details: const {},
        plays: {
          '\u0001v1': 'https://cdn.example.com/v1.m3u8',
          '\u0001v2': 'https://cdn.example.com/fail.m3u8',
        },
      );
      final sink = _FakeM3uSink();
      final db = MemoryM3uExportDb();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        dbSink: db,
        downloadOptions: optionsFor(downloader, M3uExportDownloadScope.site),
        gateOpen: true,
      );
      expect(result.downloadedCount, 1);
      expect(result.downloadFailedCount, 1);
      expect(result.successCount, 2);
      expect(sink.savedText, contains('https://cdn.example.com/fail.m3u8'));
      final rows = await db.listVideos(gateOpen: true);
      final failed = rows.firstWhere((row) => row.videoId == 'v2');
      expect(failed.url, 'https://cdn.example.com/fail.m3u8');
      expect(failed.localPath, isEmpty);
      final ok = rows.firstWhere((row) => row.videoId == 'v1');
      expect(ok.url, 'https://cdn.example.com/v1.m3u8');
      expect(ok.localPath, startsWith('/local/'));
    });
  });

  group('双轨（线上地址与本地路径双保留）', () {
    M3uExportVideoRecord record({
      String url = 'https://cdn.example.com/v1.m3u8',
      String localPath = '',
    }) {
      return M3uExportVideoRecord(
        siteId: 'test_site',
        siteName: '测试站',
        categoryId: '1',
        categoryName: '电影',
        videoId: 'v1',
        title: '片一',
        url: url,
        localPath: localPath,
        cover: '',
        synopsis: '',
        updatedAt: 1,
      );
    }

    test('记录往返保留线上地址与本地路径', () {
      final restored = M3uExportVideoRecord.fromMap(
        record(localPath: '/local/video_1.m3u8').toMap(),
      );
      expect(restored?.url, 'https://cdn.example.com/v1.m3u8');
      expect(restored?.localPath, '/local/video_1.m3u8');
    });

    test('旧形状兼容：只有本地路径的 url 认成本地路径', () {
      final restored = M3uExportVideoRecord.fromMap(
        record(url: '/local/old.m3u8').toMap()
          ..remove('localPath'),
      );
      expect(restored?.url, isEmpty);
      expect(restored?.localPath, '/local/old.m3u8');
    });

    test('播放解析：本地文件在走本地，本地没了走线上，两处都没有回空', () async {
      final temp = await Directory.systemTemp.createTemp('m3u_dual_');
      try {
        final localFile = File('${temp.path}/video.m3u8');
        await localFile.writeAsString('#EXTM3U');
        expect(
          resolveExportedPlayUrl(record(localPath: localFile.path)),
          localFile.path,
        );
        expect(
          resolveExportedPlayUrl(
            record(localPath: '${temp.path}/gone.m3u8'),
          ),
          'https://cdn.example.com/v1.m3u8',
        );
        expect(
          resolveExportedPlayUrl(record(url: '')),
          isNull,
        );
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });
  });

  group('原始链接只读', () {
    M3uExportVideoRecord record({
      required String videoId,
      String url = 'https://cdn.example.com/v.m3u8',
      String localPath = '',
    }) {
      return M3uExportVideoRecord(
        siteId: 'py_site',
        siteName: 'py 站',
        categoryId: '1',
        categoryName: '电影',
        videoId: videoId,
        title: '片',
        url: url,
        localPath: localPath,
        cover: '',
        synopsis: '',
        updatedAt: 1,
      );
    }

    test('写库合并：新记录没下载时沿用旧本地路径，旧文件没了不留死指针', () async {
      final temp = await Directory.systemTemp.createTemp('link_ro_');
      try {
        final localFile = File('${temp.path}/v.m3u8');
        await localFile.writeAsString('#EXTM3U');
        final old = record(videoId: 'v1', localPath: localFile.path);
        final kept = record(videoId: 'v1').mergedForSave(old);
        expect(kept.localPath, localFile.path);
        expect(kept.url, 'https://cdn.example.com/v.m3u8');
        localFile.deleteSync();
        final dropped = record(videoId: 'v1').mergedForSave(old);
        expect(dropped.localPath, isEmpty);
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });

    test('写库合并：新记录线上地址为空时沿用旧线上地址', () {
      final old = record(videoId: 'v1');
      final kept = record(videoId: 'v1', url: '').mergedForSave(old);
      expect(kept.url, 'https://cdn.example.com/v.m3u8');
    });

    test('重复导出不刷库：先下载后只导地址，库里本地路径与线上地址都在', () async {
      final temp = await Directory.systemTemp.createTemp('link_ro2_');
      try {
        final localFile = File('${temp.path}/v.m3u8');
        await localFile.writeAsString('#EXTM3U');
        final db = MemoryM3uExportDb();
        await db.saveExport(
          siteId: 'py_site',
          siteName: 'py 站',
          categories: const [],
          videos: [record(videoId: 'v1', localPath: localFile.path)],
        );
        await db.saveExport(
          siteId: 'py_site',
          siteName: 'py 站',
          categories: const [],
          videos: [record(videoId: 'v1')],
        );
        final kept = await db.getVideo(
          gateOpen: true,
          siteId: 'py_site',
          videoId: 'v1',
        );
        expect(kept?.localPath, localFile.path);
        expect(kept?.url, 'https://cdn.example.com/v.m3u8');
      } finally {
        if (temp.existsSync()) temp.deleteSync(recursive: true);
      }
    });

    test('播放解析是纯读：解析前后记录字段不变', () {
      final before = record(videoId: 'v1', localPath: '/no/such/file.m3u8');
      resolveExportedPlayUrl(before);
      expect(before.url, 'https://cdn.example.com/v.m3u8');
      expect(before.localPath, '/no/such/file.m3u8');
    });
  });

  group('预爬取 20 页封顶', () {
    test('每分类最多爬 20 页，第 21 页不请求并记截断', () async {
      final pages = <String, List<DramaSiteItem>>{};
      final plays = <String, String>{};
      for (var n = 1; n <= 25; n++) {
        pages['1/$n'] = [_item('p$n', '片$n')];
        plays['\u0001p$n'] = 'https://cdn.example.com/p$n.m3u8';
      }
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: pages,
        details: const {},
        plays: plays,
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        gateOpen: true,
      );
      expect(result.successCount, 20);
      expect(result.truncatedCategories, ['电影']);
      expect(client.requestedPages.length, 20);
      expect(client.requestedPages.last, '1/20');
      expect(sink.savedText, contains('https://cdn.example.com/p20.m3u8'));
      expect(
        sink.savedText,
        isNot(contains('https://cdn.example.com/p21.m3u8')),
      );
    });

    test('不足 20 页按实际页数爬完，不记截断', () async {
      final client = _FakePyClient(
        categoryList: const [DramaSiteCategory('1', '电影')],
        pages: {
          '1/1': [_item('p1', '片一')],
          '1/2': [_item('p2', '片二')],
        },
        details: const {},
        plays: {
          '\u0001p1': 'https://cdn.example.com/p1.m3u8',
          '\u0001p2': 'https://cdn.example.com/p2.m3u8',
        },
      );
      final sink = _FakeM3uSink();
      final result = await exportSiteM3u(
        siteId: 'test_site',
        siteName: '测试站',
        client: client,
        downloadSink: sink,
        gateOpen: true,
      );
      expect(result.successCount, 2);
      expect(result.truncatedCategories, isEmpty);
      expect(client.requestedPages, ['1/1', '1/2', '1/3']);
    });
  });
}
