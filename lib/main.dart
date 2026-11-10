import 'services/api_client.dart';
import 'services/audio_downloader.dart';
import 'widgets/desktop_app_frame.dart';
import 'services/native_player.dart';
import 'services/desktop_platform.dart';
import 'services/drama_site_content.dart';
import 'services/web_page_fetch.dart';
import 'services/platform_channel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'pages/home_page.dart';
import 'pages/game_page.dart';
import 'pages/audio_page.dart';
import 'pages/cached_books_page.dart';
import 'pages/cultivation_create_page.dart';
import 'pages/drama_page.dart';
import 'pages/library_page.dart';
import 'pages/live_page.dart';
import 'pages/mine_page.dart';
import 'pages/video_page.dart';
import 'services/app_log.dart';
import 'services/app_theme.dart';
import 'services/audio_download_store.dart';
import 'services/audio_floating_routes.dart';
import 'services/drama_cache_preferences.dart';
import 'services/audio_preferences.dart';
import 'services/player_preferences.dart';
import 'services/player_layout_preferences.dart';
import 'services/backend_service.dart';
import 'services/digg_store.dart';
import 'services/drama_channel_preferences.dart';
import 'services/drama_download_store.dart';
import 'services/drama_downloader.dart';
import 'services/fair_memory.dart';
import 'services/connectivity_status.dart';
import 'services/home_feed_cache.dart';
import 'services/library_store.dart';
import 'services/cultivation.dart';
import 'services/game_service.dart';
import 'services/rank_cache.dart';
import 'services/player_style_config.dart';
import 'services/source_registry.dart';
import 'services/jar_bridge.dart';
import 'services/zakatv_builtin.dart';
import 'services/short_series_font_scale.dart';
import 'services/playlet_share.dart';
import 'services/poster_cache.dart';
import 'services/shelf_store.dart';
import 'services/swipe_guide_store.dart';
import 'services/local_media_proxy.dart';
import 'services/local_proxy_preferences.dart';
import 'services/local_proxy_route.dart';
import 'services/system_proxy.dart';
import 'widgets/lazy_indexed_stack.dart';
import 'widgets/cultivation_level_up_dialog.dart';
import 'widgets/home/home_design.dart';

Future<void> main() async {
  // 绑定初始化与 runApp 必须处在同一个 Zone：此前 `ensureInitialized` 在
  // Zone 外、`runApp` 在 `runZonedGuarded` 里，Flutter 每次冷启动都会断言
  // 「Zone mismatch」并把它当成框架异常抛出来（真机 app.log 每次启动一条
  // `[E] framework: Zone mismatch`，2026-10-25），把真正的异常淹没在启动
  // 噪声里。因此整条启动流程收进同一个受保护的 Zone。
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    // 装配失败不许挡住界面：记一条错误后照常 runApp，各页面自行退化。
    try {
      await _prepareRuntime();
    } catch (error, stack) {
      AppLog.e('main', '启动装配失败，继续挂载界面', error: error, stack: stack);
    }
    runApp(const ProviderScope(child: FqApp()));
  }, (error, stack) => AppLog.e('zone', '未捕获异步异常', error: error, stack: stack));
}

/// `runApp` 之前的运行时装配：桌面窗口回调、应用内日志、分享与 Rust 日志的桥。
/// 这些都不决定界面能不能起来，所以失败只记日志（见 [main]）。
Future<void> _prepareRuntime() async {
  if (isWindowsDesktop) await DesktopPlatform.instance.initialize();
  // 应用内日志：接管 debugPrint 与 FlutterError.onError，未处理异步异常由
  // [main] 的 runZonedGuarded 捕获；文件持久化异步开启，失败只退回内存模式。
  AppLog.instance.install();
  unawaited(AppLog.instance.startPersistence());
  // 短剧分享的「系统分享」走 Android 的 Intent.ACTION_SEND
  //（官方同一条路径）。桥不可用时 PlayletShare 自动降级为复制链接，
  // 不会把失败说成成功。
  // 插件回 false 表示没能调起选择器（没有可分享的应用），必须原样返回：
  // 「调不起来」与「已分享」是两件事。
  SharePlusLite.handler = ({required title, required text}) async {
    final launched = await const AppMethodChannel(
      'fqapp/share',
    ).invokeMethod<bool>('shareText', {'title': title, 'text': text});
    return launched ?? false;
  };
  // Rust 核心日志的读取入口：日志页「Rust」视图读 runtime_dir/rust.log。
  // 核心只在 Android 落盘（桌面/测试构建不装 logger），读不到时页面给空态。
  RustLogSource.reader = BackendService.instance.readRustLog;
  if (isWindowsDesktop) {
    DesktopPlatform.instance.beforeClose = () async {
      DramaDownloader.instance.pauseAll();
      AudioDownloader.instance.pauseAll();
      await FairMemoryService.instance.flushForExit();
      try {
        await NativePlayer.pauseOthers();
      } catch (error, stack) {
        // 退出路径继续往下走，但失败要留痕：否则「关闭后还有声音」无从查起。
        AppLog.w('exit', '退出前暂停播放器失败', error: error, stack: stack);
      }
      try {
        await BackendService.instance.stop();
      } catch (error, stack) {
        AppLog.w('exit', '退出前停止后端失败', error: error, stack: stack);
      }
      await Hive.close();
    };
  }
}

