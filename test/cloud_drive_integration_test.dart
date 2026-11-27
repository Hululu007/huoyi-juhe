import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/cloud_drive/cloud_credential_store.dart';
import 'package:fqapp/cloud_drive/cloud_drive_client.dart';
import 'package:fqapp/cloud_drive/cloud_drive_login.dart';
import 'package:fqapp/cloud_drive/cloud_drive_models.dart';
import 'package:fqapp/cloud_drive/cloud_drive_stations.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/drama_site_play.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:fqapp/widgets/home/home_tab_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 假引擎接缝：只回夹具数据，不打网络。
class _FakeGateway implements CloudCatalogGateway {
  String lastCategory = '<unset>';
  String lastQuery = '<unset>';
  Drama? lastDetailDrama;
  Drama? lastResolveDrama;

  @override
  Future<CatalogPage> catalog({
    required String source,
    required int page,
    required String query,
    required String category,
  }) async {
    lastCategory = category;
    lastQuery = query;
    return CatalogPage(
      [
        const Drama(
          id: 'pan115:__all__',
          source: 'cloud:pan115',
          title: '全部',
          kind: 'folder',
          folderId: '__all__',
        ),
        const Drama(
          id: 'pan115:folderA',
          source: 'cloud:pan115',
          title: '电影',
          kind: 'folder',
          folderId: 'folderA',
        ),
        const Drama(
          id: 'pan115:file1',
          source: 'cloud:pan115',
          title: 'movie.mp4',
          description: '视频 · 1.0 GB',
          kind: 'video',
        ),
      ],
      hasMore: false,
      page: page,
    );
  }

  @override
  Future<DramaDetail> detail(Drama drama) async {
    lastDetailDrama = drama;
    return DramaDetail(drama, [
      Episode({'id': 'file1', 'title': 'movie.mp4'}, 1),
    ]);
  }

  @override
  Future<PlaybackPlan> resolve(Drama drama, Episode episode) async {
    lastResolveDrama = drama;
    if (episode.id == 'img1') {
      return const PlaybackPlan(
        url: 'pics://https://img.example/1.jpg',
        originalUrl: 'https://img.example/1.jpg',
      );
    }
    return const PlaybackPlan(
      url: 'https://cdn.example/movie.mp4',
      headers: {'User-Agent': 'ua'},
    );
  }
}

