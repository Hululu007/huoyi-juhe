import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/whos_local_library.dart';
import 'package:fqapp/services/live_platform.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:fqapp/services/whos_live_bridge.dart';

/// 内置片库桥层测试：内存库（fromWorks）验分类、分页、频道映射，
/// 不碰本地数据库与文件。数据库模式（MYTV/db/女优库.db）只在真机
/// 上走，见 live_page 里的 widget 测试（注入同款内存库）。
void main() {
  late WhosLocalLibrary library;

  setUp(() {
    WhosLocalWork work(String code, String title, {String playUrl = ''}) {
      return WhosLocalWork(
        id: code.toLowerCase(),
        title: title,
        cover: 'https://example.test/$code.jpg',
        playUrl: playUrl.isEmpty
            ? 'https://example.test/$code.m3u8'
            : playUrl,
        code: code,
        brand: WhosLocalWork.brandOfCode(code),
      );
    }

    library = WhosLocalLibrary.fromWorks([
      work('SSIS-001', '标题一'),
      work('SSIS-002', '标题二'),
      work('SSIS-003', '标题三'),
      work('IPX-001', '标题四'),
      work('IPX-002', '标题五'),
      // 只有封面、没有播放地址：进库计数，但不出频道。
      const WhosLocalWork(
        id: 'no-url',
        title: '无地址',
        cover: 'https://example.test/no-url.jpg',
        code: 'NOURL-001',
        brand: 'nourl',
      ),
    ]);
  });

  tearDown(() {
    whosLibTestLibrary = null;
  });

  test('频道名：番号在前、标题在后，超长截断', () {
    expect(
      whosLibChannelName(
        const WhosLocalWork(id: 'a', title: '标题', code: 'SSIS-001'),
      ),
      'SSIS-001 标题',
    );
    expect(
      whosLibChannelName(const WhosLocalWork(id: 'a', title: '只有标题')),
      '只有标题',
    );
    final long = whosLibChannelName(
      WhosLocalWork(id: 'a', title: '标题' * 40, code: 'SSIS-001'),
    );
    expect(long.length, 64);
    expect(long.endsWith('…'), true);
  });

  test('分类：最新 / 排行榜 + 2 条以上的厂牌', () {
    final platforms = whosLibPlatforms(library);
    expect(
      platforms.map((platform) => platform.id),
      ['new', 'rank', 'brand:ssis', 'brand:ipx'],
    );
    expect(platforms.first.name, '最新作品 · 6');
    expect(platforms[2].name, 'SSIS · 3');
  });

  test('取一页频道：无地址的条目不出频道，番号进 number、封面进 cover', () {
    final channels = whosLibChannels(library, category: 'new');
    expect(channels.length, 5);
    expect(channels.first.title, 'SSIS-001 标题一');
    expect(channels.first.url, 'https://example.test/SSIS-001.m3u8');
    expect(channels.first.number, 'SSIS-001');
    expect(channels.first.cover, 'https://example.test/SSIS-001.jpg');
    expect(channels.first.group, 'SSIS');
    expect(channels.first.sourceId, whosLibSourceId);
    // 厂牌分类只出该厂牌的。
    final ssis = whosLibChannels(library, category: 'brand:ssis');
    expect(ssis.length, 3);
    expect(whosLibChannels(library, category: 'new', page: 2), isEmpty);
  });

  test('异步版与同步版同口径（数据库模式走异步查库）', () async {
    final asyncChannels = await whosLibChannelsAsync(
      library,
      category: 'new',
    );
    expect(asyncChannels.length, 5);
    final asyncPlatforms = await whosLibPlatformsAsync(library);
    expect(
      asyncPlatforms.map((platform) => platform.id),
      ['new', 'rank', 'brand:ssis', 'brand:ipx'],
    );
  });

  test('取数入口：注入内存库时出分类与频道，无库时报读不出来', () async {
    whosLibTestLibrary = library;
    final platforms = await fetchWhosLibPlatforms();
    expect(platforms.map((platform) => platform.id).first, 'new');
    final channels = await fetchWhosLibChannels(
      const LivePlatform(id: 'new', name: '最新作品'),
    );
    expect(channels.length, 5);

    whosLibTestLibrary = null;
    // 测试环境没有本地库与 JSON：ensureLoaded 失败，报读不出来、
    // 不抛未捕获的异常（直播页按源级失败显示重试面板）。
    await expectLater(
      fetchWhosLibPlatforms(),
      throwsA(isA<StateError>()),
    );
  });

  test('登记表：内置片库是第 1 项，走 whoslib://、成人、可分页', () {
    expect(LiveSources.builtin.first.id, whosLibSourceId);
    final source = LiveSources.byId(whosLibSourceId)!;
    expect(source.endpoint, 'whoslib://all');
    expect(source.protocol, LiveProtocol.list);
    expect(source.adult, true);
    expect(source.paginated, true);
    expect(LiveSources.builtin.length, 28);
  });
}
