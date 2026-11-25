import 'dart:async';

import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/file_text_picker.dart';
import '../services/live_api.dart';
import '../services/live_catchup.dart';
import '../services/live_drm.dart';
import '../services/live_epg.dart';
import '../services/live_platform.dart';
import '../services/live_settings.dart';
import '../services/live_sleep_timer.dart';
import '../services/live_sources.dart';
import '../services/live_subscriptions.dart';
import '../services/live_store.dart';
import '../services/native_player.dart';
import '../services/whos_live_bridge.dart';
import '../source_picker_sheet.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'live_player_page.dart';
import 'live_status_panel.dart';
import 'mine_page.dart';

/// 直播页：对齐魔蚁定版 live_screen.dart 的结构与做法。
///
/// 布局：上半内嵌播放器（16:9 定比，叠顶栏频道名/分辨率/ⓘ）/
/// 下半面板：80 高瘦信息行（左预览槽 + 正在/即将两行 + 56 宽
/// 切源钮）+ 搜索行 + 分组/频道/线路三列同滚胶囊网格；点视频
/// 画面进全屏、双击重试。换源不走横向 chips，走信息行切源钮
/// 弹出的分组选择框（平台源 / 导入源）。
/// 内嵌播放与全屏播放各用一个 NativePlayer：进全屏前先暂停内嵌，
/// 回来再续播，避免两个播放器同时出声。
/// 切到底部别的 tab 时内嵌暂停（LazyIndexedStack 下本页常驻，
/// 靠 TickerMode 判断本 tab 是否可见），切回来再续播。
/// 收藏与睡眠定时是最小本地版：收藏走 SharedPreferences
///（live_store.dart），睡眠定时走纯 Dart 计时器
///（live_sleep_timer.dart），都不依赖账号。
class LivePage extends StatefulWidget {
  const LivePage({super.key});

  @override
  State<LivePage> createState() => _LivePageState();
}

/// 测试注入：非空时直播页用它代替真实的分类拉取（验首屏看门狗
/// 在慢源/挂死源下能结束加载并落报错态）。生产路径始终为 null。
@visibleForTesting
Future<List<LivePlatform>> Function(LiveSource source)?
livePlatformsFetcherForTest;

/// 测试注入：非空时 _loadChannels 用它代替真实的频道拉取
/// （验三列网格 / 线路切换 / DRM 明示卡这类要指定频道数据的
/// 场景）。生产路径始终为 null。
@visibleForTesting
Future<List<LiveChannel>> Function(LiveSource source, LivePlatform platform)?
liveChannelsFetcherForTest;

/// 测试注入：非空时节目单用它代替 LiveEpgService.loadForSource
/// （验信息行 now/next 显示真节目名的场景）。生产路径始终为 null。
@visibleForTesting
Future<LiveEpgGuide> Function(LiveSource source)? liveEpgLoaderForTest;

/// 测试注入：非空时左下「+」的本地文件导入用它代替真实的
/// file_selector 选文件（返回值同 pickTextFile：文件名 + 全文，
/// null 表示用户取消）。生产路径始终为 null。
@visibleForTesting
Future<({String name, String content})?> Function()?
liveLocalFilePickerForTest;

class _LivePageState extends State<LivePage> {
  static const _favouritesId = '__favourites';
  static const _pageSize = 60;

  /// 首屏链看门狗：分类 / 频道 / 列表任一步超过 20 秒没有返回，
  /// 就结束加载落报错态（可重试），绝不永久「载入中…」
  /// （2026-11-26 诊断第 3 条；单步更细的超时在桥层/平台层：
  /// 平台通道 ≤5 秒、单次库查询 ≤10 秒）。
  static const _loadWatchdogLimit = Duration(seconds: 20);

  /// 起播停滞看门狗：buffering / 等首帧超过 15 秒给报错卡（带
  /// 重试），不无限转圈（诊断第 8 条）。
  static const _bufferStallLimit = Duration(seconds: 15);

  /// 多槽订阅（导入源）：订阅机件是唯一数据源，这里只镜像一份
  /// 给选源弹窗与 _loadSource 查表；增删都走 LiveSubscriptionStore。
  List<LiveSubscription> _subscriptions = const [];
  String? _importError;

  LiveSubscription? _subscriptionFor(String sourceId) {
    for (final sub in _subscriptions) {
      if (sub.sourceId == sourceId) return sub;
    }
    return null;
  }

  void _subscriptionsChanged() {
    if (!mounted) return;
    setState(
      () => _subscriptions = LiveSubscriptionStore.instance.items,
    );
  }

  /// 默认源加载是否已经启动过（进页立即启动，不再等导入频道
  /// 前置门；境界刚解锁时由监听补启动一次）。
  bool _sourceLoadStarted = false;

  /// 起播停滞看门狗计时器（arm/disarm 见 _subscribe / _loadInline）。
  Timer? _bufferWatchdog;

  final _searchController = TextEditingController();
  String _query = '';

  final _store = LiveStore.instance;
  final _sleepTimer = LiveSleepTimer.instance;

  // 默认源不是内置片库：片库是 44.9 万行大库，进页压它当首源时
  // 开库 + 全表聚合的串行链任何一步慢/挂就永久「载入中…」。
  // 默认落登记表第一个真正的直播源（秀果），片库留给用户点选。
  LiveSource _source = LiveSources.defaultSource;
  List<LivePlatform> _platforms = const [];
  String _group = '';
  List<LiveChannel> _allChannels = const [];
  List<LiveChannel> _channels = const [];
  int _page = 1;
  bool _hasMore = false;

  /// 内置片库（whoslib://）远端是否还有页：本地表滑到底且它为真时
  /// 续载下一页；m3u 源整表一次拉回，它恒为 false。
  bool _whosLibHasMore = false;

  /// 内置片库正在续载远端下一页：滚动通知连续触发时只发一次，
  /// 否则同一页会重复追加（_whosLibNextPage 在回来前不变）。
  bool _whosLibAppending = false;

  /// 内置片库下一页页码：已加载条数 / 每页 120 条 + 1。
  int get _whosLibNextPage => _allChannels.length ~/ whosLibPageSize + 1;
  ({String group, List<LiveChannel> channels})? _lastGood;
  int _index = 0;
  bool _loading = false;
  String? _error;
  int _loadGeneration = 0;

  NativePlayer? _player;
  List<StreamSubscription<dynamic>> _subs = [];
  int _playerGeneration = 0;
  bool _initVideo = true;
  String? _playerError;

  /// 当前报错是不是 DRM 明示（带加密、当前播放器无法解密）：
  /// 是的话报错卡不给「重新连接」这类无效入口。
  bool _playerErrorDrm = false;

  /// 内嵌播放当前线路（频道 urls 的下标）：三列网格的线路列
  /// 点按切换；切频道时回 0。进全屏时经 startRoute 传给全屏页。
  int _route = 0;

  /// 当前源的节目单（源带 epg 地址时才拉）：拉到后信息行改用
  /// 真节目名（now/next），拉不到/对不上台回落频道标题口径。
  LiveEpgGuide? _epgGuide;
  String _epgUrl = '';

  /// 节目单到手后每分钟重算一次正在播/即将播（节目到点切换时
  /// 信息行要跟上）；没有节目单时不启这个计时器。
  Timer? _epgTick;

  bool _tabVisible = true;
  bool _fullscreenOpened = false;

  LiveChannel? get _channel => _channels.isEmpty
      ? null
      : _channels[_index.clamp(0, _channels.length - 1)];

  /// 搜索过滤后的频道：只在已加载的列表里筛（分页源只筛已加载的页）。
  List<LiveChannel> get _visibleChannels {
    if (_query.isEmpty) return _channels;
    final q = _query.toLowerCase();
    return _channels
        .where(
          (c) =>
              c.title.toLowerCase().contains(q) ||
              c.group.toLowerCase().contains(q),
        )
        .toList();
  }

  List<({String id, String name, int count})> get _entries => [
    (id: _favouritesId, name: '收藏', count: _store.favourites.length),
    for (final platform in _platforms)
      (id: platform.id, name: platform.name, count: platform.count),
  ];

