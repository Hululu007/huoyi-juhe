import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/pages/series_detail_page.dart';
import 'package:fqapp/pages/tgdrama_channel_page.dart';
import 'package:fqapp/services/drama_playback.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_sites.dart';
import 'package:fqapp/services/shelf_store.dart';
import 'package:fqapp/services/tgdrama_content.dart';
import 'package:fqapp/services/tgdrama_service.dart';
import 'package:fqapp/widgets/home/drama_site_grid.dart';

/// 假服务：只覆盖 ensureRunning / lastError，不启动真服务、不联网。
class _FakeService extends TgdramaService {
  @override
  Future<bool> ensureRunning() async => true;

  @override
  String? get lastError => null;
}

/// 假 TG影视库客户端：catalog/detail/playSource 全按写死的数据回，
/// 不调 HTTP、不读库。继承正式类，这样 openDramaSiteItem 里的
/// `client is TgdramaContentClient` 判定与线上一致。
class _FakeTgdramaClient extends TgdramaContentClient {
  _FakeTgdramaClient()
    : super(
        httpClient: MockClient(
          (_) async => throw StateError('假客户端不应调 HTTP'),
        ),
        service: _FakeService(),
      );

  @override
  Future<List<DramaSiteCategory>> categories() async =>
      const [DramaSiteCategory('all', '全部')];

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) async {
    if (categoryId == TgdramaContentClient.channelsCategoryId) {
      return const DramaSiteCatalogPage(
        items: [
          DramaSiteItem(
            id: 'channel:-100111',
            title: '剧场一号',
            cover: '',
            remark: '128条消息',
          ),
        ],
        hasMore: false,
      );
    }
    if (categoryId == 'channel:-100111') {
      return const DramaSiteCatalogPage(
        items: [
          DramaSiteItem(id: '1', title: '剧一', cover: '', remark: '共12集'),
          DramaSiteItem(id: '2', title: '剧二', cover: '', remark: '共3集'),
        ],
        hasMore: false,
      );
    }
    return const DramaSiteCatalogPage(items: [], hasMore: false);
  }

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    if (seriesId == '1') {
      return const DramaSiteDetail(
        id: '1',
        title: '剧一',
        cover: '',
        synopsis: '简介一',
        episodes: [
          DramaSiteEpisode(videoId: '11', title: '第1集', seriesId: '1'),
          DramaSiteEpisode(videoId: '12', title: '第2集', seriesId: '1'),
        ],
      );
    }
    throw StateError('找不到该剧');
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    return const DramaPlaySource(url: 'http://127.0.0.1:5278/x.m3u8');
  }
}

void main() {
  late Directory directory;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await Directory.systemTemp.createTemp('tgdrama-channel-');
    Hive.init(directory.path);
    await ShelfStore.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    await directory.delete(recursive: true);
  });

  setUp(() async => ShelfStore.instance.clear());

  Future<void> pumpChannelPage(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: TgdramaChannelPage(
          siteId: 'tgdrama',
          channelId: '-100111',
          title: '剧场一号',
          client: _FakeTgdramaClient(),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('频道页：列出该频道收录的剧（标题与集数备注）', (tester) async {
    await pumpChannelPage(tester);
    expect(find.text('剧场一号'), findsOneWidget);
    expect(find.text('剧一'), findsOneWidget);
    expect(find.text('剧二'), findsOneWidget);
    expect(find.text('共12集'), findsOneWidget);
    expect(find.text('共3集'), findsOneWidget);
  });

  testWidgets('点频道条目：进频道页，不进剧详情页', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          // DramaSiteGrid 出的是 sliver，只能放在 CustomScrollView 里。
          body: CustomScrollView(
            slivers: [
              DramaSiteGrid(
                siteId: 'tgdrama',
                categoryId: TgdramaContentClient.channelsCategoryId,
                gridWidth: 800,
                client: _FakeTgdramaClient(),
                showFilterBar: false,
                columns: 4,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.text('剧场一号'), findsOneWidget);
    // 点频道：openDramaSiteItem 拦截，推进频道页（标题仍是频道名）。
    await tester.tap(find.text('剧场一号'));
    await tester.pump();
    await tester.pumpAndSettle();
    expect(find.byType(TgdramaChannelPage), findsOneWidget);
    // 频道页里不出现剧详情页。
    expect(find.byType(SeriesDetailPage), findsNothing);
  });

  testWidgets('频道页点剧：进该剧详情（分集列表），不直接播第 1 集', (tester) async {
    await pumpChannelPage(tester);
    expect(find.text('剧一'), findsOneWidget);
    await tester.tap(find.text('剧一'));
    await tester.pump();
    await tester.pumpAndSettle();
    // 进了剧详情页（标题是剧名），不是播放页。
    expect(find.byType(SeriesDetailPage), findsOneWidget);
    expect(find.text('剧一'), findsWidgets);
  });
}
