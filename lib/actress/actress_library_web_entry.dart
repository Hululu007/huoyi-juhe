import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../widgets/series_detail/moyi_detail_theme.dart';
import 'actress_adapter_repository.dart' show AppRepository;
import 'actress_adapter_store.dart' show LocalStore;
import 'actress_library_web_page.dart';
import 'actress_nvku_page.dart';

/// 演员库入口（2026-11-26 同步魔蚁合并页）：合并网页（123AV
/// 外壳 + whos 女优库板块，底部源切换条首段为女优库默认源）
/// 作演员库界面，宿主走本树的 WebView 宿主页与自家桥
/// （见 actress_library_bridge.dart / actress_library_db.dart）。
///
/// 原生女优库页（ActressNvkuPage）保留作回退不删：合并页资源
/// 加载失败时自动落回原生页。境界门禁不挂在本页——入口只被
/// 已过元婴门禁的演员库 tab 与影视区入口卡到达（与插件区成人
/// 条目同口径：未达门槛整行不显示，见 main.dart 的
/// _actressLibraryTab 与 plugin_zone_view.dart）。
class ActressLibraryWebEntryPage extends StatefulWidget {
  const ActressLibraryWebEntryPage({
    super.key,
    required this.repository,
    required this.store,
    this.showTitle = true,
    this.htmlLoader,
    this.fallbackBuilder,
    this.webViewBuilder,
  });

  final AppRepository repository;
  final LocalStore store;

  /// 与原生页同名参数：只透传给回退的原生页（合并页自带界面
  /// 框架，不需要壳侧标题）。
  final bool showTitle;

  /// 测试注入资源加载；为空时从 rootBundle 读合并页资源。
  final Future<String> Function()? htmlLoader;

  /// 测试/特殊入口注入回退页；为空时回退原生女优库页。
  final Widget Function(BuildContext context)? fallbackBuilder;

  /// 测试/预览注入平台视图替身，透传给宿主页。
  final Widget Function(BuildContext context)? webViewBuilder;

  static const String assetPath = 'assets/actress_library.html';

  @override
  State<ActressLibraryWebEntryPage> createState() =>
      _ActressLibraryWebEntryPageState();
}

class _ActressLibraryWebEntryPageState
    extends State<ActressLibraryWebEntryPage> {
  late final Future<String> _htmlFuture = _load();

  Future<String> _load() {
    final loader = widget.htmlLoader;
    if (loader != null) return loader();
    return rootBundle.loadString(ActressLibraryWebEntryPage.assetPath);
  }

  Widget _fallback(BuildContext context) {
    final builder = widget.fallbackBuilder;
    if (builder != null) return builder(context);
    return ActressNvkuPage(
      repository: widget.repository,
      store: widget.store,
      showTitle: widget.showTitle,
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: _htmlFuture,
      builder: (context, snapshot) {
        if (snapshot.hasData) {
          return ActressLibraryWebPage(
            html: snapshot.data!,
            repository: widget.repository,
            store: widget.store,
            viewBuilder: widget.webViewBuilder,
          );
        }
        if (snapshot.hasError) return _fallback(context);
        return const MoyiPageBackground(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: CircularProgressIndicator()),
          ),
        );
      },
    );
  }
}