void main() {
  group('CloudDriveContentClient 映射', () {
    test('根分类只有一个「网盘」', () async {
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: _FakeGateway(),
      );
      final categories = await client.categories();
      expect(categories, hasLength(1));
      expect(categories.single.name, '网盘');
    });

    test('catalog：文件夹条目带 folder: 前缀与「文件夹」remark，文件条目原样', () async {
      final gateway = _FakeGateway();
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: gateway,
      );
      final page = await client.catalog('all', 1);
      expect(gateway.lastCategory, ''); // all 归一成引擎根
      expect(page.items, hasLength(3));
      final all = page.items[0];
      expect(all.id, 'folder:__all__');
      expect(all.remark, '文件夹');
      final folder = page.items[1];
      expect(folder.id, 'folder:folderA');
      expect(folder.title, '电影');
      final file = page.items[2];
      expect(file.id, 'pan115:file1');
      expect(file.remark, '视频 · 1.0 GB');
    });

    test('catalog 下钻：folder: 前缀与裸 folderId 都归一成引擎 category', () async {
      final gateway = _FakeGateway();
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: gateway,
      );
      await client.catalog('folder:folderA', 1);
      expect(gateway.lastCategory, 'folderA');
      await client.catalog('folderA', 2);
      expect(gateway.lastCategory, 'folderA');
      expect(
        CloudDriveContentClient.folderCategoryOf('folder:__all__'),
        '__all__',
      );
    });

    test('detail：先经 catalog 后按 id 取回缓存 Drama；未见过的 id 拼最小 Drama', () async {
      final gateway = _FakeGateway();
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: gateway,
      );
      await client.catalog('all', 1);
      final detail = await client.detail('pan115:file1');
      expect(gateway.lastDetailDrama?.title, 'movie.mp4');
      expect(detail.episodes, hasLength(1));
      expect(detail.episodes.single.videoId, 'file1');
      expect(detail.episodes.single.seriesId, 'pan115:file1');

      final unseen = await client.detail('pan115:fileX');
      expect(gateway.lastDetailDrama?.id, 'pan115:fileX');
      expect(gateway.lastDetailDrama?.source, 'cloud:pan115');
      expect(gateway.lastDetailDrama?.title, 'fileX');
      expect(unseen.id, 'pan115:fileX');
    });

    test('detail：文件夹条目不走详情，如实抛错', () async {
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: _FakeGateway(),
      );
      expect(
        () => client.detail('folder:folderA'),
        throwsA(isA<StateError>()),
      );
    });

    test('playSource：PlaybackPlan 映射 url+headers；图片 pics:// 原样透传', () async {
      final gateway = _FakeGateway();
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: gateway,
      );
      await client.catalog('all', 1);
      final source = await client.playSource(
        const DramaSiteEpisode(videoId: 'file1', title: 'movie.mp4', seriesId: 'pan115:file1'),
      );
      expect(source.url, 'https://cdn.example/movie.mp4');
      expect(source.headers, {'User-Agent': 'ua'});
      expect(gateway.lastResolveDrama?.id, 'pan115:file1');

      final pics = await client.playSource(
        const DramaSiteEpisode(videoId: 'img1', title: 'a.jpg', seriesId: 'pan115:img1'),
      );
      expect(pics.url, startsWith('pics://'));
    });

    test('rooted：categories 只回根文件夹一个分类（id 带 folder: 前缀、名为文件夹名）', () async {
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: _FakeGateway(),
        rootFolderId: 'folderA',
        rootFolderName: '电影',
      );
      expect(client.isRooted, isTrue);
      final categories = await client.categories();
      expect(categories, hasLength(1));
      expect(categories.single.id, 'folder:folderA');
      expect(categories.single.name, '电影');
    });

    test('rooted：catalog 的 ''/all 归一到根文件夹，其余 categoryId 归一逻辑不变', () async {
      final gateway = _FakeGateway();
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: gateway,
        rootFolderId: 'folderA',
        rootFolderName: '电影',
      );
      await client.catalog('', 1);
      expect(gateway.lastCategory, 'folderA');
      await client.catalog('all', 1);
      expect(gateway.lastCategory, 'folderA');
      // 下钻到子文件夹照旧：folder: 前缀与裸 id 都归一成引擎 category。
      await client.catalog('folder:folderB', 1);
      expect(gateway.lastCategory, 'folderB');
      await client.catalog('folderB', 1);
      expect(gateway.lastCategory, 'folderB');
    });

    test('非 rooted：isRooted 为假、分类仍是根「网盘」（行为不变）', () async {
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: _FakeGateway(),
      );
      expect(client.isRooted, isFalse);
      final categories = await client.categories();
      expect(categories.single.id, 'all');
    });

    test('search：走引擎 query 通道并按同一映射出条目', () async {
      final gateway = _FakeGateway();
      final client = CloudDriveContentClient(
        providerId: 'pan115',
        gateway: gateway,
      );
      final items = await client.search('movie');
      expect(gateway.lastQuery, 'movie');
      expect(items.map((e) => e.id), contains('pan115:file1'));
      expect(await client.search('  '), isEmpty);
    });
  });

  group('网盘文件夹下钻判定（openDramaSiteItem 分支）', () {
    test('cloud 站 + folder: 条目走下钻；文件条目与非 cloud 站不走', () {
      expect(
        isCloudFolderDrillDown(
          'cloud:pan115',
          const DramaSiteItem(id: 'folder:folderA', title: '电影', cover: ''),
        ),
        isTrue,
      );
      expect(
        isCloudFolderDrillDown(
          'cloud:pan115',
          const DramaSiteItem(id: 'pan115:file1', title: 'movie.mp4', cover: ''),
        ),
        isFalse,
      );
      expect(
        isCloudFolderDrillDown(
          'some-site',
          const DramaSiteItem(id: 'folder:x', title: 't', cover: ''),
        ),
        isFalse,
      );
    });
  });

  group('网盘当站', () {
    Future<CloudCredentialStore> fakeStore() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      return CloudCredentialStore(prefs);
    }

    tearDown(() {
      SourceRegistry.instance.setCloudDriveEntries(const []);
    });

    test('refresh 按登录状态产出/清站点', () async {
      final store = await fakeStore();
      await CloudDriveStations.refresh(store);
      expect(SourceRegistry.instance.cloudDriveEntries, isEmpty);

      await store.save(
        'pan115',
        CloudCredentials(
          fields: const {'cookie': 'a=b'},
          savedAtMs: 1,
          label: '测试账号',
        ),
      );
      final entries = CloudDriveStations.entriesFor(store);
      expect(entries, hasLength(1));
      expect(entries.single.id, 'cloud:pan115');
      expect(entries.single.name, '115网盘');
      expect(entries.single.kind, SourceKind.cloudDrive);
      expect(entries.single.extra['contentType'], 'video');

      await CloudDriveStations.refresh(store);
      expect(
        SourceRegistry.instance.cloudDriveEntries.map((e) => e.id),
        ['cloud:pan115'],
      );
      // customById 也认内存网盘站（网格卡片种类/详情站名走这个口）。
      expect(
        SourceRegistry.instance.customById('cloud:pan115')?.name,
        '115网盘',
      );

      await store.clear('pan115');
      await CloudDriveStations.refresh(store);
      expect(SourceRegistry.instance.cloudDriveEntries, isEmpty);
    });

    test('unifiedVideoZoneSites 含 cloud 条目且不被短剧判据摘掉', () async {
      final store = await fakeStore();
      await store.save(
        'pan115',
        CloudCredentials(fields: const {'cookie': 'a=b'}, savedAtMs: 1),
      );
      final entries = CloudDriveStations.entriesFor(store);
      expect(isFilmVideoSite('cloud:pan115', '115网盘'), isTrue);
      expect(
        videoPagePlayableSites(entries).map((e) => e.id),
        contains('cloud:pan115'),
      );
      final unified = unifiedVideoZoneSites(entries);
      expect(unified.map((e) => e.id), contains('cloud:pan115'));
      expect(
        unified.singleWhere((e) => e.id == 'cloud:pan115').name,
        '115网盘',
      );
      // 汇合点：登记表为空时并入内存网盘站。
      await CloudDriveStations.refresh(store);
      expect(
        withCloudDriveSites(const []).map((e) => e.id),
        contains('cloud:pan115'),
      );
    });
  });

  group('首页网盘档', () {
    test('homeCategories 里「网盘」在「听书」后', () {
      final labels = [for (final c in homeCategories) c.label];
      expect(labels.indexOf('网盘'), labels.indexOf('听书') + 1);
    });

    test('identityOf 网盘特判：name 网盘、kind pan、无 tabType；未开特判的实例仍是视频', () {
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(usesLocalTabs: true, panTabEnabled: true),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      final panIndex = notifier.panTabIndex;
      expect(panIndex, homeCategories.length - 1);
      expect(
        notifier.identityOf(panIndex),
        (name: '网盘', kind: 'pan', tabType: null),
      );
      // 既有下标不移位：短剧仍是短剧。
      expect(notifier.identityOf(2).name, '短剧');

      final dramaLike = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(usesLocalTabs: true),
      );
      final container2 = ProviderContainer();
      addTearDown(container2.dispose);
      final notifier2 = container2.read(dramaLike.notifier);
      expect(notifier2.identityOf(panIndex).name, '视频');
    });

    test('load 网盘档不拉流、直接置空闲', () async {
      var loaderCalls = 0;
      final provider = NotifierProvider<HomeNotifier, HomeState>(
        () => HomeNotifier(
          usesLocalTabs: true,
          panTabEnabled: true,
          homepageLoader: ({int tabType = 0, int offset = 0, String? sessionId}) async {
            loaderCalls++;
            throw StateError('网盘档不该拉书城流');
          },
        ),
      );
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(provider.notifier);
      notifier.selectTab(notifier.panTabIndex);
      await notifier.load();
      final state = container.read(provider);
      expect(state.tabIndex, notifier.panTabIndex);
      expect(state.isLoading, isFalse);
      expect(state.items, isEmpty);
      expect(state.error, isNull);
      expect(state.hasMore, isFalse);
      expect(loaderCalls, 0);
    });

    testWidgets('HomeTabBar 渲染含「网盘」且排在「听书」后', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: CustomScrollView(
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: HomeTabBarDelegate(
                    selectedIndex: homeCategories.length - 1,
                    onSelect: (_) {},
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('网盘'), findsOneWidget);
      expect(find.text('听书'), findsOneWidget);
      final panDx = tester.getTopLeft(find.text('网盘')).dx;
      final audioDx = tester.getTopLeft(find.text('听书')).dx;
      expect(panDx, greaterThan(audioDx));
    });
  });

  group('登入中心网盘区', () {
    testWidgets('五家行渲染：未登录态显示名 + 未登录 + 登录钮', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = CloudCredentialStore(prefs);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudDriveAccountSection(store: store),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final name in ['115网盘', '夸克网盘', '阿里云盘', '百度网盘', '移动云盘']) {
        expect(find.text(name), findsOneWidget);
      }
      expect(find.text('未登录'), findsNWidgets(5));
      expect(find.widgetWithText(FilledButton, '登录'), findsNWidgets(5));
    });

    testWidgets('已登录行显示昵称与退出钮', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final store = CloudCredentialStore(prefs);
      await store.save(
        'quark',
        CloudCredentials(
          fields: const {'cookie': 'a=b'},
          savedAtMs: 1,
          label: '夸克昵称',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CloudDriveAccountSection(store: store),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('已登录 · 夸克昵称'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, '退出'), findsOneWidget);
      expect(find.text('未登录'), findsNWidgets(4));
    });
  });
}