Future<void> _initializeLocalData() async {
  await Hive.initFlutter();
  // 以下初始化互相独立（各开各的 box / 各读各的配置），串行等只会把
  // 磁盘 I/O 叠加到冷启动里；并行发起，失败语义与串行时一致：必需项
  // （书架/历史）失败仍使启动失败，可选项各自吞错退化。
  Future<void> optional(Future<void> Function() run) async {
    try {
      await run();
    } catch (error, stack) {
      // 可选项失败时启动照常继续，但必须留下可检索的记录，否则一个永远
      // 打不开的可选 box 会以「某功能默默不生效」的形式表现出来。
      AppLog.w('startup', '可选本地数据初始化失败，已跳过', error: error, stack: stack);
    }
  }

  await Future.wait<void>([
    LibraryStore.instance.init(),
    // The 加入书架 collection is optional data: a failure here must not block
    // startup, which is why it shares the retryable bootstrap with the history.
    ShelfStore.instance.init(),
    // 短剧 feed 的 点赞 也是可选本地数据，与书架同一处理：开箱失败不能让
    // 启动失败，否则一个纯装饰性的集合会拖住短剧页之外的所有功能。
    optional(() async {
      await DiggStore.instance.init();
      // DiggStore 自己把「不可用」当成「没有点赞」处理（见 _openBox）。
    }),
    // 「上滑查看更多视频」的一次性标记同样是可选数据：读不到就当没弹过，
    // 弹一次的语义退化成「本次启动弹一次」也不能拖住启动。
    optional(() async {
      await SwipeGuideStore.instance.init();
      // SwipeGuideStore 自己把「不可用」当成「未显示」处理。
    }),
    // 首页 feed 的冷启动缓存也是可选数据：打不开就当没有缓存，
    // 首页退化为先加载再显示，其余行为不变。
    optional(() async {
      HomeFeedCache.hiveReady = true;
      await HomeFeedCache.instance.warmUp();
      // HomeFeedCache 自己把「不可用」当成「没有缓存」处理。
    }),
    // 榜单缓存同理：开箱失败只是退化为每次现拉。
    optional(() async {
      RankCache.hiveReady = true;
      await RankCache.instance.warmUp();
      // RankCache 自己把「不可用」当成「没有缓存」处理。
    }),
    // 官方播放页开关（PlayerBottomStyleConfig / 清屏反转 / 横屏锁）随同一份
    // 运行时配置读取；读不到就用默认值，不能拖住启动。
    PlayerStyleConfig.load(),
    // 官方播放页字号档（jk3/b 的 SP）同理：读失败回标准档，不拖启动。
    ShortSeriesFontScale.load(),
    // 解码器偏好必须先进内存：`NativePlayer.create` 在起播路径上直接读它，
    // 不能在那里再 await 读盘（见 DecoderPreferenceCache 的说明）。
    optional(DecoderPreferenceCache.load),
    // 离线缓存的记录箱启动即打开：播放器的离线命中只在 box 就绪时才查
    // （避免运行中途首次 openBox 失败产生游离异步错误）。可选数据，失败
    // 只退化为「本会话不查离线」。
    optional(HiveDramaDownloadStore.instance.warmUp),
    // 听书音频离线记录箱：与短剧箱分开，同样只在就绪时才查离线命中。
    optional(HiveAudioDownloadStore.instance.warmUp),
  ]);
  // 听书后台播放开关：异步读取 SharedPreferences，失败退化为默认开启。
  unawaited(AudioPreferences.instance.load());
  // 短剧「边看边往后缓存」的开关与集数：同一条装配链里读，避免播放页
  // 起来时还没加载完、拿默认值把用户关掉的开关又打开。
  unawaited(DramaCachePreferences.instance.load());
  // 本地代理（FongMiTV 同款）：开关默认开，启动时读盘、开着就起服务
  // （9978 起找空闲端口），关着就不起；/proxy 的 do/siteKey 分发同
  // 时接线。失败只退化为「本次启动不常驻」，播放时按需再起，不挡启动。
  bindLocalProxyRoutes();
  unawaited(() async {
    try {
      await LocalProxyPreferences.instance.load();
      if (LocalProxyPreferences.instance.enabled.value) {
        await LocalMediaProxy.instance.start();
      }
    } catch (error, stack) {
      AppLog.w(
        'startup',
        '本地代理启动失败，本次启动不常驻',
        error: error,
        stack: stack,
      );
    }
  }());
  // ZakaTV jar 内置站首次启动补进登记表：幂等、开关保留、删过的不复活。
  unawaited(SourceRegistry.instance.ensureBuiltinJarSites());
  // 内置 jar 启动时校验一次落盘：覆盖安装后指纹变了就重解，避免用户
  // 第一次点站才解包、还撞上并发（见 jar_bridge 的竞态修复说明）。
  // 尽力而为，不挡启动；已落盘且指纹对得上时只是两次 MD5 读盘。
  unawaited(
    JarBridge.verifyBuiltinJar(
      assetPath: zakatvJarAsset,
      configId: zakatvJarId,
      md5: zakatvJarMd5,
    ),
  );
  unawaited(
    JarBridge.verifyBuiltinJar(
      assetPath: youtubeJarAsset,
      configId: youtubeJarId,
      md5: youtubeJarMd5,
    ),
  );
  // 内置导入站（随包 py / 阅读 JSON）首次启动补进登记表：同款规矩。
  unawaited(SourceRegistry.instance.ensureBuiltinImportedSites());
  // 短剧切后台悬浮窗开关（#24）：异步读取，失败退化为默认关闭。
  unawaited(PlayerPreferences.loadFloatingWindow());
  // 离线缓存的网络门（官方 onNetChangeCheck）：断网/只剩计费链路时
  // 自动暂停下载队列，半成品保留。监听失败只退化为「无自动暂停」。
  try {
    Connectivity().onConnectivityChanged.listen((results) {
      final view = foldConnectivity(results);
      DramaDownloader.instance.updateConnectivity(
        online: view.online,
        metered: view.metered,
      );
      AudioDownloader.instance.updateConnectivity(
        online: view.online,
        metered: view.metered,
      );
      // 网络变化时重新应用出口代理：用户开关 VPN/梯子后，系统代理变了，
      // 核心的出口要跟着变（有代理走代理、无代理传空串回直连）；失败不抛、
      // 不影响下载队列的门控。
      unawaited(SystemProxyService.applyEgressProxy());
    });
  } catch (_) {
    // 监听连通性只为自动暂停下载；拿不到不构成启动失败，但值得留一条记录，
    // 否则「断网没自动暂停」会被当成下载器自己的 bug。
    AppLog.w('startup', '连通性监听注册失败，自动暂停下载不可用');
  }
  // 海报缓存的字节预算清扫：超额时删最旧的图。失败不影响任何页面。
  unawaited(PosterCache.instance.enforceBudget());
  // 小米澎湃 OS 公平运行内存：注册 TRIM/KILL 通道回调。必须在启动时构造，
  // 否则广播到达时 Dart 侧还没有处理函数，原生侧只能按“未处理”回。
  FairMemoryService.instance.init();
  final sp = await SharedPreferences.getInstance();
  // Note: Optional preference schemas cannot block local data startup; see
  // .agents/notes/implemented/bug-fix/2026-09-17-persistent-data-and-web-cancellation.md.
  final savedTheme = sp.get(themeModeKey);
  themeModeNotifier.value = themeModeFromName(
    savedTheme is String ? savedTheme : null,
  );
  // 墨水屏模式与深色模式同为可选偏好：读不到退化为关闭，不拖住启动。
  einkModeNotifier.value = sp.getBool(einkModeKey) ?? false;
  // 修仙体系：读盘（首次安装未建档时不静默注册，主界面弹创建档案弹窗）。
  unawaited(CultivationService.instance.ensureInitialized());
  // OLED 纯黑与墨水屏互斥；两个旧值同时为 true 时墨水屏优先。
  oledModeNotifier.value = sp.getBool(oledModeKey) ?? false;
  // 背景主题：读不到或非法值退化为默认，不拖住启动。
  backgroundNotifier.value = AppBackground.decode(
    sp.getString(backgroundKey),
    sp.getString(backgroundImageKey),
  );
  // 播放页布局（短剧上下分屏/左右分栏）同样是可选偏好：读不到退化为
  // 沉浸式，不阻塞启动。
  PlayerLayoutPreferences.mode.value = PlayerLayoutPreferences.decode(
    sp.getString(PlayerLayoutPreferences.key),
  );
  // 短剧分区上次停在哪个频道（官方 SP `last_tab_type`）：同样只读一次，
  // 页面在 initState 同步取用，首帧不会先闪「推荐」。
  DramaChannelPreferences.load(sp);
}