  String _numberFor(int index, LiveChannel channel) => channel.number.isEmpty
      ? (index + 1).toString().padLeft(3, '0')
      : channel.number;

  void _pauseInline() {
    unawaited(_player?.pause());
  }

  // 睡眠定时到期时调的暂停动作：存成字段，dispose 时按身份比对清掉。
  late final VoidCallback _pauseInlineHandler = _pauseInline;

  @override
  void initState() {
    super.initState();
    CultivationService.instance.snapshotNotifier.addListener(
      _onCultivationChanged,
    );
    _store.addListener(_storeChanged);
    _sleepTimer.addListener(_sleepChanged);
    _sleepTimer.pausePlayback = _pauseInlineHandler;
    LiveSubscriptionStore.instance.addListener(_subscriptionsChanged);
    unawaited(_store.load());
    // 睡眠定时默认时长：设置里配了默认档，进直播自动起算
    //（计时器已在跑时不重置，见 live_settings.dart）。
    unawaited(applyLiveSleepDefault());
    // 前置门并行化：默认源立即启动，订阅列表就绪后只合并进源
    // 列表（_pickSource 读 _subscriptions），不再挡首屏。订阅
    // 机件首次 load 时顺带把老单槽导入迁成一条订阅。
    if (CultivationService.instance.snapshot.unlockedVideo) {
      _sourceLoadStarted = true;
      unawaited(_loadSource(_source));
    }
    LiveSubscriptionStore.instance.load().then((subs) {
      if (!mounted) return;
      setState(() => _subscriptions = subs);
      // 当前正在看的源是订阅源且当时还没数据时，顺手补拉一次。
      if (_subscriptionFor(_source.id) != null &&
          _channels.isEmpty &&
          !_loading) {
        unawaited(_loadSource(_source));
      }
    });
  }

  void _onCultivationChanged() {
    if (!mounted) return;
    setState(() {});
    // 刚解锁、且默认源还没启动过时补启动一次（进页时境界服务
    // 可能还没初始化完，快照当时还是上锁态）。
    if (CultivationService.instance.snapshot.unlockedVideo &&
        !_sourceLoadStarted) {
      _sourceLoadStarted = true;
      unawaited(_loadSource(_source));
    }
  }

  void _storeChanged() {
    if (!mounted) return;
    // 只同步列表内容，不重建播放，否则刚点开的频道会被重置回第一条。
    setState(() {
      if (_group == _favouritesId) _channels = _store.favourites;
    });
  }

