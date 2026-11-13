import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../services/app_links.dart';
import '../web_scrape/scrape_py_service.dart';
import '../web_scrape/verification_detector.dart';
import '../web_scrape/web_scrape_service.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'source_management_page.dart';

/// 网页爬取：输网址拉页面，按模式抽内容；结果页顶部可一键生成 py 蜘蛛。
///
/// 结构参照万象影院的爬取页（模式分段 + 网址条 + 结果区 + 顶部 py 生成
/// 卡片），界面按本树规矩重写（深紫底 + 白字 + 中文直写）。一期只做页内
/// 展示 + 外部浏览器打开；命中验证特征时诚实报错 + 指引去浏览器验证，
/// 不做 WebView 验证屏。
class WebScrapePage extends StatefulWidget {
  const WebScrapePage({
    super.key,
    this.initialMode,
    this.scrapeService,
    this.pyService,
  });

  final ScrapeMode? initialMode;

  /// 测试注入用；不传走默认单例/默认构造。
  final WebScrapeService? scrapeService;
  final ScrapePyService? pyService;

  @override
  State<WebScrapePage> createState() => _WebScrapePageState();
}

/// 网址归一化：去空白；没写协议时补 https；解析不出 host 返回 null。
String? normalizeScrapeUrl(String raw) {
  final trimmed = raw.trim();
  if (trimmed.isEmpty) return null;
  final withScheme = trimmed.contains('://') ? trimmed : 'https://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  return withScheme;
}

class _WebScrapePageState extends State<WebScrapePage> {
  late ScrapeMode _mode;
  late final WebScrapeService _scrapeService;
  late final ScrapePyService _pyService;
  final TextEditingController _urlCtl = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _verifyBlocked = false;
  String _failedUrl = '';
  ScrapeResult? _result;
  bool _generating = false;
  String _genProgress = '';
  String? _genError;
  OneKeyCodeResult? _genResult;
  bool _registering = false;
  bool _registered = false;

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode ?? ScrapeMode.general;
    _scrapeService = widget.scrapeService ?? WebScrapeService.instance;
    _pyService = widget.pyService ?? ScrapePyService();
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  String _templateLabel(String templateId) {
    return switch (templateId) {
      'apple_cms_v10' => '苹果 CMS JSON',
      'tvbox_api' => 'TVBox 共享接口',
      'maccms_html' => 'MacCMS 网页',
      'wordpress' => 'WordPress',
      'nextjs' => 'Next.js',
      'generic_html' => '通用网页嗅探',
      _ => templateId.isEmpty ? '自动探测' : templateId,
    };
  }

  Future<void> _scrape(String rawUrl) async {
    final url = normalizeScrapeUrl(rawUrl);
    if (url == null) {
      setState(() {
        _error = '请输入正确的网址，例如 https://example.com';
        _verifyBlocked = false;
        _result = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
      _verifyBlocked = false;
      _failedUrl = '';
      _result = null;
      _genProgress = '';
      _genError = null;
      _genResult = null;
      _registered = false;
    });
    try {
      final result = await _scrapeService.scrape(url, _mode);
      if (mounted) {
        setState(() {
          _result = result;
          _loading = false;
        });
      }
    } on VerificationRequiredException catch (e) {
      if (mounted) {
        setState(() {
          _error = '该站点需要验证后才能访问，请先在浏览器里完成验证，再回来重新爬取。';
          _verifyBlocked = true;
          _failedUrl = e.url;
          _loading = false;
        });
      }
    } on HttpStatusException catch (e) {
      if (mounted) {
        setState(() {
          _error = '页面返回 HTTP ${e.statusCode}，请检查地址或换个页面试试。';
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '爬取失败：$e';
          _loading = false;
        });
      }
    }
  }

  void _scrapeUrl(String url) {
    _urlCtl.text = url;
    _scrape(url);
  }

  /// 一键生成 py：依据本次爬取实际拿到的数据（地址、HTML、标题、链接），
  /// 不再让用户输网址重新探测。只产出代码，默认不注册。
  Future<void> _generatePy() async {
    final ScrapeResult? result = _result;
    if (result == null || _generating) return;
    setState(() {
      _generating = true;
      _genProgress = '正在分析爬取数据…';
      _genError = null;
      _genResult = null;
      _registered = false;
    });
    try {
      final OneKeyCodeResult gen = await _pyService.generateFromScrape(
        scrapeUrl: result.url,
        html: result.html,
        pageTitle: result.pageTitle,
        linkUrls: result.links.map((ScrapeLink l) => l.url).toList(),
        onProgress: (String p) {
          if (mounted) setState(() => _genProgress = p);
        },
      );
      if (mounted) {
        setState(() {
          _genResult = gen;
          _genProgress = '';
        });
      }
    } on OneKeyException catch (e) {
      if (mounted) {
        setState(() {
          _genError = e.message;
          _genProgress = '';
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _genError = '生成失败：$e';
          _genProgress = '';
        });
      }
    } finally {
      if (mounted) setState(() => _generating = false);
    }
  }

  /// 导出 py 文件：写临时文件后走系统分享，用户自选保存位置或发送去向。
  Future<void> _exportPy() async {
    final OneKeyCodeResult? gen = _genResult;
    if (gen == null) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      final Directory tmp = await getTemporaryDirectory();
      final File tmpFile = File('${tmp.path}/${gen.fileName}');
      await tmpFile.writeAsString(gen.code);
      await Share.shareXFiles(<XFile>[XFile(tmpFile.path, name: gen.fileName)]);
    } on Object catch (e) {
      if (mounted) {
        messenger.showSnackBar(SnackBar(content: Text('导出失败：$e')));
      }
    }
  }