class FqApp extends StatefulWidget {
  const FqApp({super.key});

  @override
  State<FqApp> createState() => _FqAppState();
}

class _FqAppState extends State<FqApp> {
  // Official tabbar + 18dp applies on every page. Our floating dock is 64
  // high with an 8px gap; the desktop shell has no bottom bar.
  final _audioRoutes = AudioFloatingRoutes(
    defaultBottomInset: isWindowsDesktop ? 0 : 72,
  );
  // Desktop fullscreen reparents the content; keep the playback owner alive.
  final _audioScopeKey = GlobalKey();
  final _navigatorKey = isWindowsDesktop
      ? DesktopPlatform.navigatorKey
      : GlobalKey<NavigatorState>();

  @override
  void dispose() {
    BackendService.instance.cancelStartupTimeout();
    _audioRoutes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 网页引擎取页绑定导航键：伍果走 WebView 过指纹门，取页时往导航
    // 的 Overlay 里插离屏页；绑定是幂等赋值，每次重建都可跑。
    WebViewPageFetcher.bind(_navigatorKey);
    MaccmsContentClient.defaultWebFetch = WebViewPageFetcher.fetch;
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return ValueListenableBuilder<bool>(
          valueListenable: einkModeNotifier,
          builder: (context, eink, _) {
            return ListenableBuilder(
              listenable: Listenable.merge([
                oledModeNotifier,
                backgroundNotifier,
              ]),
              builder: (context, _) {
                final oled = oledModeNotifier.value;
                final background = backgroundNotifier.value;
                // 墨水屏强制浅色纯黑白：深色反白在墨水屏上残影最重。
                final effectiveMode = eink ? ThemeMode.light : mode;
                return MaterialApp(
                  navigatorKey: _navigatorKey,
                  navigatorObservers: [_audioRoutes],
                  builder: (context, child) {
                    final playback = AudioPlaybackScope(
                      key: _audioScopeKey,
                      navigatorKey: _navigatorKey,
                      recentListen: loadRecentListen,
                      child: child ?? const SizedBox.shrink(),
                    );
                    final framed = AudioFloatingRouteScope(
                      routes: _audioRoutes,
                      child: isWindowsDesktop
                          ? DesktopAppFrame(child: playback)
                          : playback,
                    );
                    // 图片背景：图片铺满 + 半透明罩（浅色罩白、深色罩黑），
                    // 正文颜色按主题亮度来，罩住后仍可读；墨水屏不铺图。
                    if (!eink &&
                        background.isImage &&
                        background.imagePath != null) {
                      final isDark =
                          Theme.of(context).brightness == Brightness.dark;
                      final scrim = isDark ? Colors.black : Colors.white;
                      return Stack(
                        children: [
                          Positioned.fill(
                            child: Image.file(
                              File(background.imagePath!),
                              fit: BoxFit.cover,
                              errorBuilder: (context, _, _) =>
                                  Container(color: scrim),
                            ),
                          ),
                          Positioned.fill(
                            child: Container(
                              color: scrim.withValues(alpha: 0.55),
                            ),
                          ),
                          framed,
                        ],
                      );
                    }
                    return framed;
                  },
                  title: '凡人修仙观影传',
                  debugShowCheckedModeBanner: false,
                  // OLED 纯黑只在深色下生效（浅色时 createTheme 直接忽略）。
                  theme: _theme(
                    Brightness.light,
                    eink: eink,
                    oled: oled,
                    background: background,
                  ),
                  darkTheme: _theme(
                    Brightness.dark,
                    eink: eink,
                    oled: oled,
                    background: background,
                  ),
                  themeMode: effectiveMode,
                  // 全 App 文案是中文，系统文本菜单（复制/粘贴/全选）与 Material
                  // 内置文案也必须跟着中文：缺 delegates 时一律回退英文（#79）。
                  locale: const Locale('zh', 'CN'),
                  supportedLocales: const [Locale('zh', 'CN'), Locale('en')],
                  localizationsDelegates: GlobalMaterialLocalizations.delegates,
                  home: AppBootstrap(
                    backendStarter: BackendService.instance.start,
                    child: const RootShell(),
                  ),
                );
              },
            );
          },
        );
      },
    );
  }

  ThemeData _theme(
    Brightness brightness, {
    bool eink = false,
    bool oled = false,
    AppBackground? background,
  }) => AppTheme.createTheme(
    brightness,
    einkMode: eink,
    oledMode: oled,
    background: background,
  );
}

