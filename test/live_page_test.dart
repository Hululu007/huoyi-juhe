import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/live_page.dart';
import 'package:fqapp/services/cultivation.dart';
import 'package:fqapp/services/live_sources.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 直播页的数据走修仙境界：未到元婴期（3000 修为）时只显示上锁提示，
/// 不露源名与频道；到了元婴期正常显示四个内置源（按火蚁TV：源名在
/// 当前卡「切换直播源」框里，不再是横向源 chips）。

/// 站点库批（2026-11-27）适配（组装 20261127+3 补）：直播 26 源
/// （3 平台＋23 清单）已改由站点库供数（LiveSources.sqlSources），
/// 未导入时 builtin 只剩原生 2 源。本文件验的是「导入后」的完整
/// 源表行为，故在 setUp 注入与生产站点库等值的 26 源夹具（id/名/
/// 协议与生成器 ACCOUNT 对账一致，与 live_port_verify_test 同款），
/// tearDown 清空。断言一字未动。
void injectSqlLiveFixture() {
  LiveSources.sqlSources = <LiveSource>[
    const LiveSource(
      id: 'xiuguo',
      name: '秀果',
      description: '主播直播 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw', 'http://api.hclyz.com:81/mf'],
      adult: true,
    ),
    const LiveSource(
      id: 'maiyoux',
      name: '欲火聚合',
      description: '欲火移植 · 平台动态聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.maiyoux.com:81/mf', 'http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    const LiveSource(
      id: 'bnzb',
      name: '百年直播',
      description: '百年直播 · 多平台聚合 · 实时开播',
      protocol: LiveProtocol.pingtai,
      endpoints: ['http://api.vipmisss.com:81/xcdsw'],
      adult: true,
    ),
    for (final e in <String, String>{
      'user_m3u': '成人点播',
      'm3u_zhubo': '主播网红',
      'm3u_luanlun': '乱伦精品',
      'm3u_huayu': '华语精品',
      'm3u_guochan': '国产精品',
      'm3u_xuesheng': '学生合集',
      'm3u_tanhua': '探花约炮',
      'm3u_riben': '日本有码',
      'm3u_oumei': '欧美大屌',
      'm3u_heilian': '黑料吃瓜',
      'm3u_community10': '社区合集10',
      'm3u_community11': '社区合集11',
      'm3u_wuma': '無碼專區',
      'm3u_wanghong': '網紅頭條',
      'm3u_xingba': '杏吧原創',
      'm3u_chengtou': '成人頭條',
      'm3u_zhifu': '制服絲襪',
      'm3u_qunjiao': '群交淫亂',
      'm3u_mingxing': '明星換臉',
      'm3u_zipai': '自拍偷拍',
      'm3u_avxiongdi': 'AV兄弟无码',
      'm3u_guochanse': '国产色情',
      'm3u_riben2': '日本有码2',
    }.entries)
      LiveSource(
        id: e.key,
        name: e.value,
        description: '',
        protocol: LiveProtocol.list,
        endpoints: ['sql://${e.key}'],
        adult: true,
      ),
  ];
}

void main() {
  setUp(() async {
    injectSqlLiveFixture();
    SharedPreferences.setMockInitialValues({});
    await CultivationService.instance.resetForTest();
    await CultivationService.instance.ensureInitialized();
  });

  tearDown(() async {
    LiveSources.sqlSources = <LiveSource>[];
    await CultivationService.instance.resetForTest();
  });

  Future<void> pumpLive(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: LivePage()));
    // 上锁态不显示转圈动画；多推几帧让 loadImportedChannels 的
    // Future 完成并把 _loading 置 false，免得解锁后还停在转圈上。
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
  }

  testWidgets('未到元婴期：只显示上锁提示，不露源名与频道', (tester) async {
    await pumpLive(tester);

    expect(find.text('直播源需要元婴期'), findsOneWidget);
    expect(find.textContaining('还差 3000 修为'), findsOneWidget);
    expect(find.text('去我的页看进度'), findsOneWidget);
    expect(find.text('秀果'), findsNothing);
    expect(find.text('欲火聚合'), findsNothing);
    expect(find.text('百年直播'), findsNothing);
    expect(find.text('成人点播'), findsNothing);
    expect(find.text('内置直播源'), findsNothing);
    expect(find.text('导入的 m3u 频道'), findsNothing);
  });

  testWidgets('到了元婴期：正常显示四个内置源', (tester) async {
    // 先按上锁态把页搭起来（与旧口令版测试同一结构：先锁后解），
    // 再把修为快照换成 3000 修为（6000 秒小说 ×0.5/秒），让页面的
    // 修为监听自己重建出列表。修为累计本身由 cultivation_test 覆盖，
    // 这里只验页面对境界的反应；直接换快照可避开 testWidgets 里调
    // 异步服务方法会挂起的问题。
    await pumpLive(tester);
    expect(find.text('直播源需要元婴期'), findsOneWidget);

    CultivationService.instance.snapshotNotifier.value =
        const CultivationSnapshot(
      seconds: {CultivationCategory.novel: 6000.0},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();

    expect(find.text('直播源需要元婴期'), findsNothing);
    // 源 chips 已按火蚁TV去掉：源名只在「切换直播源」框与房间列表的
    // 平台列里，当前卡副标题只显示“分组 · 序号/总数”，不再带平台名。
    expect(find.text('内置直播源'), findsNothing);
    await tester.tap(find.byTooltip('切换直播源'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('切换直播源'), findsOneWidget);
    expect(find.text('秀果'), findsOneWidget);
    expect(find.text('欲火聚合'), findsOneWidget);
    expect(find.text('百年直播'), findsOneWidget);
    expect(find.text('成人点播'), findsOneWidget);
  });
}