  /// 把已生成的 py 注册进站点列表（可选，默认不注册；同名站就地更新）。
  Future<void> _registerPy() async {
    final OneKeyCodeResult? gen = _genResult;
    if (gen == null || _registering || _registered) return;
    setState(() => _registering = true);
    try {
      final ScrapePyRegisterResult res = await _pyService.registerGenerated(
        generated: gen,
      );
      if (!mounted) return;
      setState(() => _registered = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            res.updated ? '已更新源：${res.entryName}' : '已注册进站点列表：${res.entryName}',
          ),
        ),
      );
    } on OneKeyException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(e.message)));
      }
    } on Object catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('注册失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _registering = false);
    }
  }

  /// 深底输入框：深紫半透明底 + 白字 + 提示字白 55% + 可见描边（一键页同款）。
  InputDecoration _moyiField({required String labelText, String? hintText}) =>
      InputDecoration(
        labelText: labelText,
        hintText: hintText,
        labelStyle: const TextStyle(color: moyiMutedOnDark),
        hintStyle: const TextStyle(color: moyiMutedOnDark),
        filled: true,
        fillColor: moyiDarkCardFill,
        border: const OutlineInputBorder(
          borderSide: BorderSide(color: moyiDarkCardBorder),
        ),
        enabledBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: moyiDarkCardBorder),
        ),
        focusedBorder: const OutlineInputBorder(
          borderSide: BorderSide(color: moyiGold, width: 1.5),
        ),
      );

  @override
  Widget build(BuildContext context) {
    return MoyiPageBackground(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        appBar: AppBar(
          title: const Text('网页爬取'),
          backgroundColor: Colors.transparent,
          surfaceTintColor: Colors.transparent,
          scrolledUnderElevation: 0,
          foregroundColor: Colors.white,
        ),
        body: Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                children: <Widget>[
                  SegmentedButton<ScrapeMode>(
                    selected: <ScrapeMode>{_mode},
                    showSelectedIcon: false,
                    onSelectionChanged: (s) => setState(() => _mode = s.first),
                    segments: const <ButtonSegment<ScrapeMode>>[
                      ButtonSegment<ScrapeMode>(
                        value: ScrapeMode.general,
                        label: Text('通用'),
                      ),
                      ButtonSegment<ScrapeMode>(
                        value: ScrapeMode.novel,
                        label: Text('小说'),
                      ),
                      ButtonSegment<ScrapeMode>(
                        value: ScrapeMode.comic,
                        label: Text('漫画'),
                      ),
                      ButtonSegment<ScrapeMode>(
                        value: ScrapeMode.video,
                        label: Text('视频'),
                      ),
                      ButtonSegment<ScrapeMode>(
                        value: ScrapeMode.article,
                        label: Text('文章'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: <Widget>[
                      Expanded(
                        child: TextField(
                          controller: _urlCtl,
                          style: const TextStyle(color: Colors.white),
                          decoration: _moyiField(
                            labelText: '网址',
                            hintText: '例如 https://example.com',
                          ),
                          keyboardType: TextInputType.url,
                          textInputAction: TextInputAction.go,
                          onSubmitted: _scrape,
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton.icon(
                        onPressed: _loading
                            ? null
                            : () => _scrape(_urlCtl.text),
                        icon: _loading
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.travel_explore_rounded),
                        label: Text(_loading ? '爬取中…' : '爬取'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Expanded(child: _buildResult()),
          ],
        ),
      ),
    );
  }

  Widget _buildResult() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    final error = _error;
    if (error != null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Icon(
            Icons.error_outline_rounded,
            size: 48,
            color: moyiMutedOnDark,
          ),
          const SizedBox(height: 12),
          Text(
            error,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 15),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              if (_verifyBlocked) ...<Widget>[
                FilledButton.icon(
                  onPressed: () => openAppLink(context, _failedUrl),
                  icon: const Icon(Icons.open_in_new_rounded),
                  label: const Text('在浏览器打开'),
                ),
                const SizedBox(width: 12),
              ],
              FilledButton.icon(
                onPressed: () => _scrape(_urlCtl.text),
                icon: const Icon(Icons.refresh_rounded),
                label: const Text('重试'),
              ),
            ],
          ),
        ],
      );
    }
    final result = _result;
    if (result == null) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const <Widget>[
          SizedBox(height: 32),
          Icon(Icons.travel_explore_rounded, size: 48, color: moyiMutedOnDark),
          SizedBox(height: 12),
          Text(
            '输入网址开始爬取',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            '通用模式列出页面链接，小说/文章模式抽正文段落，漫画模式抽图片，视频模式抽视频地址。爬到页面后，顶部的卡片可依据本次爬取的数据一键生成 py 蜘蛛。',
            textAlign: TextAlign.center,
            style: TextStyle(color: moyiBodyOnDark),
          ),
        ],
      );
    }
    if (result.isEmpty) {
      return ListView(
        padding: const EdgeInsets.all(16),
        children: const <Widget>[
          SizedBox(height: 32),
          Icon(Icons.search_off_rounded, size: 48, color: moyiMutedOnDark),
          SizedBox(height: 12),
          Text(
            '这个页面没有爬到内容',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white, fontSize: 16),
          ),
          SizedBox(height: 8),
          Text(
            '换个模式或换个页面试试；部分页面内容由脚本动态加载，爬取不到是正常的。',
            textAlign: TextAlign.center,
            style: TextStyle(color: moyiBodyOnDark),
          ),
        ],
      );
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      children: <Widget>[
        if (result.pageTitle != null) ...<Widget>[
          Text(
            result.pageTitle!,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 12),
        ],
        ..._buildPyGen(),
        const SizedBox(height: 12),
        if (_mode == ScrapeMode.general) ..._buildLinks(result),
        if (_mode == ScrapeMode.novel || _mode == ScrapeMode.article)
          ..._buildText(result),
        if (_mode == ScrapeMode.comic) ..._buildImages(result),
        if (_mode == ScrapeMode.video) ..._buildVideos(result),
      ],
    );
  }

  /// 一键生成 py 区：位于爬取结果顶部，所有模式共用。依据本次爬取
  /// 实际拿到的数据生成；生成后可导出 py 文件，也可注册进站点列表。
  List<Widget> _buildPyGen() {
    final OneKeyCodeResult? gen = _genResult;
    return <Widget>[
      Card(
        color: moyiDarkCardFill,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: moyiDarkCardBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '一键生成 py 蜘蛛',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              const Text(
                '依据本次爬取的页面数据生成（站点地址、页面结构、标题与链接），不用重新输网址。',
                style: TextStyle(color: moyiBodyOnDark),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: _generating ? null : _generatePy,
                icon: const Icon(Icons.auto_fix_high_rounded),
                label: Text(_generating ? '生成中…' : '一键生成并导出 py'),
              ),
              if (_genProgress.isNotEmpty) ...<Widget>[
                const SizedBox(height: 12),
                Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _genProgress,
                        style: const TextStyle(color: moyiBodyOnDark),
                      ),
                    ),
                  ],
                ),
              ],
              if (_genError != null) ...<Widget>[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0x26F44336),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    _genError!,
                    style: const TextStyle(color: Colors.white),
                  ),
                ),
              ],
              if (gen != null) ...<Widget>[
                const SizedBox(height: 12),
                const Divider(color: moyiDarkCardBorder),
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    const Icon(Icons.check_circle_rounded, color: Colors.green),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '已生成：${gen.siteName}',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '文件：${gen.fileName}',
                  style: const TextStyle(color: moyiBodyOnDark),
                ),
                Text(
                  '模板：${_templateLabel(gen.templateId)}（${gen.mode}）',
                  style: const TextStyle(color: moyiBodyOnDark),
                ),
                if (gen.api.isNotEmpty)
                  Text(
                    '接口：${gen.api}',
                    style: const TextStyle(color: moyiBodyOnDark),
                  ),
                Text(
                  '基址：${gen.base}',
                  style: const TextStyle(color: moyiBodyOnDark),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: <Widget>[
                    FilledButton.icon(
                      onPressed: _exportPy,
                      icon: const Icon(Icons.file_download_rounded),
                      label: const Text('导出 py 文件'),
                    ),
                    OutlinedButton.icon(
                      onPressed: (_registering || _registered)
                          ? null
                          : _registerPy,
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: const BorderSide(color: moyiDarkCardBorder),
                      ),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(
                        _registered
                            ? '已注册进站点列表'
                            : _registering
                            ? '注册中…'
                            : '注册进站点列表',
                      ),
                    ),
                  ],
                ),
                if (_registered) ...<Widget>[
                  const SizedBox(height: 8),
                  const Text(
                    '已在站点列表里，可在站源管理里启用、编辑、删除。',
                    style: TextStyle(color: moyiBodyOnDark),
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const SourceManagementPage(),
                        ),
                      );
                    },
                    icon: const Icon(Icons.list),
                    label: const Text('去站源管理查看'),
                  ),
                ],
              ],
            ],
          ),
        ),
      ),
    ];
  }

  List<Widget> _buildLinks(ScrapeResult result) => <Widget>[
    Text(
      '链接（${result.links.length} 条）',
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    const SizedBox(height: 4),
    ...result.links.map(
      (link) => ListTile(
        leading: const Icon(Icons.link_rounded, color: moyiBodyOnDark),
        title: Text(
          link.text.isEmpty ? link.url : link.text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        subtitle: Text(
          link.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: moyiMutedOnDark),
        ),
        trailing: IconButton(
          icon: const Icon(Icons.open_in_new_rounded),
          tooltip: '在浏览器打开',
          color: moyiBodyOnDark,
          onPressed: () => openAppLink(context, link.url),
        ),
        onTap: () => _scrapeUrl(link.url),
      ),
    ),
  ];

  List<Widget> _buildText(ScrapeResult result) => <Widget>[
    if (_mode == ScrapeMode.article && result.imageUrls.isNotEmpty) ...<Widget>[
      ..._buildImages(result),
      const SizedBox(height: 12),
    ],
    SelectableText(
      result.paragraphs.join('\n\n'),
      style: const TextStyle(color: Colors.white, fontSize: 16, height: 1.6),
    ),
  ];

  List<Widget> _buildImages(ScrapeResult result) => <Widget>[
    Text(
      '图片（${result.imageUrls.length} 张）',
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    const SizedBox(height: 8),
    Wrap(
      spacing: 8,
      runSpacing: 8,
      children: result.imageUrls
          .take(12)
          .map(
            (u) => InkWell(
              onTap: () => openAppLink(context, u),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Image.network(
                  u,
                  width: 96,
                  height: 128,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox(
                    width: 96,
                    height: 128,
                    child: Icon(
                      Icons.broken_image_rounded,
                      color: moyiMutedOnDark,
                    ),
                  ),
                ),
              ),
            ),
          )
          .toList(),
    ),
    if (result.imageUrls.length > 12)
      const Padding(
        padding: EdgeInsets.only(top: 8),
        child: Text(
          '仅显示前 12 张，点图片在浏览器打开原图。',
          style: TextStyle(color: moyiBodyOnDark),
        ),
      ),
  ];

  List<Widget> _buildVideos(ScrapeResult result) => <Widget>[
    Text(
      '视频地址（${result.videoUrls.length} 条）',
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: Colors.white,
      ),
    ),
    const SizedBox(height: 4),
    ...result.videoUrls.map(
      (u) => ListTile(
        leading: const Icon(Icons.play_circle_rounded, color: moyiBodyOnDark),
        title: Text(
          u,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: Colors.white),
        ),
        onTap: () => openAppLink(context, u),
      ),
    ),
  ];
}