/// Opens local data before any page can access LibraryStore's boxes. Failed
/// initialization is retryable without clearing or replacing the user's data.
/// See .agents/notes/implemented/bug-fix/2026-09-17-reviewed-runtime-boundaries.md.
///
/// When [backendStarter] is provided, the backend starts concurrently with
/// local-data init instead of waiting for it (the two chains are independent:
/// the backend only needs the asset bundle + app dir, never Hive/SharedPrefs
/// stores). The backend future is deliberately NOT awaited here: RootShell
/// awaits the same shared future (BackendService.start is idempotent) and
/// owns backend-error UI. When null (widget tests), no backend starts here.
class AppBootstrap extends StatefulWidget {
  final Widget child;
  final Future<void> Function()? initializer;
  final Future<void> Function()? backendStarter;

  const AppBootstrap({
    super.key,
    required this.child,
    this.initializer,
    this.backendStarter,
  });

  @override
  State<AppBootstrap> createState() => _AppBootstrapState();
}

class _AppBootstrapState extends State<AppBootstrap> {
  bool _initializing = false;
  bool _ready = false;
  bool _failed = false;
  Future<void>? _backendFuture;

  @override
  void initState() {
    super.initState();
    _initialize();
  }

  Future<void> _initialize() async {
    if (_initializing || _ready) return;
    setState(() {
      _initializing = true;
      _failed = false;
    });
    // Start the backend before awaiting local data (see class doc): the
    // two chains run concurrently; a retry must not start it twice.
    _backendFuture ??= widget.backendStarter?.call();
    // Attach a no-op error handler so a backend failure is never reported
    // as an unhandled async error if RootShell never mounts to await the
    // same future (e.g. local-data init keeps failing). RootShell awaiting
    // the original future still observes the error.
    unawaited(_backendFuture?.then<void>((_) {}, onError: (_) {}));
    try {
      await (widget.initializer ?? _initializeLocalData)();
      if (mounted) setState(() => _ready = true);
    } catch (_) {
      // 这里不写日志：启动失败发生在持久化开启之前，而 AppLog 的写入会排到
      // 那条尚未完成的 I/O 之后（test/app_bootstrap_test.dart 的失败路径用例
      // 因此会挂到超时）。失败本身已经由界面的重试入口与 runZonedGuarded 呈现。
      if (mounted) setState(() => _failed = true);
    } finally {
      _initializing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_ready) return widget.child;
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_failed)
                  Icon(
                    LucideIcons.triangle_alert,
                    color: Theme.of(context).colorScheme.error,
                  )
                else
                  const CircularProgressIndicator(),
                const SizedBox(height: 16),
                Text(_failed ? '无法读取本地数据' : '正在读取本地数据…'),
                if (_failed) ...[
                  const SizedBox(height: 8),
                  const Text('请检查设备可用空间后重试。', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    onPressed: _initialize,
                    child: const Text('重试'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class RootShell extends StatefulWidget {
  final Future<void> Function()? backendStarter;

  const RootShell({super.key, this.backendStarter});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell>
    with SingleTickerProviderStateMixin {
  int _index = 0;
  bool _backendReady = false;

  /// 游戏 / 观影 3D 翻转切换的控制器（0..1：前半段旧页转走，
  /// 0.5 处换 tab，后半段新页转进来）。
  late final AnimationController _flipController =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 600));

  /// 翻转进行中（防连点重复翻）。
  bool _flipping = false;

  /// 创建道友档案是否已读盘核对过（未核对完先显示加载，不闪创建页）。
  bool _profileChecked = false;

  /// 上次升境弹窗结算时的总修为（null 表示还没读盘）；修为只涨不跌，
  /// 跨过境界门槛时弹升境庆祝弹窗。
  int? _lastLevelUpXp;

  /// 升境庆祝弹窗是否正在显示（避免修为连续跳变时叠弹窗）。
  bool _levelUpDialogShowing = false;

  /// 首页 feed 的滚动控制器，由壳层持有以便底部栏触发回顶部。

  /// 首页 feed 的滚动控制器，由壳层持有以便底部栏触发回顶部。
  final ScrollController _homeScroll = ScrollController();

  /// 上一次「重复点击底部首页 tab」的时间，用于 800ms 防抖。
  ///
  /// 官方对重复点击用 `throttleFirst(800L, MILLISECONDS)`
  /// （BookshelfVideoMultiTabFragment.java:101）。
  DateTime? _lastHomeTabRepeatAt;

  /// 底部 tab 被选中。重复点当前 tab 时回到首页顶部。
  ///
  /// 官方把它放在底部栏而不是页内：`onBottomTabRepeatClick()` 转发到当前
  /// fragment，最终是 `scrollToPosition(0)`（BookshelfVideoTabFragment.java:247）。
  /// 首页头部是普通 sliver（不是折叠 AppBar），把 offset 归零即等价，吸顶的
  /// 分类栏会自己重新吸住。
  void _selectTab(int index) {
    if (index != _index) {
      setState(() => _index = index);
      return;
    }
    if (index != 1) return; // 只有首页有 feed 需要回顶
    final now = DateTime.now();
    final last = _lastHomeTabRepeatAt;
    if (last != null && now.difference(last).inMilliseconds < 800) return;
    _lastHomeTabRepeatAt = now;
    if (!_homeScroll.hasClients) return;
    // 官方是瞬间跳转（scrollToPosition(0)），没有动画。
    _homeScroll.jumpTo(_homeScroll.position.minScrollExtent);
  }

  String? _backendError;

  @override
  void initState() {
    super.initState();
    // 短剧频道在推荐（视频流）与浅色页之间切换时，悬浮 dock 和系统导航栏
    // 要跟着换肤，所以停在壳层的 build 里监听。
    dramaLightPageNotifier.addListener(_onDramaChromeChanged);
    // 修为变化时刷新导航栏：影视入口到元婴期才由锁变正常。
    CultivationService.instance.snapshotNotifier.addListener(
      _onCultivationChanged,
    );
    _startBackend();
    // 挂机游戏服务早启动：进游戏页之前定时器就跑起来，
    // 切到影视区看视频时修为与元宝照涨。
    unawaited(GameService.instance.ensureInitialized());
    // 硬门槛：先读盘核对有没有创建过道友档案；没建档时主界面不挂，
    // 只显示全屏创建人物界面（无跳过、无关闭、返回键也绕不过去），
    // 建档落盘后才进主界面。
    unawaited(_checkProfile());
  }

  void _onDramaChromeChanged() {
    if (mounted) setState(() {});
  }

  void _onCultivationChanged() {
    if (mounted) setState(() {});
    _maybeShowLevelUpDialog();
  }

  /// 读盘核对道友档案：核对完才决定显示创建页还是主界面，
  /// 免得已建档的用户首帧先闪一下创建页。
  Future<void> _checkProfile() async {
    await CultivationService.instance.ensureInitialized();
    if (!mounted) return;
    _lastLevelUpXp ??= CultivationService.instance.snapshot.totalXp;
    setState(() => _profileChecked = true);
  }

  /// 修为跨过境界门槛时弹升境庆祝弹窗（列新解锁的内容区与成人站档位）。
  /// 首次读盘只记基线不弹；弹窗显示期间的跳变先记着，关掉后重算再弹，
  /// 不叠弹窗、不漏境界。
  void _maybeShowLevelUpDialog() {
    if (!mounted || _levelUpDialogShowing) return;
    final currentXp = CultivationService.instance.snapshot.totalXp;
    final lastXp = _lastLevelUpXp;
    if (lastXp == null) {
      _lastLevelUpXp = currentXp;
      return;
    }
    if (currentXp <= lastXp) {
      _lastLevelUpXp = currentXp;
      return;
    }
    final crossed = crossedRealmIndexes(lastXp, currentXp);
    if (crossed.isEmpty) {
      _lastLevelUpXp = currentXp;
      return;
    }
    _lastLevelUpXp = currentXp;
    _levelUpDialogShowing = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) {
        _levelUpDialogShowing = false;
        return;
      }
      await showCultivationLevelUpDialog(
        context,
        crossedRealmIndexes: crossed,
        adultRegistryOrder: adultVideoSiteOrder,
        newXp: currentXp,
      );
      _levelUpDialogShowing = false;
      // 关掉后重算一次：弹窗期间又有跳变时补弹，不漏境界。
      _maybeShowLevelUpDialog();
    });
  }