  void _sleepChanged() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible = TickerMode.valuesOf(context).enabled;
    if (visible == _tabVisible) return;
    _tabVisible = visible;
    if (!visible) {
      unawaited(_player?.pause());
    } else {
      _sleepTimer.pausePlayback = _pauseInlineHandler;
      if (!_fullscreenOpened) {
        _resumeInline();
      }
    }
  }

  void _resumeInline() {
    if (_channels.isEmpty) return;
    if (_sleepTimer.sleepPaused) return;
    if (_player == null || _playerError != null) {
      unawaited(_loadInline(_index));
    } else {
      unawaited(_player?.play());
    }
  }

  @override
  void dispose() {
    CultivationService.instance.snapshotNotifier.removeListener(
      _onCultivationChanged,
    );
    _store.removeListener(_storeChanged);
    LiveSubscriptionStore.instance.removeListener(_subscriptionsChanged);
    _sleepTimer.removeListener(_sleepChanged);
    if (_sleepTimer.pausePlayback == _pauseInlineHandler) {
      _sleepTimer.pausePlayback = null;
    }
    _epgTick?.cancel();
    _teardownPlayer();
    _searchController.dispose();
    super.dispose();
  }

  /// 导入失败文案：剥掉异常类型前缀，只留机件里写好的人话
  ///（订阅拉取失败 / 内容为空 / 未解析到任何频道等，各说各的）。
  static String _importErrorText(Object error) {
    var text = error.toString();
    for (final prefix in const ['StateError: ', 'FormatException: ', 'Bad state: ']) {
      if (text.startsWith(prefix)) text = text.substring(prefix.length);
    }
    return text;
  }

  /// 左下悬浮「+」的导入菜单：两路——导入本地文件 / 添加远程
  /// 链接。两路都走订阅机件落盘，成功自动切到新源。
  Future<void> _showImportMenu() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: moyiSheetFill,
      showDragHandle: true,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              key: const ValueKey('live-import-local'),
              leading: const Icon(
                Icons.folder_open_rounded,
                color: moyiMutedOnDark,
              ),
              title: const Text(
                '导入本地文件',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                '选择 m3u / m3u8 / txt 播放列表文件',
                style: TextStyle(color: moyiMutedOnDark),
              ),
              onTap: () => Navigator.pop(sheetContext, 'local'),
            ),
            ListTile(
              key: const ValueKey('live-import-remote'),
              leading: const Icon(Icons.link_rounded, color: moyiMutedOnDark),
              title: const Text(
                '添加远程链接',
                style: TextStyle(color: Colors.white),
              ),
              subtitle: const Text(
                '粘贴 m3u / txt 订阅地址，刷新时自动重拉',
                style: TextStyle(color: moyiMutedOnDark),
              ),
              onTap: () => Navigator.pop(sheetContext, 'remote'),
            ),
          ],
        ),
      ),
    );
    if (!mounted || choice == null) return;
    if (choice == 'local') {
      await _importLocalFile();
    } else {
      await _importDialog();
    }
  }

  /// 导入本地文件：走修仙版已有的 file_selector（pickTextFile，
  /// 不引新依赖）选 m3u/m3u8/txt，读全文 → 订阅机件按扩展名/
  /// 内容选解析器验真落盘 → 自动切到该源。选文件/读文件失败、
  /// 内容不是播放列表、解析 0 频道各有各自的报错，不吞错。
  Future<void> _importLocalFile() async {
    ({String name, String content})? picked;
    try {
      final picker = liveLocalFilePickerForTest;
      picked = picker != null
          ? await picker()
          : await pickTextFile(
              label: '直播列表',
              extensions: ['m3u', 'm3u8', 'txt'],
            );
    } catch (error) {
      if (mounted) {
        setState(() => _importError = '文件读不到：${_importErrorText(error)}');
      }
      return;
    }
    if (picked == null || !mounted) return;
    try {
      final name = picked.name.replaceAll(
        RegExp(r'\.(m3u8?|txt)$', caseSensitive: false),
        '',
      );
      final sub = await LiveSubscriptionStore.instance.addLocal(
        name: name,
        content: picked.content,
        fileName: picked.name,
      );
      if (!mounted) return;
      setState(() => _importError = null);
      unawaited(_loadSource(liveSourceForSubscription(sub)));
    } catch (error) {
      if (mounted) setState(() => _importError = _importErrorText(error));
    }
  }

  /// 添加远程链接：粘贴地址 → 订阅机件拉取/解析/落盘 →
  /// 自动切到该源。失败原因（地址无效/拉不到/解析 0 频道）
  /// 由机件按格式给出，显示在面板的导入报错行。
  Future<void> _importDialog() async {
    final controller = TextEditingController();
    final url = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: moyiSheetFill,
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
        contentTextStyle: const TextStyle(color: moyiBodyOnDark),
        title: const Text('添加远程链接'),
        content: TextField(
          controller: controller,
          style: const TextStyle(color: moyiBodyOnDark),
          decoration: const InputDecoration(
            labelText: '订阅地址',
            labelStyle: TextStyle(color: moyiMutedOnDark),
            hintText: 'https://…/playlist.m3u',
            hintStyle: TextStyle(color: moyiMutedOnDark),
            enabledBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: moyiDarkCardBorder),
            ),
            focusedBorder: UnderlineInputBorder(
              borderSide: BorderSide(color: moyiPurple),
            ),
          ),
        ),
        actions: [
          TextButton(
            style: TextButton.styleFrom(foregroundColor: moyiCyan),
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: moyiCyan),
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: const Text('导入'),
          ),
        ],
      ),
    );
    if (url == null || url.trim().isEmpty || !mounted) return;
    try {
      final sub = await LiveSubscriptionStore.instance.addRemote(url);
      if (!mounted) return;
      setState(() => _importError = null);
      unawaited(_loadSource(liveSourceForSubscription(sub)));
    } catch (error) {
      if (mounted) setState(() => _importError = _importErrorText(error));
    }
  }

  /// 首屏链看门狗 + 耗时日志：[step] 超过 20 秒没返回就抛
  /// TimeoutException，上层 catch 落报错态并结束 _loading——链上
  /// 任何一步慢/挂都不许让页面永久停在「载入中…」。每步耗时打
  /// 日志（源名 / 步骤 / 毫秒），手机侧再卡能直接从日志定步。
  Future<T> _guardedStep<T>(String step, Future<T> future) async {
    final watch = Stopwatch()..start();
    try {
      final result = await future.timeout(
        _loadWatchdogLimit,
        onTimeout: () => throw TimeoutException(
          '直播加载超时：$step 超过 20 秒没有返回，请点刷新重试',
        ),
      );
      debugPrint(
        '[直播耗时] 源=${_source.name} 步骤=$step '
        '耗时=${watch.elapsedMilliseconds}ms',
      );
      return result;
    } catch (error) {
      debugPrint(
        '[直播耗时] 源=${_source.name} 步骤=$step '
        '失败(${watch.elapsedMilliseconds}ms)：$error',
      );
      rethrow;
    }
  }

  /// 当前源带节目单地址时把节目单跟上：切源走 _loadSource 时
  /// 在这里按地址比对——地址没变不重拉，变了就换一份；源没给
  /// 地址就清掉旧节目单，信息行回落频道标题口径。异步加载，
  /// 不挡播放与列表，到手后 setState 补显示。
  void _syncEpgForSource(LiveSource source) {
    final loader = liveEpgLoaderForTest;
    final url = source.epg.trim();
    if (loader == null && url == _epgUrl) return;
    _epgUrl = url;
    _epgGuide = null;
    _epgTick?.cancel();
    _epgTick = null;
    if (loader == null && url.isEmpty) return;
    unawaited(_loadEpgGuide(source, loader));
  }

  Future<void> _loadEpgGuide(
    LiveSource source,
    Future<LiveEpgGuide> Function(LiveSource source)? loader,
  ) async {
    try {
      final guide = loader != null
          ? await loader(source)
          : await LiveEpgService.instance.loadForSource(source);
      if (!mounted || _source.id != source.id) return;
      setState(() => _epgGuide = guide);
      _epgTick ??= Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted && _epgGuide != null) setState(() {});
      });
    } catch (_) {
      // 节目单是增强项：拉不到就不显示节目名，不打扰用户。
    }
  }

  Future<void> _loadSource(LiveSource source) async {
    _syncEpgForSource(source);
    final generation = ++_loadGeneration;
    _teardownPlayer();
    setState(() {
      _source = source;
      _loading = true;
      _error = null;
      _platforms = const [];
      _group = '';
      _allChannels = const [];
      _channels = const [];
      _page = 1;
      _hasMore = false;
      _whosLibHasMore = false;
      _whosLibAppending = false;
      _lastGood = null;
      _index = 0;
      _route = 0;
      _playerError = null;
      _playerErrorDrm = false;
      _initVideo = true;
      _query = '';
      _searchController.clear();
    });
    try {
      // 内置片库（whoslib://）不走 m3u 整表：库里 34 万部一次拉不完，
      // 按魔蚁走分类 + 按页取频道（见 whos_live_bridge.dart）。
      if (source.endpoint.startsWith(whosLibScheme)) {
        await _loadPlatforms(generation: generation);
        return;
      }
      if (source.protocol == LiveProtocol.list) {
        final sub = _subscriptionFor(source.id);
        final channels = sub != null
            ? LiveSubscriptionStore.instance.channelsFor(sub)
            : await _guardedStep(
                '拉频道表',
                LiveSources.loadBuiltinListChannels(source),
              );
        if (!mounted || generation != _loadGeneration) return;
        setState(() {
          _allChannels = channels;
          _page = 1;
          _loading = false;
        });
        _applyPage();
        if (channels.isNotEmpty) unawaited(_loadInline(0));
        return;
      }
      await _loadPlatforms(generation: generation);
    } catch (error) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  Future<void> _loadPlatforms({int? generation, String keepGroup = ''}) async {
    final source = _source;
    final gen = generation ?? ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = null;
      _platforms = const [];
      _channels = const [];
      _allChannels = const [];
      _group = '';
      _lastGood = null;
      _page = 1;
      _hasMore = false;
      _whosLibHasMore = false;
      _whosLibAppending = false;
    });
    try {
      // 内置片库走本地库出分类（首屏只有最新 / 排行榜，厂牌聚合
      // 异步补，见下方）；api 源（bilibili）走 B 站公开接口取分区，
      // pingtai 源走平台接口。每步过首屏看门狗（20 秒）。
      final testFetcher = livePlatformsFetcherForTest;
      final platforms = testFetcher != null
          ? await _guardedStep('拉分类', testFetcher(source))
          : source.endpoint.startsWith(whosLibScheme)
          ? await _guardedStep('拉分类', fetchWhosLibPlatforms())
          : source.protocol == LiveProtocol.api
          ? await _guardedStep('拉分类', fetchApiPlatforms(source))
          : await _guardedStep('拉分类', fetchPingtaiPlatforms(source));
      if (!mounted || gen != _loadGeneration) return;
      if (platforms.isEmpty) throw StateError('该直播源没有可用分类');
      setState(() {
        _platforms = platforms;
        _loading = false;
      });
      final target =
          keepGroup.isNotEmpty &&
              platforms.any((platform) => platform.id == keepGroup)
          ? keepGroup
          : platforms.first.id;
      await _loadChannels(target);
      // 首屏（第一页频道）已经出来，厂牌聚合这时才异步补进分组栏：
      // 它是对 44.9 万行做 GROUP BY 的重活，绝不再挡首屏。
      if (source.endpoint.startsWith(whosLibScheme)) {
        unawaited(_appendWhosBrandPlatforms(gen));
      }
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      setState(() {
        _loading = false;
        _error = error.toString();
      });
    }
  }

  /// 内置片库厂牌分类异步补：首屏出来之后才算聚合，算完合并进
  /// 分组栏（已有的不重复加）；失败静默（只有最新 / 排行榜也够用，
  /// 用户点品牌筛选走的也是同一条聚合，见 bridge）。
  Future<void> _appendWhosBrandPlatforms(int gen) async {
    final brands = await fetchWhosLibBrandPlatforms();
    if (!mounted || gen != _loadGeneration || brands.isEmpty) return;
    setState(() {
      final existing = _platforms.map((platform) => platform.id).toSet();
      _platforms = [
        ..._platforms,
        for (final brand in brands)
          if (!existing.contains(brand.id)) brand,
      ];
    });
  }

  /// 列表型源（m3u）取数接口没有分页参数：整表一次拉回，
  /// 按 60 条一页展示追加，与火蚁TV 的滚动续载行为一致。
  /// 内置片库是远端分页：本地表滑到底且远端还有页时也要续载。
  void _applyPage() {
    setState(() {
      _channels = _allChannels.take(_page * _pageSize).toList();
      _hasMore = _source.paginated &&
          (_allChannels.length > _page * _pageSize || _whosLibHasMore);
    });
  }

  /// 滑到底续载：本地表还有未显示的只翻本地页；内置片库本地表滑到底
  /// 且远端还有页时调 _loadChannels append 续一页。
  void _loadMore() {
    if (_page * _pageSize < _allChannels.length) {
      _page++;
      _applyPage();
      return;
    }
    if (_source.endpoint.startsWith(whosLibScheme) &&
        _whosLibHasMore &&
        !_loading &&
        !_whosLibAppending) {
      unawaited(_loadChannels(_group, append: true));
    }
  }

  Future<void> _loadChannels(String id, {bool append = false}) async {
    final source = _source;
    if (id == _favouritesId) {
      _loadGeneration++;
      final channels = _store.favourites;
      _lastGood = (group: id, channels: channels);
      // 切到收藏只换列表，不打断正在播放的频道。
      setState(() {
        _group = id;
        _allChannels = channels;
        _channels = channels;
        _error = null;
        _loading = false;
        _page = 1;
        _hasMore = false;
        _whosLibHasMore = false;
        _whosLibAppending = false;
      });
      return;
    }
    final platform = _platforms.where((entry) => entry.id == id).firstOrNull;
    if (platform == null) return;
    if (append && !_hasMore) return;
    if (!append && id == _group) return;
    if (!append) _lastGood = (group: _group, channels: _channels);
    final gen = _loadGeneration;
    setState(() {
      _group = id;
      _error = null;
      if (!append) {
        _loading = true;
        _hasMore = false;
        _page = 1;
        _route = 0;
        _channels = const [];
        _allChannels = const [];
        _query = '';
        _searchController.clear();
      } else if (source.endpoint.startsWith(whosLibScheme)) {
        _whosLibAppending = true;
      }
    });
    try {
      // api 源（bilibili）按分区调房间列表接口，只拉第 1 页（每页 30 条）；
      // pingtai 源走平台接口；内置片库按页读库（120 条/页，append 续载）。
      final isWhosLib = source.endpoint.startsWith(whosLibScheme);
      final channelsFetcher = liveChannelsFetcherForTest;
      final channels = channelsFetcher != null
          ? await _guardedStep('拉频道', channelsFetcher(source, platform))
          : isWhosLib
          ? await _guardedStep(
              '拉频道',
              fetchWhosLibChannels(
                platform,
                page: append ? _whosLibNextPage : 1,
              ),
            )
          : source.protocol == LiveProtocol.api
          ? await _guardedStep('拉频道', fetchApiChannels(source, platform))
          : await _guardedStep(
              '拉频道',
              fetchPingtaiChannels(source, platform),
            );
      if (!mounted || gen != _loadGeneration) return;
      if (!append) _lastGood = (group: id, channels: channels);
      setState(() {
        if (append && isWhosLib) {
          // 续载：新一页追加到已加载表尾，不重置 _page（滚动位置不变）。
          _allChannels = [..._allChannels, ...channels];
        } else {
          _allChannels = channels;
          _page = 1;
        }
        if (isWhosLib) _whosLibHasMore = channels.length >= whosLibPageSize;
        _whosLibAppending = false;
        _loading = false;
      });
      _applyPage();
      if (!append && channels.isNotEmpty) unawaited(_loadInline(0));
    } catch (error) {
      if (!mounted || gen != _loadGeneration) return;
      final restore = _lastGood;
      final fallback =
          !append && restore != null && restore.channels.isNotEmpty;
      setState(() {
        _loading = false;
        _whosLibAppending = false;
        if (fallback) {
          _group = restore.group;
          _allChannels = restore.channels;
          _channels = restore.channels;
          _error = null;
        } else {
          _error = error.toString();
        }
      });
      if (fallback && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${platform.name} 暂时不可用，已保留原分类')),
        );
      }
    }
  }

  /// 手动刷新：强制重新抓取直播分类与当前分类的频道列表。
  /// 加载中也允许刷新（自救入口）：_loadPlatforms 会递增代次，
  /// 在途的旧加载回来时按代次作废，不会覆盖刷新结果。以前刷新
  /// 按钮在 _loading 时被禁用、这里也直接 return，链上一旦挂死
  /// 用户连自救都点不了，只能退页重进（诊断第 1.4 条）。
  Future<void> _refreshLive() async {
    _sourceLoadStarted = true;
    // 订阅源刷新（魔蚁口径）：远程源重拉地址、重解析、更新
    // 快照后再载入；本地快照源不重读文件，直接从已存快照
    // 重新载入。远程重拉失败按原因报错，旧频道保留不清空。
    final sub = _subscriptionFor(_source.id);
    if (sub != null) {
      var current = sub;
      if (sub.isUrl) {
        try {
          current = await LiveSubscriptionStore.instance.refreshRemote(sub);
        } catch (error) {
          if (mounted) {
            setState(() => _importError = _importErrorText(error));
          }
          return;
        }
      }
      await _loadSource(liveSourceForSubscription(current));
      return;
    }
    if (_group == _favouritesId) {
      setState(() => _channels = _store.favourites);
      return;
    }
    await _loadPlatforms(keepGroup: _group);
  }

  /// 切换直播源：调公共站点切换弹窗（与魔蚁 live_screen._pickSource
  /// 同款：sectionName 传“直播”，不传 enableZoneFlip、不分区翻页）。
  /// 修仙版直播页没有 greenMode 概念：全量内置 + 导入，成人源不靠
  /// 弹窗过滤，整页由元婴境界门禁守着。
  /// 注意：旧弹窗里「导入的频道」那行的副标题（已存频道数 / m3u 地址）
  /// 在公共弹窗里没有位置，随这次对齐去掉，与魔蚁版一致。
  Future<void> _pickSource() async {
    final sources = [
      ...LiveSources.builtin,
      for (final sub in _subscriptions) liveSourceForSubscription(sub),
    ];
    final grouped = _subscriptions.isNotEmpty;
    final picked = await showSitePickerDialog(
      context,
      sectionName: '直播',
      currentId: _source.id,
      onDeleteSite: _deleteImportedSource,
      groups: [
        SourcePickerGroup(
          title: grouped ? '平台源' : '',
          entries: [
            for (final source in LiveSources.builtin)
              SourcePickerEntry(
                id: source.id,
                name: source.name,
                // 内置 28 源不可删：只有订阅源给删除能力。
                deletable: false,
              ),
          ],
        ),
        if (grouped)
          SourcePickerGroup(
            title: '导入源',
            entries: [
              for (final sub in _subscriptions)
                SourcePickerEntry(
                  id: sub.sourceId,
                  name: sub.name,
                  deletable: true,
                ),
            ],
          ),
      ],
    );
    if (picked == null || !mounted) return;
    final source = sources.where((item) => item.id == picked).firstOrNull;
    if (source != null && source.id != _source.id) {
      unawaited(_loadSource(source));
    }
  }

  /// 选源弹窗长按删除（走弹窗自带的 onDeleteSite）：只有订阅源
  /// 会走到这里（内置条目 deletable=false，弹窗不给删除入口）。
  /// 删的是当前正在看的源时，先回落到默认源再删记录。
  Future<bool> _deleteImportedSource(SourcePickerEntry entry) async {
    final sub = _subscriptionFor(entry.id);
    if (sub == null) return false;
    if (_source.id == entry.id) {
      unawaited(_loadSource(LiveSources.defaultSource));
    }
    await LiveSubscriptionStore.instance.remove(sub.id);
    return true;
  }

  void _selectChannel(int index) {
    if (index < 0 || index >= _channels.length) return;
    unawaited(_loadInline(index));
  }

  /// 三列网格线路列点按：当前频道切到该线路重播（与全屏页
  /// _loadChannel(keepRoute) 同一条取址逻辑：urls[route] 起播）。
  void _selectRoute(int route) {
    if (route == _route) return;
    unawaited(_loadInline(_index, route: route));
  }

  static String _epgClock(DateTime time) =>
      '${time.hour.toString().padLeft(2, '0')}:'
      '${time.minute.toString().padLeft(2, '0')}';

  /// 频道信息弹层：只列源数据真实带有的字段（频道名/号、源、
  /// 分组、线路、分辨率——分辨率只在播放器真拿到宽高时才写）；
  /// 节目单对得上台时多一条「节目单」入口。顶栏 ⓘ 与信息行
  /// 点按（无节目单时）都开这一层。
  Future<void> _showChannelInfo() async {
    final channel = _channel;
    if (channel == null) return;
    final player = _player;
    final hasSize =
        player != null && player.videoWidth > 0 && player.videoHeight > 0;
    final guide = _epgGuide;
    final hasProgrammes =
        guide != null && guide.programmesFor(channel).isNotEmpty;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      backgroundColor: moyiSheetFill,
      builder: (sheetContext) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(
                  Icons.live_tv_rounded,
                  color: moyiMutedOnDark,
                ),
                title: Text(
                  channel.title,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  [
                    if (channel.number.isNotEmpty) '频道号 ${channel.number}',
                    '直播源 ${_source.name}',
                    if (channel.group.isNotEmpty) '分组 ${channel.group}',
                  ].join(' · '),
                  style: const TextStyle(color: moyiMutedOnDark),
                ),
              ),
              ListTile(
                leading: const Icon(
                  Icons.route_rounded,
                  color: moyiMutedOnDark,
                ),
                title: Text(
                  '线路 ${_route + 1}/${channel.urls.length}',
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: channel.subtitle.isNotEmpty
                    ? Text(
                        channel.subtitle,
                        style: const TextStyle(color: moyiMutedOnDark),
                      )
                    : null,
              ),
              if (hasSize)
                ListTile(
                  leading: const Icon(
                    Icons.high_quality_rounded,
                    color: moyiMutedOnDark,
                  ),
                  title: Text(
                    '分辨率 ${player.videoWidth} x ${player.videoHeight}',
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              if (hasProgrammes)
                ListTile(
                  key: const ValueKey('live-info-epg'),
                  leading: const Icon(
                    Icons.event_note_rounded,
                    color: moyiMutedOnDark,
                  ),
                  title: const Text(
                    '节目单',
                    style: TextStyle(color: Colors.white),
                  ),
                  subtitle: channel.catchup != null
                      ? const Text(
                          '过去的节目可点回看',
                          style: TextStyle(color: moyiMutedOnDark),
                        )
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop('epg'),
                ),
            ],
          ),
        ),
      ),
    );
    if (action == 'epg' && mounted) {
      await _showProgrammeSheet(channel);
    }
  }

  /// 节目单弹层：当前频道今天的节目（按时间正序，打开时滚到
  /// 正在播的那条）。正在播的标「正在播」；已播完的在频道带
  /// 回看模板、且模板真能生成地址时可点回看，生成不出地址的
  /// 置灰不可点；没回看模板时只看单子，不给假入口。
  Future<void> _showProgrammeSheet(LiveChannel channel) async {
    final guide = _epgGuide;
    if (guide == null) return;
    final all = guide.programmesFor(channel);
    if (all.isEmpty) return;
    final now = DateTime.now();
    // 只列今天这一天的节目：结束晚于今天零点、开始早于明天
    // 零点（跨零点的节目按这个口径不会被漏掉）；节目单文件
    // 常含多天，全列出来太长。一条都不剩时回落全表。
    final dayStart = DateTime(now.year, now.month, now.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final todays = [
      for (final item in all)
        if (item.end.isAfter(dayStart) && item.start.isBefore(dayEnd)) item,
    ];
    final list = todays.isEmpty ? all : todays;
    final currentIndex = list.indexWhere((item) => item.contains(now));
    final scroll = ScrollController(
      initialScrollOffset: currentIndex > 0 ? currentIndex * 56.0 : 0,
    );
    final picked = await showModalBottomSheet<LiveEpgProgramme>(
      context: context,
      showDragHandle: true,
      backgroundColor: moyiSheetFill,
      builder: (sheetContext) => SafeArea(
        child: SizedBox(
          height: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
                child: Text(
                  '${channel.title} · 节目单',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('live-epg-list'),
                  controller: scroll,
                  itemCount: list.length,
                  itemBuilder: (itemContext, index) {
                    final item = list[index];
                    final playing = item.contains(now);
                    final past = item.end.isBefore(now) || item.end == now;
                    // 能不能点回看当场按模板验：生成不出地址的
                    // 节目置灰不可点，不给假入口。
                    final catchupUrl = past && channel.catchup != null
                        ? formatLiveCatchupUrl(
                            catchup: channel.catchup!,
                            liveUrl: channel.url,
                            start: item.start,
                            end: item.end,
                          )
                        : null;
                    return ListTile(
                      key: ValueKey('live-epg-item-$index'),
                      enabled: catchupUrl != null,
                      leading: Text(
                        _epgClock(item.start),
                        style: const TextStyle(color: moyiBodyOnDark),
                      ),
                      title: Text(
                        item.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: catchupUrl != null || playing
                              ? Colors.white
                              : moyiMutedOnDark,
                        ),
                      ),
                      subtitle: Text(
                        '${_epgClock(item.start)}–${_epgClock(item.end)}',
                        style: const TextStyle(color: moyiMutedOnDark),
                      ),
                      trailing: playing
                          ? const Chip(label: Text('正在播'))
                          : catchupUrl != null
                          ? const Icon(
                              Icons.replay_rounded,
                              color: moyiCyan,
                            )
                          : null,
                      onTap: catchupUrl != null
                          ? () => Navigator.of(sheetContext).pop(item)
                          : null,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
    scroll.dispose();
    if (picked == null || !mounted) return;
    _playCatchup(channel, picked);
  }

  /// 回看起播：按频道回看模板生成该节目的回看地址，直接以该
  /// 地址起播当前频道（列表不动，用户再切分组/切源重拉列表后
  /// 该频道自然恢复直播地址）。生成不出地址时如实提示。
  void _playCatchup(LiveChannel channel, LiveEpgProgramme programme) {
    final catchup = channel.catchup;
    if (catchup == null) return;
    final url = formatLiveCatchupUrl(
      catchup: catchup,
      liveUrl: channel.url,
      start: programme.start,
      end: programme.end,
    );
    if (url == null) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('这个节目生成不了回看地址')));
      return;
    }
    final index = _channels.indexWhere((entry) => entry.key == channel.key);
    if (index < 0) return;
    unawaited(_loadInline(index, overrideUrl: url));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text('回看：${programme.title}')));
  }

  Future<void> _openFullscreen() async {
    if (_channels.isEmpty || !mounted) return;
    await _player?.pause();
    if (!mounted) return;
    _fullscreenOpened = true;
    await Navigator.push<void>(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LivePlayerPage(
          channels: _channels,
          startIndex: _index,
          source: _source,
          startRoute: _route,
        ),
      ),
    );
    _fullscreenOpened = false;
    if (!mounted) return;
    _sleepTimer.pausePlayback = _pauseInlineHandler;
    // 全屏页内可能换了频道，内嵌播回自己当前频道。
    if (_tabVisible) _resumeInline();
  }

  /// 起播停滞看门狗：从起播/进入 buffering 开始计时，15 秒内没
  /// 等到首帧或缓冲结束就落报错卡（带「重新连接」重试）。上游流
  /// 假死（不断开、不报错、不出首帧）时播放区以前会无限转圈。
  void _armBufferWatchdog(int generation, NativePlayer player) {
    _bufferWatchdog?.cancel();
    _bufferWatchdog = Timer(_bufferStallLimit, () {
      if (!_isCurrentPlayer(generation, player)) return;
      if (mounted) {
        setState(() {
          // DRM 频道本就不起播、不会走到这里；万一判定口径变化
          // 走到了，报错卡同样不给「重新连接」这类无效入口。
          if (_channel != null && liveDrmForChannel(_channel!) != null) {
            _playerError = _drmBlockedMessage;
            _playerErrorDrm = true;
          } else {
            _playerError = '直播信号停滞：超过 15 秒没有新画面，请重新连接或换一个频道';
            _playerErrorDrm = false;
          }
          _initVideo = false;
        });
      }
    });
  }

  /// DRM 明示文案：带加密的频道当前播放器解不了密，如实说明，
  /// 不装作信号问题、不给无效的重试入口。
  static const _drmBlockedMessage = '该频道带 DRM 加密，当前播放器无法解密，暂时播不了';

  void _disarmBufferWatchdog() {
    _bufferWatchdog?.cancel();
    _bufferWatchdog = null;
  }

  /// 内嵌起播：[route] 指定线路（缺省时同频道沿用当前线路、
  /// 换频道回线路 0）；[overrideUrl] 是回看起播用的现成地址，
  /// 给了就直接播它、不再按线路取址。
  Future<void> _loadInline(
    int index, {
    int? route,
    String? overrideUrl,
  }) async {
    if (_channels.isEmpty) return;
    _sleepTimer.clearSleepPaused();
    final generation = ++_playerGeneration;
    final target = index.clamp(0, _channels.length - 1);
    final channel = _channels[target];
    final effectiveRoute = overrideUrl != null
        ? _route
        : (route ?? (target == _index ? _route : 0));
    _teardownPlayer();
    setState(() {
      _index = target;
      _route = effectiveRoute.clamp(0, channel.urls.length - 1);
      _initVideo = true;
      _playerError = null;
      _playerErrorDrm = false;
    });
    // DRM 明示：判定带 DRM 的频道不起播、不重连，直接落明示
    // 报错卡（报错卡按 _playerErrorDrm 不给「重新连接」入口）。
    // 魔蚁主树此处分流 EXO pane（5203915，TvboxPlayerPlugin 的
    // drm 参数 + dash 模块），本应用无对应通路（NativePlayer 插件
    // 无 MediaDrm、gradle 无 dash 模块），能归一化也统一出明示卡。
    if (liveDrmForChannel(channel) != null) {
      setState(() {
        _playerError = _drmBlockedMessage;
        _playerErrorDrm = true;
        _initVideo = false;
      });
      return;
    }
    final player = NativePlayer();
    _player = player;
    _subscribe(player, generation);
    _armBufferWatchdog(generation, player);
    try {
      // api 源（bilibili）列表里只有房间号没有直链，播之前按 token
      // 现取播放地址；解析出的直链写回列表，收藏时才能存下可播地址。
      // 平台房间地址是明文 http FLV：直接给 ExoPlayer 会被 App 的明文
      // 策略拦掉（列表能拉、一点播就失败），先走本地中继转成 127.0.0.1。
      // 多线路频道按当前线路取址（与全屏页 _loadChannel 同口径）。
      var playUrl =
          overrideUrl ??
          channel.urls[_route.clamp(0, channel.urls.length - 1)];
      if (overrideUrl == null &&
          _source.protocol == LiveProtocol.api &&
          playUrl.isEmpty) {
        final resolved = await resolveLiveApiPlayUrl(_source, channel);
        if (resolved.isEmpty) throw StateError('该频道暂时无法播放');
        playUrl = resolved;
        final fixed = channel.copyWith(url: playUrl, urls: [playUrl]);
        // 收藏视图的列表是 LiveStore.favourites 的不可改包装，写回会抛
        // UnsupportedError：只在能写的列表上换，写不进也不影响本次播放。
        for (final list in [_channels, _allChannels]) {
          try {
            final at = list.indexWhere((entry) => entry.key == channel.key);
            if (at >= 0) list[at] = fixed;
          } catch (_) {}
        }
      }
      playUrl = await playableLiveUrl(playUrl);
      await player.create(playUrl, '');
      if (!_isCurrentPlayer(generation, player)) {
        await player.dispose();
        return;
      }
      if (player.lastError case final Object error) throw error;
      await player.play();
      if (!_isCurrentPlayer(generation, player)) return;
      if (mounted) setState(() {});
    } catch (error) {
      if (!_isCurrentPlayer(generation, player)) return;
      _disarmBufferWatchdog();
      if (mounted) {
        setState(() {
          _playerError = error.toString();
          _initVideo = false;
        });
      }
    }
  }

  bool _isCurrentPlayer(int generation, NativePlayer player) =>
      mounted && generation == _playerGeneration && identical(_player, player);

  void _subscribe(NativePlayer player, int generation) {
    _subs = [
      player.textureIdStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) setState(() {});
      }),
      player.firstFrameStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) {
          _disarmBufferWatchdog();
          setState(() => _initVideo = false);
        }
      }),
      player.bufferingStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) {
          // 缓冲开始重新计时，缓冲结束撤掉看门狗。
          if (player.buffering) {
            _armBufferWatchdog(generation, player);
          } else {
            _disarmBufferWatchdog();
          }
          setState(() {});
        }
      }),
      player.videoSizeStream.listen((_) {
        if (_isCurrentPlayer(generation, player) && mounted) setState(() {});
      }),
      player.errorStream.listen((error) {
        if (_isCurrentPlayer(generation, player) && mounted) {
          _disarmBufferWatchdog();
          setState(() {
            _playerError = error.toString();
            _initVideo = false;
          });
        }
      }),
    ];
  }

  void _teardownPlayer() {
    _disarmBufferWatchdog();
    for (final sub in _subs) {
      unawaited(sub.cancel());
    }
    _subs = [];
    final player = _player;
    _player = null;
    if (player != null) unawaited(player.dispose());
  }

  Future<void> _showSleepTimer() async {
    await showLiveSleepTimerDialog(context);
    if (mounted) setState(() {});
  }

  /// 未到元婴期时的上锁页：不露源名与频道，只写还差多少修为。
  /// 直播里的成人源与影视区一样按修为解锁：修为不到不显示，
  /// 修为到了才列出来。
  Widget _lockedBody(BuildContext context) {
    final snapshot = CultivationService.instance.snapshot;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: moyiMutedOnDark),
            const SizedBox(height: 16),
            const Text(
              '直播源需要元婴期',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '还差 ${snapshot.xpToVideoZone} 修为（约 ${snapshot.episodesToVideoZone} 集短剧）解锁，修为到了自动显示直播源。',
              textAlign: TextAlign.center,
              style: const TextStyle(color: moyiBodyOnDark),
            ),
            const SizedBox(height: 16),
            MoyiGradientButton(
              label: '去我的页看进度',
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(builder: (_) => const MinePage()),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // 直播页整页由 unlockedVideo（元婴期 3000 修为）门禁守着：修为不到
    // 不显示，修为到了才列出来。22 个 m3u 源、3 个平台源与内置片库全是
    // 成人，bilibili 是唯一非成人源，目前也随整页上锁（拆分门禁待定，
    // 见报告）。
    final unlocked = CultivationService.instance.snapshot.unlockedVideo;
    return Scaffold(
      backgroundColor: Colors.transparent,
      // 目标版式没有顶栏：播放器直接贴顶（16:9），切换源在信息行
      // 右端的 56 钮；导入走左下角固定悬浮「+」（独立层，列表
      // 滚动不动它，魔蚁定版同款位置）。
      body: MoyiPageBackground(
        child: SafeArea(
          top: true,
          bottom: false,
          child: !unlocked
              ? _lockedBody(context)
              : Stack(
                  children: [
                    Column(
                      children: [
                        AspectRatio(aspectRatio: 16 / 9, child: _videoArea()),
                        Expanded(child: _panel()),
                      ],
                    ),
                    Positioned(
                      left: 12,
                      bottom: 12,
                      child: Material(
                        key: const ValueKey('live-import-add'),
                        color: moyiPurple,
                        shape: const CircleBorder(),
                        elevation: 4,
                        child: InkWell(
                          customBorder: const CircleBorder(),
                          onTap: () => unawaited(_showImportMenu()),
                          child: const SizedBox(
                            width: 48,
                            height: 48,
                            child: Icon(Icons.add, color: Colors.white),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
    );
  }

  Widget _videoArea() {
    final channel = _channel;
    final player = _player;
    final texture = player?.textureId;
    final waiting =
        _initVideo ||
        texture == null ||
        player == null ||
        !player.firstFrameRendered ||
        player.videoWidth <= 0 ||
        player.videoHeight <= 0;
    return ColoredBox(
      key: const ValueKey('live-stage'),
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Stack(
            fit: StackFit.expand,
            children: [
              // 画面按原始比例显示：StackFit.expand 会把 Texture 强行拉满
              // 整个区域（竖版流塞进横向盒子就被压扁，issue #11 同款）。
              // 用 Center + AspectRatio（已计入旋转修正的显示宽高比）
              // 包住，画面保持比例、多余处留黑边，不拉伸、不压扁。
              if (texture != null)
                Center(
                  child: AspectRatio(
                    aspectRatio: player!.displayAspectRatio,
                    child: RotatedBox(
                      quarterTurns: player.videoRotationCorrection ~/ 90,
                      child: Texture(
                        key: const ValueKey('live-inline-texture'),
                        textureId: texture,
                      ),
                    ),
                  ),
                ),
              if (_playerError == null &&
                  !_loading &&
                  channel == null &&
                  _channels.isEmpty)
                const Center(
                  child: Text(
                    '选择频道开始播放',
                    style: TextStyle(color: Color(0xFF8B8F99), fontSize: 12),
                  ),
                ),
            ],
          ),
          // 点画面进全屏、双击重试：这层手势盖在视频上、控制条之下，
          // 所以暂停/全屏/收藏按钮先响应，不会被抢点击；报错时不盖，
          // 报错卡片自己的重试按钮先响应。
          if (_playerError == null)
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _openFullscreen,
                onDoubleTap: () {
                  if (_channels.isNotEmpty) {
                    unawaited(_loadInline(_index));
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
          if (_playerError != null)
            Positioned.fill(
              child: ColoredBox(
                color: Colors.black.withValues(alpha: .82),
                child: Theme(
                  data: ThemeData.dark(),
                  // DRM 明示卡不给「重新连接」：重连也解不了密，
                  // 给了只会让用户白点（标题与图标也换成加密口径）。
                  child: _playerErrorDrm
                      ? LiveStatusPanel(
                          title: '该频道带 DRM 加密',
                          message: _playerError!,
                          icon: Icons.lock_rounded,
                        )
                      : LiveStatusPanel(
                          title: '直播暂时中断',
                          message: _playerError!,
                          icon: Icons.wifi_off_rounded,
                          action: '重新连接',
                          onRetry: () {
                            if (_channels.isNotEmpty) {
                              unawaited(_loadInline(_index));
                            }
                          },
                        ),
                ),
              ),
            )
          else if (_loading || waiting || player.buffering)
            const Center(
              child: SizedBox(
                width: 34,
                height: 34,
                child: CircularProgressIndicator(strokeWidth: 3),
              ),
            ),
          if (channel != null && _playerError == null)
            Align(
              alignment: Alignment.bottomCenter,
              child: _nowPlaying(channel),
            ),
          if (channel != null && _playerError == null)
            Positioned(left: 0, right: 0, top: 0, child: _videoHeader(channel)),
        ],
      ),
    );
  }

  /// 播放区顶栏：频道名 + 分辨率 + ⓘ 信息钮。分辨率只在播放器
  /// 真拿到宽高时才拼（拿不到不拼）；帧率不拼——NativePlayer
  /// 不暴露帧率，编数不许。ⓘ 开频道信息弹层（节目单入口在内）。
  Widget _videoHeader(LiveChannel channel) {
    final player = _player;
    final hasSize =
        player != null && player.videoWidth > 0 && player.videoHeight > 0;
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 4, 14),
        child: Row(
          children: [
            Expanded(
              child: Text(
                channel.title,
                key: const ValueKey('live-video-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (hasSize) ...[
              const SizedBox(width: 8),
              Text(
                '[ ${player.videoWidth} x ${player.videoHeight} ]',
                key: const ValueKey('live-video-resolution'),
                style: const TextStyle(
                  color: Color(0xB3FFFFFF),
                  fontSize: 11,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
            IconButton(
              key: const ValueKey('live-video-info'),
              visualDensity: VisualDensity.compact,
              tooltip: '频道信息',
              onPressed: _showChannelInfo,
              icon: const Icon(
                Icons.info_outline_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _nowPlaying(LiveChannel channel) {
    final favourite = _store.isFavourite(channel.key);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xB3000000), Color(0x00000000)],
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 16, 4, 4),
        child: Row(
          children: [
            Text(
              _numberFor(_index, channel),
              style: const TextStyle(
                color: Color(0xB3FFFFFF),
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                channel.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (channel.subtitle.isNotEmpty) ...[
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  channel.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xB3FFFFFF),
                    fontSize: 12,
                  ),
                ),
              ),
            ] else
              const Spacer(),
            if (channel.urls.length > 1)
              Text(
                '线路 ${channel.urls.length}',
                style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 12),
              ),
            IconButton(
              key: const ValueKey('live-sleep-timer'),
              visualDensity: VisualDensity.compact,
              tooltip: _sleepTimer.active
                  ? '睡眠定时 · ${_sleepTimer.label}'
                  : '睡眠定时',
              onPressed: _showSleepTimer,
              icon: const Icon(
                Icons.bedtime_outlined,
                size: 20,
                color: Colors.white,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: '全屏与旋转',
              onPressed: _openFullscreen,
              icon: const Icon(
                Icons.screen_rotation_alt_rounded,
                size: 20,
                color: Colors.white,
              ),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: favourite ? '取消收藏' : '收藏频道',
              onPressed: () => unawaited(_store.toggleFavourite(channel)),
              icon: Icon(
                favourite ? Icons.star_rounded : Icons.star_border_rounded,
                size: 20,
                color: favourite ? moyiGold : Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _panel() => Column(
    children: [
      _infoCards(),
      if (_importError != null)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            _importError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
      Expanded(child: _lists()),
    ],
  );

  /// 播放区下方瘦信息行（魔蚁定版版式）：整行钉死 80 高，左槽
  /// 实时预览帧（频道号只作小角标叠在帧一角）、中卡「正在播放 /
  /// 即将播放」两行小字、右端 56 宽切源小方钮（点开现有选源
  /// 弹窗，弹窗样子用法不动）。
  /// 节目名口径：当前源带节目单（epg）且对得上台时，两行优先
  /// 显示真节目名（nowNext 按 tvg-id 优先、显示名兜底）；没有
  /// 节目单、对不上台或还没加载完时回落——正在=当前频道标题
  /// （subtitle 是另一份真实信息且与标题不同才拼在后面）、
  /// 即将=列表里下一条频道标题，没有下一条才「暂无节目信息」。
  /// 绝不编节目名。点中卡：对得上节目单开节目单弹层，否则开
  /// 频道信息弹层。
  Widget _infoCards() {
    final channel = _channel;
    final number = channel == null ? '--' : _numberFor(_index, channel);
    final guide = _epgGuide;
    final hit = guide != null && channel != null
        ? guide.nowNext(channel, DateTime.now())
        : null;
    final matched =
        guide != null &&
        channel != null &&
        guide.programmesFor(channel).isNotEmpty;
    final now = hit?.now != null
        ? hit!.now!.title
        : channel == null
        ? '暂无节目信息'
        : channel.subtitle.isNotEmpty && channel.subtitle != channel.title
        ? '${channel.title} · ${channel.subtitle}'
        : channel.title;
    final next = matched
        ? hit?.next?.title ?? '暂无节目信息'
        : channel != null && _index + 1 < _channels.length
        ? _channels[_index + 1].title
        : '暂无节目信息';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: SizedBox(
        height: 80,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(flex: 20, child: _infoPreviewSlot(channel, number)),
            const SizedBox(width: 8),
            Expanded(
              flex: 75,
              child: Material(
                key: const ValueKey('live-epg-card'),
                color: moyiDarkCardFill,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: moyiDarkCardBorder),
                ),
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: channel == null
                      ? null
                      : () => matched
                            ? _showProgrammeSheet(channel)
                            : _showChannelInfo(),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '正在播放：$now',
                          key: const ValueKey('live-epg-now'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                        const Divider(
                          color: moyiDarkCardBorder,
                          height: 8,
                        ),
                        Text(
                          '即将播放：$next',
                          key: const ValueKey('live-epg-next'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // 切源钮：随瘦行做成 56 宽的小方钮（与行同高 80）。
            SizedBox(
              width: 56,
              child: Material(
                key: const ValueKey('live-source-card'),
                color: moyiDarkCardFill,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: const BorderSide(color: moyiDarkCardBorder),
                ),
                child: IconButton(
                  key: const ValueKey('live-source-button'),
                  tooltip: '切换直播源',
                  onPressed: _pickSource,
                  icon: const Icon(Icons.tv_rounded, color: Colors.white),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 信息行左槽：实时预览帧。与上方播放区同一个 NativePlayer 的
  /// 纹理再挂一个 Texture 组件共用同一 textureId（Flutter 层已
  /// 验可共存，见 test/live_dual_texture_test.dart；真机双面出画
  /// 待手机验）。画面完整显示不裁剪（Center + AspectRatio 保
  /// 比例）。频道号不另占卡，只以左上角小角标叠在帧上。无纹理/
  /// 未起播/报错时落占位：黑底 + 「实时预览」+ 频道名。
  Widget _infoPreviewSlot(LiveChannel? channel, String number) {
    final player = _player;
    final texture = player?.textureId;
    final showFrame = texture != null && _playerError == null;
    return Container(
      key: const ValueKey('live-info-preview'),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (showFrame)
            Center(
              child: AspectRatio(
                aspectRatio: player!.displayAspectRatio,
                child: RotatedBox(
                  quarterTurns: player.videoRotationCorrection ~/ 90,
                  child: Texture(
                    key: const ValueKey('live-info-preview-texture'),
                    textureId: texture,
                  ),
                ),
              ),
            )
          else
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      '实时预览',
                      style: TextStyle(color: Color(0xFF8B8F99), fontSize: 10),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      channel?.title ?? '未选择频道',
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF8B8F99),
                        fontSize: 10,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          if (showFrame && player?.buffering == true)
            const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              ),
            ),
          if (channel != null)
            Positioned(
              left: 4,
              top: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: .55),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  number,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _lists() {
    // 搜索行与三列网格：搜索行整行在网格上方（魔蚁无搜索，属
    // 修仙版增量，保留）；源加载失败时搜索行也要能刷新/导入，
    // 报错只显示在网格区。
    return Column(
      children: [
        _searchRow(),
        Expanded(child: _channelPane()),
      ],
    );
  }

  /// 搜索行：搜当前已加载的频道（标题/分组）；这里只剩刷新
  /// 小钮（切源在信息行右端的 56 钮，导入在左下悬浮「+」）。
  Widget _searchRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(6, 2, 12, 2),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _query = value),
              style: const TextStyle(color: moyiBodyOnDark),
              decoration: InputDecoration(
                hintText: '搜索频道',
                hintStyle: const TextStyle(color: moyiMutedOnDark),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  size: 18,
                  color: moyiMutedOnDark,
                ),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        icon: const Icon(
                          Icons.clear_rounded,
                          size: 18,
                          color: moyiMutedOnDark,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                isDense: true,
                filled: true,
                fillColor: moyiDarkCardFill,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: moyiDarkCardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: moyiDarkCardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: moyiPurple),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
              ),
            ),
          ),
          IconButton(
            key: const ValueKey('live-refresh-button'),
            tooltip: '刷新直播',
            visualDensity: VisualDensity.compact,
            // 加载中不禁用：看门狗之外再给一条用户自救路。
            onPressed: _refreshLive,
            icon: const Icon(Icons.refresh_rounded, color: Colors.white),
          ),
          // 搜索行原先的导入小钮已退役：导入统一走左下悬浮「+」。
        ],
      ),
    );
  }

  Widget _channelPane() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    final error = _error;
    if (error != null && _channels.isEmpty) {
      // 源级失败（分类都没拉到）与分类级失败共用这里：源级失败重试
      // 整个源，分类级失败重试当前分类。
      final sourceFailed = _group != _favouritesId && _platforms.isEmpty;
      return LiveStatusPanel(
        title: sourceFailed ? '${_source.name} 直播源暂时不可用' : '这个分类暂时不可用',
        message: error,
        icon: Icons.wifi_off_rounded,
        onRetry: () =>
            sourceFailed ? unawaited(_loadPlatforms()) : _loadChannels(_group),
      );
    }
    if (_channels.isEmpty) {
      return LiveStatusPanel(
        title: _group == _favouritesId ? '还没有收藏频道' : '没有可用频道',
        message: _group == _favouritesId ? '播放时点星标即可加入收藏。' : '可以切换其他分类或直播源。',
        icon: Icons.live_tv_rounded,
      );
    }
    if (_visibleChannels.isEmpty) {
      return const LiveStatusPanel(
        title: '没有找到频道',
        message: '换个关键词试试。',
        icon: Icons.search_off_rounded,
      );
    }
    return _grid();
  }

  /// 三列胶囊（魔蚁定版版式）：分组 / 频道 / 线路三列同排、同一
  /// 个 ListView 一起滚、占满全宽（flex 25 / 44 / 26，按修仙版
  /// 页面宽度适配），格高 48、圆角 10；行数取三列最长，短的列
  /// 空着。选中格底走修仙版主题令牌渐变、字变金（moyiGold，
  /// 不写死魔蚁黄字色值）。频道列随同一个 ListView 上下滑动；
  /// 滑到底续载（本地翻页 + 片库远端续页，触发点随列表迁移到
  /// 这里）。线路列是当前频道的线路：只有直连型源（pingtai /
  /// list）可点，点按即切播当前频道该线路；api 型源只展示。
  Widget _grid() {
    final entries = _entries;
    final visible = _visibleChannels;
    final current = _channel;
    final lineCount = current?.urls.length ?? 0;
    final multiRoute =
        _source.protocol == LiveProtocol.pingtai ||
        _source.protocol == LiveProtocol.list;
    var rows = entries.length;
    if (visible.length > rows) rows = visible.length;
    if (lineCount > rows) rows = lineCount;
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification.metrics.extentAfter < 600 &&
            _hasMore &&
            _group != _favouritesId) {
          _loadMore();
        }
        return false;
      },
      child: ListView.builder(
        key: const ValueKey('live-channel-list'),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        itemCount: rows,
        itemBuilder: (context, index) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                Expanded(flex: 25, child: _groupCell(entries, index)),
                const SizedBox(width: 6),
                Expanded(
                  flex: 44,
                  child: _channelCell(visible, current, index),
                ),
                const SizedBox(width: 6),
                Expanded(
                  flex: 26,
                  child: _lineCell(index, lineCount, multiRoute),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _gridCell({required bool selected, required Widget child}) =>
      Container(
        height: 48,
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 4),
        decoration: BoxDecoration(
          gradient: selected ? moyiSelectedGradient : null,
          color: selected ? null : moyiDarkCardFill,
          border: selected
              ? null
              : Border.all(color: moyiDarkCardBorder),
          borderRadius: BorderRadius.circular(10),
        ),
        child: child,
      );

  TextStyle _gridCellText(bool selected) => TextStyle(
    fontSize: 13,
    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
    color: selected ? moyiGold : moyiBodyOnDark,
  );

  Widget _groupCell(
    List<({String id, String name, int count})> entries,
    int index,
  ) {
    if (index >= entries.length) return const SizedBox(height: 48);
    final entry = entries[index];
    final selected = entry.id == _group;
    final label = entry.id == _favouritesId && entry.count > 0
        ? '${entry.name}（${entry.count}）'
        : entry.name;
    return InkWell(
      key: ValueKey('live-group-${entry.id}'),
      onTap: () => unawaited(_loadChannels(entry.id)),
      child: _gridCell(
        selected: selected,
        child: Text(
          label,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: _gridCellText(selected),
        ),
      ),
    );
  }

  Widget _channelCell(
    List<LiveChannel> visible,
    LiveChannel? current,
    int index,
  ) {
    if (index >= visible.length) return const SizedBox(height: 48);
    final channel = visible[index];
    final selected = identical(channel, current);
    return InkWell(
      key: ValueKey('live-channel-$index'),
      onTap: () {
        final original = _channels.indexOf(channel);
        if (original >= 0) _selectChannel(original);
      },
      // 频道格只剩频道名一个 Text：源名不重复显示（源名只在切换
      // 弹窗与报错标题里出现；2026-11-24 用户令）。
      child: _gridCell(
        selected: selected,
        child: Text(
          channel.title,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: _gridCellText(selected),
        ),
      ),
    );
  }

  /// 线路格：与分组/频道同款胶囊。api 型源的线路走接口解析、
  /// 切线重播没有意义，只展示不挂点按（key 也不挂，魔蚁同口径）。
  Widget _lineCell(int index, int lineCount, bool multiRoute) {
    if (index >= lineCount) return const SizedBox(height: 48);
    final selected = multiRoute && index == _route;
    final cell = _gridCell(
      selected: selected,
      child: Text(
        '线路${index + 1}',
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: _gridCellText(selected),
      ),
    );
    if (!multiRoute) return cell;
    return InkWell(
      key: ValueKey('live-line-$index'),
      onTap: () => _selectRoute(index),
      child: cell,
    );
  }
}