  /// A backend (re)start already in flight. Retries tapped twice must not
  /// start the core twice; the guard also keeps a retry from flashing the
  /// loading screen — while it runs, the old error stays on the degraded
  /// banner and the main UI stays up (see [_degradedShell]).
  bool _backendStarting = false;

  Future<void> _startBackend() async {
    if (_backendStarting) return;
    _backendStarting = true;
    try {
      await (widget.backendStarter ?? BackendService.instance.start)();
      if (mounted) {
        setState(() {
          _backendReady = true;
          _backendError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _backendError = '$e';
        });
      }
    } finally {
      _backendStarting = false;
    }
  }

  /// Degraded shell: the normal main UI with a banner on top saying the
  /// local service failed and some features are unavailable, plus a retry
  /// that really restarts the core and an offline-reading entry. Used when
  /// the backend never came up (e.g. its loopback port stayed held by a
  /// stale process) instead of blocking the whole app on a failure page.
  Widget _degradedShell(Widget shell) {
    final error = _backendError;
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    const Icon(LucideIcons.triangle_alert, size: 18),
                    const SizedBox(width: 8),
                    const Expanded(child: Text('本地服务启动失败，部分功能不可用')),
                    TextButton(
                      onPressed: _startBackend,
                      child: const Text('重试'),
                    ),
                    TextButton(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const CachedBooksPage(),
                        ),
                      ),
                      child: const Text('离线阅读'),
                    ),
                  ],
                ),
              ),
            ),
            if (error != null)
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 4,
                ),
                child: Text(
                  error,
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 12, color: Colors.red),
                ),
              ),
            Expanded(child: shell),
          ],
        ),
      ),
    );
  }

  /// 游戏 / 观影切换钮：像 3D 换界面一样翻转切换——
  /// 前半段旧界面转走（0→90 度），中点换 tab，
  /// 后半段新界面转进来（90 度→0）。
  /// 游戏切观影后游戏后台继续挂机（服务层定时器不停）；
  /// 观影切游戏后正在播的视频暂停。
  Future<void> _flipToTab(int index) async {
    if (_flipping) return;
    if (isWindowsDesktop) {
      if (desktopTab.value == index) return;
    } else if (_index == index) {
      return;
    }
    _flipping = true;
    if (index == 0) {
      unawaited(NativePlayer.pauseOthers());
    }
    await _flipController.animateTo(
      0.5,
      duration: const Duration(milliseconds: 300),
    );
    if (!mounted) {
      _flipping = false;
      return;
    }
    if (isWindowsDesktop) {
      desktopTab.value = index;
    } else {
      setState(() => _index = index);
    }
    await _flipController.animateTo(
      1.0,
      duration: const Duration(milliseconds: 300),
    );
    if (mounted) _flipController.value = 0;
    _flipping = false;
  }

  /// 给翻转切换包一层 3D 旋转（带透视的 rotateY）。
  Widget _flipWrap(Widget child) {
    return AnimatedBuilder(
      animation: _flipController,
      builder: (context, child) {
        final value = _flipController.value;
        final angle =
            value <= 0.5 ? value * math.pi : (1 - value) * math.pi;
        return Transform(
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.0015)
            ..rotateY(angle),
          alignment: Alignment.center,
          child: child,
        );
      },
      child: child,
    );
  }

  @override
  void dispose() {
    dramaLightPageNotifier.removeListener(_onDramaChromeChanged);
    CultivationService.instance.snapshotNotifier.removeListener(
      _onCultivationChanged,
    );
    _homeScroll.dispose();
    _flipController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 硬门槛：读盘没核对完先显示加载；核对完未建档时只显示全屏创建人物
    // 界面（创建页自带 PopScope 禁返回，没有跳过/关闭），建档落盘后
    // 快照监听会重建、自动进主界面；本地服务在后台照常启动。
    if (!_profileChecked) {
      return const Scaffold(
        body: SafeArea(
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('正在读取本地数据…'),
              ],
            ),
          ),
        ),
      );
    }
    if (!CultivationService.instance.snapshot.hasProfile) {
      return CultivationCreatePage(
        onCreated: () {
          if (mounted) setState(() {});
        },
      );
    }
    // 本地服务起不来也不整页拦死：还没出结果时只显示加载；一旦失败就进
    // 主界面、顶一条横幅提示部分功能不可用（见 [_degradedShell]），失败
    // 原因仍留在横幅里，重试点下去重新拉起核心。
    final backendDegraded = !_backendReady && _backendError != null;
    if (!_backendReady && !backendDegraded) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  const Text('正在启动本地服务...'),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const CachedBooksPage(),
                      ),
                    ),
                    icon: const Icon(LucideIcons.download),
                    label: const Text('离线阅读'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }
    final Widget shell;
    if (isWindowsDesktop) {
      shell = ValueListenableBuilder<int>(
        valueListenable: desktopTab,
        builder: (context, index, _) {
          AudioFloatingRouteScope.configure(context, hidden: index == 2);
          return _flipWrap(
            LazyIndexedStack(
              index: index,
              children: [
                GamePage(
                  active: index == 0,
                  onExit: () => desktopTab.value = 1,
                  onOpenFilmTab: () => desktopTab.value = 3,
                  onOpenDramaTab: () => desktopTab.value = 2,
                  onSwitchToVideo: () => _flipToTab(3),
                ),
                HomePage(cueLoader: () => ApiClient.instance.searchCue()),
                const DramaPage(),
                VideoPage(onOpenGame: () => _flipToTab(0)),
                const LivePage(),
                LibraryPage(
                  onBrowse: () => desktopTab.value = 1,
                  onFindDrama: () => desktopTab.value = 2,
                ),
                const MinePage(),
              ],
            ),
          );
        },
      );
    } else {
    AudioFloatingRouteScope.configure(context, hidden: _index == 2);
    final palette = HomePalette.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isDramaTab = _index == 2;
    // 短剧的推荐频道压在全屏视频流上，dock 用深色玻璃；看剧/漫剧/最近/收藏
    // 是浅色页，dock 跟主题走，否则浅色外观下页面是奶白、dock 还是黑的。
    final dramaOnVideo = isDramaTab && !dramaLightPageNotifier.value;
    final glassDark = isDark || dramaOnVideo;
    // 墨水屏模式：本 build 由 Theme 变化触发重建（上面读了 Theme.of），
    // 这里直接读 notifier 当前值即可拿到最新开关，不另加监听。
    final eink = einkModeNotifier.value;
    // OLED 纯黑只在深色外观下生效，浅色 / 墨水屏时该值为 false。
    final oled = oledActive();
    final navBar = NavigationBarTheme(
      data: NavigationBarThemeData(
        height: 64,
        elevation: 0,
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        shadowColor: Colors.transparent,
        indicatorColor: eink
            ? Colors.black
            : HomePalette.accent.withValues(alpha: glassDark ? 0.20 : 0.12),
        indicatorShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 22,
            color: states.contains(WidgetState.selected)
                ? (eink ? Colors.white : HomePalette.accent)
                : (eink
                      ? Colors.black
                      : (glassDark
                            ? Colors.white.withValues(alpha: 0.65)
                            : palette.muted)),
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontSize: 11,
            fontWeight: states.contains(WidgetState.selected)
                ? FontWeight.w700
                : FontWeight.w500,
            color: states.contains(WidgetState.selected)
                ? (eink
                      ? Colors.black
                      : (glassDark ? HomePalette.accent : palette.accentText))
                : (eink
                      ? Colors.black
                      : (glassDark
                            ? Colors.white.withValues(alpha: 0.65)
                            : palette.muted)),
          ),
        ),
      ),
      child: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: _selectTab,
        backgroundColor: Colors.transparent,
        elevation: 0,
        destinations: [
          // 游戏在最前面：全屏 2.5D 战场，点它进游戏。
          const NavigationDestination(
            icon: Icon(LucideIcons.gamepad),
            selectedIcon: Icon(LucideIcons.gamepad),
            label: '游戏',
          ),
          const NavigationDestination(
            icon: Icon(LucideIcons.house),
            selectedIcon: Icon(LucideIcons.house),
            label: '首页',
          ),
          const NavigationDestination(
            icon: Icon(LucideIcons.clapperboard),
            selectedIcon: Icon(LucideIcons.clapperboard),
            label: '短剧',
          ),
          // 影视区是成人午夜区：导航栏一直显示，修为不到元婴期时显示上锁
          // 图标，点进去是上锁页（写明还差多少修为）；到元婴期后正常显示。
          NavigationDestination(
            icon: Icon(
              CultivationService.instance.snapshot.unlockedVideo
                  ? LucideIcons.film
                  : LucideIcons.lock,
            ),
            selectedIcon: Icon(
              CultivationService.instance.snapshot.unlockedVideo
                  ? LucideIcons.film
                  : LucideIcons.lock,
            ),
            label: '影视',
          ),
          const NavigationDestination(
            icon: Icon(LucideIcons.tv),
            selectedIcon: Icon(LucideIcons.tv),
            label: '直播',
          ),
          const NavigationDestination(
            icon: Icon(LucideIcons.library_big),
            selectedIcon: Icon(LucideIcons.library_big),
            label: '书架',
          ),
          const NavigationDestination(
            icon: Icon(LucideIcons.circle_user_round),
            selectedIcon: Icon(LucideIcons.circle_user_round),
            label: '我的',
          ),
        ],
      ),
    );

    // 静态半透明底：与毛玻璃同色，供短剧 tab 复用（短剧 tab 背后是每帧
    // 变化的视频流，BackdropFilter 每帧重算模糊，GPU 满负荷；该 tab 下
    // 用静态底，外观几乎不变；切出短剧 tab 后恢复毛玻璃）。OLED 纯黑直接
    // 用不透明的近黑底：纯黑画布上毛玻璃只会晕出一圈灰，还白白模糊每帧。
    final staticNavBar = Container(
      decoration: BoxDecoration(
        color: oled
            ? const Color(0xFF0C0C0E)
            : (glassDark
                  ? const Color(0xFF161619).withValues(alpha: 0.72)
                  : Colors.white.withValues(alpha: 0.82)),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(
          color: glassDark
              ? Colors.white.withValues(alpha: 0.16)
              : Colors.white.withValues(alpha: 0.75),
          width: 0.8,
        ),
      ),
      child: navBar,
    );

    // 系统导航栏（Android 底部系统自绘的那条）按当前画布取色。Flutter 的
    // light / dark 两套预设都把它写成纯黑底 + 白图标，浅色页面下会在最底部
    // 留一条突兀的黑带；短剧只有视频流（推荐）背后是视频，仍用黑。
    final lightSystemIcons = dramaOnVideo || isDark;
    shell = Scaffold(
      extendBody: true,
      // 状态栏图标亮度挂在壳层、按选中 tab 切换：短剧页是黑底视频流（官方
      // SeriesMallFragment 的透明顶栏直接压在 feed 上），深色图标在黑底上
      // 整条状态栏都看不见，必须浅色；其余三页浅色底用深色。样式放壳层而不是
      // 各页内部，是因为 IndexedStack 里未选中的页不参与绘制，页内
      // AnnotatedRegion 切走后会残留上一个页的样式。
      body: AnnotatedRegion<SystemUiOverlayStyle>(
        value:
            (lightSystemIcons
                    ? SystemUiOverlayStyle.light
                    : SystemUiOverlayStyle.dark)
                .copyWith(
                  systemNavigationBarColor: dramaOnVideo
                      ? Colors.black
                      : palette.canvas,
                  systemNavigationBarDividerColor: dramaOnVideo
                      ? Colors.black
                      : palette.canvas,
                  systemNavigationBarIconBrightness: lightSystemIcons
                      ? Brightness.light
                      : Brightness.dark,
                ),
        child: _flipWrap(
          LazyIndexedStack(
            index: _index,
            children: [
              GamePage(
                active: _index == 0,
                onExit: () => setState(() => _index = 1),
                onOpenFilmTab: () => setState(() => _index = 3),
                onOpenDramaTab: () => setState(() => _index = 2),
                onSwitchToVideo: () => _flipToTab(3),
              ),
              HomePage(
                scrollController: _homeScroll,
                cueLoader: () => ApiClient.instance.searchCue(),
              ),
              const DramaPage(),
              VideoPage(onOpenGame: () => _flipToTab(0)),
              const LivePage(),
              // 空书架上的「去书城找书」切回首页 tab；收藏空态的「找短剧」
              // 切到短剧 tab。
              LibraryPage(
                onBrowse: () => setState(() => _index = 1),
                onFindDrama: () => setState(() => _index = 2),
              ),
              const MinePage(),
            ],
          ),
        ),
      ),
      // 游戏 tab 全屏战场：底部导航藏掉，不遮战场；出游戏靠
      // 游戏内「离开」钮或右上角「观影」切换钮。
      bottomNavigationBar: _index == 0
          ? null
          : SafeArea(
        top: false,
        left: false,
        right: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: RepaintBoundary(
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
                // 墨水屏：阴影是灰阶 + 刷新残影来源，直接去掉，改用实线边框。
                boxShadow: eink
                    ? null
                    : [
                        BoxShadow(
                          color: Colors.black.withValues(
                            alpha: glassDark ? 0.38 : 0.08,
                          ),
                          blurRadius: 22,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: HomePalette.accent.withValues(
                            alpha: glassDark ? 0.06 : 0.03,
                          ),
                          blurRadius: 14,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(28),
                // 墨水屏：BackdropFilter 毛玻璃会把底部栏变成一团灰，改实色。
                // 短剧 tab：背后是每帧变化的视频流，BackdropFilter 每帧都要
                // 重算模糊，GPU 一直满负荷；该 tab 下改用同色静态半透明底，
                // 外观几乎不变，省掉每帧重栅格化。切出短剧 tab 后恢复毛玻璃。
                child: eink
                    ? Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(28),
                          border: Border.all(color: Colors.black, width: 0.8),
                        ),
                        child: navBar,
                      )
                    : isDramaTab || oled
                    ? staticNavBar
                    : BackdropFilter(
                        filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                        child: staticNavBar,
                      ),
              ),
            ),
          ),
        ),
      ),
    );
    }
    return backendDegraded ? _degradedShell(shell) : shell;
  }
}
