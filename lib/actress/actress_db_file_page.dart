import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_adapter_repository.dart';
import 'actress_adapter_store.dart';
import 'actress_db_fields_page.dart';
import 'actress_db_work_detail_page.dart';
import 'actress_generic_db.dart';
import 'video_db_repair.dart';
import 'video_db_normalize.dart';

/// 外来数据库浏览页（2026-11-21 用户令，第二轮修复）：
/// 顶部一级分类瓦片点进来后，这里就是**这个库自己的视频列表**——
/// 先把第一页卡片立刻铺出来（不再等全表 COUNT），再后台补总数；
/// 库内部的多级分类（分类/类型/标签/系列/地区…）按列分组做筛选
/// chips，组内多选取并、跨组取交；点卡片直接播（本地库地址是直链，
/// 不再绕蜘蛛取流）。
///
/// 库文件只读打开、只读不写。认不出作品表时不空白：列出探到的表，
/// 给“数据库字段”手动指定入口。
class ActressDbFilePage extends StatefulWidget {
  const ActressDbFilePage({
    super.key,
    required this.filePath,
    required this.title,
    required this.repository,
    required this.store,
  });

  /// 要浏览的数据库文件绝对路径（只读打开）。
  final String filePath;

  /// 一级分类瓦片上显示的名字（数据库文件名，去后缀）。
  final String title;

  final AppRepository repository;
  final LocalStore store;

  @override
  State<ActressDbFilePage> createState() => _ActressDbFilePageState();
}

class _ActressDbFilePageState extends State<ActressDbFilePage> {
  static const _pageSize = 60;

  Database? _db;
  GenericDbReader? _reader;
  GenericDbSchema? _schema;

  final _works = <GenericDbWork>[];
  final _facets = <GenericDbFacet>[];
  final _selected = <String, Set<String>>{};

  /// 分类下钻路径：一级分类卡片 → 二级分类卡片 → …→ 视频卡片列表。
  /// `value` 为 null 表示这一层点了「全部」，只往下走、不加筛选条件。
  final _path = <({String column, String? value})>[];

  /// 这一步先选了哪个分类维度（分类/类型/标签…）。
  ///
  /// 库里分类维度不止一个时，进库第一屏是「维度卡片墙」——一张卡一个
  /// 维度；点某张才进它的取值卡片（分类卡片墙）。只有一个维度就免这步，
  /// 直接摆分类卡片。
  var _dimension = '';
  /// 分类值自身的层级路径（同一维度内往里钻）。
  ///
  /// 库里的分类值常常自带层级（`日本AV/有码`、`无码/流出`），用户要的是
  /// 「分类卡片 → 子分类卡片 → 视频卡片」这种翻法。所以同一维度内走这张
  /// 前缀链：每点一层往里压一段，面包屑跟着变，返回逐层退。
  final _valuePath = <String>[];

  final _searchController = TextEditingController();
  final _scrollController = ScrollController();

  var _total = -1; // -1 = 还在后台数
  var _loadingFirst = true;

  /// 分类维度还没查出来时先等一会儿（这样一进库就是分类卡片，不会先闪
  /// 一下视频列表）；等太久就先把视频摆出来，别让人对着转圈干等。
  var _facetWaitExpired = false;
  Timer? _facetWaitTimer;
  var _loadingMore = false;
  var _loadingFacets = false;
  var _hasMore = false;
  var _error = '';
  var _query = '';
  String _table = '';
  int _generation = 0;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _searchController.addListener(_onSearchChanged);
    unawaited(_open());
  }

  @override
  void dispose() {
    _generation++;
    _facetWaitTimer?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    final db = _db;
    _db = null;
    if (db != null) {
      // 关掉只读连接：页面退出不占文件句柄（用户可能同时在换库）。
      db.close().catchError((_) {});
    }
    super.dispose();
  }

  Map<String, List<String>> get _filters {
    final out = <String, List<String>>{
      for (final entry in _selected.entries)
        if (entry.value.isNotEmpty) entry.key: entry.value.toList(),
    };
    // 下钻路径上的选择也算筛选；同一列用户在 chips 里手动改过，听用户的。
    for (final step in _path) {
      final value = step.value;
      if (value == null) continue;
      out.putIfAbsent(step.column, () => [value]);
    }
    return out;
  }

  /// 当前正停在哪一层分类卡片上；null = 没有下一层分类，该出视频卡片了。
  GenericDbFacet? get _levelFacet {
    if (_facets.isEmpty || _path.length >= _facets.length) return null;
    // 多维度库还没选维度：先出维度卡片墙，别把第一个维度当唯一分类。
    if (_path.isEmpty && _dimension.isEmpty && _facets.length > 1) {
      return null;
    }
    return _facets[_path.length];
  }

  /// 是否正停在「分类维度卡片墙」这一层。
  bool get _showDimensionWall =>
      _query.isEmpty &&
      _path.isEmpty &&
      _dimension.isEmpty &&
      _facets.length > 1;

  /// 分类卡片层 or 视频卡片层。搜索时直接给视频（搜索不绕分类）。
  bool get _showWorkGrid =>
      _query.isNotEmpty || (!_showDimensionWall && _levelFacet == null);

  /// 点了维度卡片：把这个维度转到队首先看它的取值，再按顺序往下钻。
  void _pickDimension(GenericDbFacet facet) {
    setState(() {
      _dimension = facet.column;
      _valuePath.clear();
      final index = _facets.indexWhere((item) => item.column == facet.column);
      if (index > 0) _facets.insert(0, _facets.removeAt(index));
    });
  }

  void _drillInto(GenericDbFacet facet, String? value) {
    setState(() {
      _path.add((column: facet.column, value: value));
      if (value == null) {
        _selected.remove(facet.column);
      } else {
        _selected[facet.column] = {value};
      }
    });
    _reload();
  }

  /// 用一个「值集合」下钻：分类值带层级时，「本级全部」就是把这一前缀
  /// 下的所有完整值一起选中（前缀含几个分叉就筛几个）。
  void _drillIntoValues(
    GenericDbFacet facet,
    List<String> values,
    String label,
  ) {
    if (values.isEmpty) {
      _drillInto(facet, null);
      return;
    }
    setState(() {
      _path.add((column: facet.column, value: label));
      _selected[facet.column] = values.toSet();
    });
    _reload();
  }

  void _drillBack() {
    // 先在当前维度里退一层子分类。
    if (_valuePath.isNotEmpty) {
      setState(() => _valuePath.removeLast());
      return;
    }
    if (_path.isNotEmpty) {
      setState(() {
        final step = _path.removeLast();
        _selected.remove(step.column);
      });
      _reload();
      return;
    }
    // 已经在分类第一层：退回维度卡片墙（不重新查库）。
    if (_dimension.isNotEmpty) setState(() => _dimension = '');
  }

  void _resetPath() {
    if (_path.isEmpty &&
        _selected.isEmpty &&
        _dimension.isEmpty &&
        _valuePath.isEmpty) {
      return;
    }
    final hadPath = _path.isNotEmpty;
    setState(() {
      _path.clear();
      _selected.clear();
      _dimension = '';
      _valuePath.clear();
    });
    if (hadPath) _reload();
  }

  int get _selectedCount =>
      _selected.values.fold(0, (sum, values) => sum + values.length);

  bool _repairing = false;
  bool _repairCancel = false;

  /// 体检修复当前库：逐条验活播放地址，确认打不开的行删掉，重建演员
  /// 汇总与分类计数。开修前自动备份一份 .bak，修完重开库刷新列表。
  /// 库文件旁边的潮流名册（离线补性别/头像用）：roster_live.json
  /// 或 actors.json，有就解析、没有/解析失败就回 null（走联网取）。
  Future<Map<String, ({String avatar, String sex})>?>
  _localRosterProfiles() async {
    final dir = path.dirname(widget.filePath);
    for (final name in const ['roster_live.json', 'actors.json']) {
      try {
        final file = File(path.join(dir, name));
        if (!await file.exists()) continue;
        final text = await file.readAsString();
        final map = VideoDbNormalizer.parseChaoliuProfiles(text);
        if (map.isNotEmpty) return map;
      } catch (_) {
        // 这个文件读不了就试下一个，没有就回 null。
      }
    }
    return null;
  }

  Future<void> _repairLibrary() async {
    if (_repairing) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('体检修复这个库'),
        content: const Text(
          '一次做两件事：\n\n'
          '一、按女优库结构补齐：缺的表/字段补上，值能对上的先搬到对应字段'
          '（你库里原有的其它字段不动，不删），顺手补女优头像，'
          '库里播放域名判死的换到能通的域名上。\n\n'
          '二、逐条测播放地址：能播的留着，确认打不开的删掉，'
          '测不准的（403、超时、TLS 失败）一律保留，不误删能播的源。\n\n'
          '30 万条的库大约要几十分钟；几 G 的大库更久，'
          '可以随时点中止，已测的部分已经生效。\n\n'
          '开修前会自动存一份 .bak 备份。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('开始修复'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() {
      _repairing = true;
      _repairCancel = false;
    });

    // 先关只读连接，免得写库时被占着。
    final db = _db;
    _db = null;
    try {
      await db?.close();
    } catch (_) {}

    // 备份：没有备份就删行，丢了找不回来。备份没做成直接停下，不修。
    var backupNote = '';
    var backupOk = false;
    try {
      final file = File(widget.filePath);
      if (await file.exists()) {
        // 已有一份 .bak：别用当前库覆盖它——当前库可能已经是上一轮
        // 修坏的，覆盖就丢了最后一份好备份；另存一份带时间的。
        var backupPath = '${widget.filePath}.bak';
        if (await File(backupPath).exists()) {
          backupPath =
              '${widget.filePath}.bak.${DateTime.now().millisecondsSinceEpoch}';
        }
        await file.copy(backupPath);
        backupNote = '已备份到 ${path.basename(backupPath)}';
        backupOk = true;
      }
    } catch (_) {
      backupOk = false;
    }
    if (!backupOk) {
      if (!mounted) return;
      setState(() => _repairing = false);
      await showDialog<void>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('备份没做成，修复已停下'),
          content: const Text(
            '备份文件没存下来（可能空间不够），库没动。\n\n'
            '体检修复会删确认打不开的行，没有备份不能修：'
            '先清出空间再点修复。',
          ),
          actions: [
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }

    if (!mounted) return;
    final progress = ValueNotifier<String>('正在读库…');
    final navigator = Navigator.of(context, rootNavigator: true);
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (context) => AlertDialog(
          title: const Text('正在体检'),
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (context, value, _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const LinearProgressIndicator(minHeight: 4),
                const SizedBox(height: 14),
                Text(value),
                const SizedBox(height: 6),
                Text(
                  '测不准的地址不会删，只删确认打不开的',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => _repairCancel = true,
              child: const Text('中止'),
            ),
          ],
        ),
      ),
    );

    VideoDbRepairReport? report;
    VideoDbNormalizeReport? normalize;
    var normalizeError = '';
    var error = '';
    try {
      // 第一步：结构对齐 + 头像 + 域名（快，几十秒）。
      progress.value = '按女优库结构整理…';
      // 2026-11-23：名册是性别的权威——库旁边放了潮流名册
      // （roster_live.json / actors.json）就用它离线补性别/头像，
      // 不用再联网取；没放就走原来的联网取（取不到跳过这步）。
      final rosterProfiles = await _localRosterProfiles();
      try {
        normalize = await VideoDbNormalizer.run(
          widget.filePath,
          schema: _schema,
          profiles: rosterProfiles,
          onStage: (stage) => progress.value = stage,
        );
      } catch (e) {
        normalizeError = e.toString();
      }
      if (_repairCancel) throw StateError('已中止');
      // 第二步：逐条验播放地址（慢）。
      report = await VideoDbRepair.run(
        widget.filePath,
        onProgress: (done, total) {
          progress.value = total > 0
              ? '已测 $done / $total（${(done * 100 / total).toStringAsFixed(0)}%）'
              : '已测 $done';
        },
        cancelled: () => _repairCancel,
      );
    } catch (e) {
      error = e.toString();
    } finally {
      progress.dispose();
      if (mounted) navigator.pop();
    }

    if (!mounted) return;
    setState(() => _repairing = false);
    await _open();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(error.isEmpty ? '体检修复完成' : '修复没做成'),
        content: Text(
          error.isEmpty
              ? [
                  if (normalize != null) '结构：${normalize.summary}',
                  if (normalize != null && normalize.hostFixes.isNotEmpty)
                    '换掉的域名：${normalize.hostFixes.entries.map((e) => '${e.key} → ${e.value}').join('；')}',
                  if (normalize != null && normalize.deadHosts.isNotEmpty)
                    '判死的域名：${normalize.deadHosts.join('、')}',
                  if (normalize != null)
                    for (final note in normalize.notes.take(3)) '· $note',
                  if (normalizeError.isNotEmpty) '结构整理没做成：$normalizeError',
                  if (report != null) report.summary,
                  if (report?.cancelled ?? false) '（中途中止，已测的部分已生效）',
                  if (report?.rollupSkipped ?? false)
                    '大库跳过了演员汇总重建，进女优库时它会自己重算。',
                  if (backupNote.isNotEmpty) backupNote,
                  '修复只删确认打不开的行，测不准的都保留。',
                ].join('\n')
              : '$error\n\n${normalize != null ? '结构：${normalize.summary}\n' : ''}$backupNote',
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _open() async {
    final generation = ++_generation;
    setState(() {
      _loadingFirst = true;
      _error = '';
    });
    try {
      if (!File(widget.filePath).existsSync()) {
        setState(() {
          _loadingFirst = false;
          _error = '库文件不在了：${path.basename(widget.filePath)}';
        });
        return;
      }
      // 2026-11-23：先给这个库补索引（只加索引，不动行；后台跑不堵读）。
      // 全球丽影库就是在这里 25 秒超时报“读这个库太慢”——videos 表
      // 除主键外没有索引，首屏 ORDER BY/LIKE 全是全表扫；补上后
      // 下次打开直接走索引。
      unawaited(ensureVideoDbIndexes(widget.filePath));
      // 2026-11-24 掉线修复：探库独立连接，关完不拖主库的共享连接掉线。
      final db = await openDatabase(
        widget.filePath,
        readOnly: true,
        singleInstance: false,
      ).timeout(
        const Duration(seconds: 15),
        onTimeout: () => throw TimeoutException('打开库超时'),
      );
      if (!mounted || generation != _generation) {
        await db.close();
        return;
      }
      final schema = await probeGenericDbSchema(db).timeout(
        const Duration(seconds: 25),
        onTimeout: () => throw TimeoutException('读库结构超时'),
      );
      final reader = GenericDbReader(
        db: db,
        schema: schema,
        mappingStore: GenericDbMappingStore(
          file: File(path.join(path.dirname(widget.filePath), '字段映射.json')),
        ),
      );
      if (!mounted || generation != _generation) {
        await db.close();
        return;
      }
      _db = db;
      _reader = reader;
      _schema = schema;
      _table = schema.worksTable?.table ?? '';
      _facetWaitExpired = false;
      _facetWaitTimer?.cancel();
      _facetWaitTimer = Timer(const Duration(seconds: 6), () {
        if (mounted) setState(() => _facetWaitExpired = true);
      });
      if (schema.worksTable == null) {
        // 认不出作品表：不空白，进诊断态（列已探到的表 + 手动指定入口）。
        setState(() => _loadingFirst = false);
        return;
      }
      await _loadFirst(generation);
      unawaited(_loadTotalAndFacets(generation));
    } on TimeoutException {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '这个库打开/读结构太慢，先退回去了。它可能太大或正被别的程序占用，\n'
            '过一会儿再点一次，或者把库文件名告诉我换个读法。';
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '打不开这个库：$error';
      });
    }
  }

  /// 第一页：只查作品，不等 COUNT（大库 COUNT 很慢，等它就白屏）。
  Future<void> _loadFirst(int generation) async {
    final reader = _reader;
    if (reader == null) return;
    setState(() {
      _loadingFirst = true;
      _error = '';
      _works.clear();
      _hasMore = true;
      _total = -1;
    });
    try {
      final works = await reader.works(
        offset: 0,
        limit: _pageSize,
        query: _query,
        filters: _filters,
      ).timeout(const Duration(seconds: 25));
      if (!mounted || generation != _generation) return;
      setState(() {
        _works
          ..clear()
          ..addAll(works);
        _hasMore = works.length >= _pageSize;
        _loadingFirst = false;
      });
    } on TimeoutException {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '读这个库太慢（可能是大库没索引），换个筛选或稍后再试。';
      });
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loadingFirst = false;
        _error = '读库失败：$error';
      });
    }
  }

  /// 后台补总数与分类维度（不阻塞首屏）。
  ///
  /// [refreshFacets] 为 false 时沿用已查到的分类维度：分类是整库统计，
  /// 下钻/翻页不会改变它，重查一次大库要白扫几遍全表。
  Future<void> _loadTotalAndFacets(
    int generation, {
    bool refreshFacets = true,
  }) async {
    final reader = _reader;
    if (reader == null) return;
    if (refreshFacets) setState(() => _loadingFacets = true);
    if (!refreshFacets && _facets.isNotEmpty) {
      unawaited(_refreshTotal(generation, reader));
      return;
    }
    // 分类先查：大库 COUNT 可能慢几十秒，等它会把分类条一起拖住，
    // 用户看到的就是「点进来没有分类」。
    try {
      // 分类维度逐列查（副表维度在前），大库上可能几秒到十几秒；
      // 给足时间，别一超时就把整批分类丢掉（那正是「读不到分类」）。
      final facets = await reader
          .facets(maxValues: 200)
          .timeout(const Duration(seconds: 90));
      if (!mounted || generation != _generation) return;
      setState(() {
        _facets
          ..clear()
          ..addAll(facets);
        _loadingFacets = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingFacets = false);
    }
    await _refreshTotal(generation, reader);
  }

  Future<void> _refreshTotal(int generation, GenericDbReader reader) async {
    try {
      final total = await reader.countWorks(
        query: _query,
        filters: _filters,
      ).timeout(const Duration(seconds: 60));
      if (!mounted || generation != _generation) return;
      setState(() => _total = total);
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _total = _works.length);
    }
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 400) {
      unawaited(_loadMore());
    }
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    if (query == _query) return;
    _query = query;
    _reload();
  }

  void _reload({bool refreshFacets = false}) {
    final generation = ++_generation;
    unawaited(_loadFirst(generation));
    unawaited(_loadTotalAndFacets(generation, refreshFacets: refreshFacets));
  }

  Future<void> _loadMore() async {
    final reader = _reader;
    if (reader == null || _loadingMore || !_hasMore || _loadingFirst) return;
    final generation = _generation;
    setState(() => _loadingMore = true);
    try {
      final works = await reader.works(
        offset: _works.length,
        limit: _pageSize,
        query: _query,
        filters: _filters,
      );
      if (!mounted || generation != _generation) return;
      setState(() {
        _works.addAll(works);
        _hasMore = works.length >= _pageSize;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() => _loadingMore = false);
    }
  }

  /// 点视频卡片进详情页（详情页里再播放）。
  Future<void> _openWork(GenericDbWork work) async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ActressDbWorkDetailPage(
          work: work,
          repository: widget.repository,
          store: widget.store,
        ),
      ),
    );
  }

  Future<void> _openFieldPage() async {
    final reader = _reader;
    if (reader == null) return;
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ActressDbFieldsPage(reader: reader)),
    );
    if (changed == true && mounted) {
      setState(() {
        _schema = reader.schema;
        _table = reader.schema.worksTable?.table ?? '';
        _selected.clear();
        _path.clear();
      });
      _reload(refreshFacets: true);
    }
  }

  Future<void> _pickFacet(GenericDbFacet facet) async {
    final selected = {...?_selected[facet.column]};
    final applied = await showModalBottomSheet<Set<String>>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _FacetSheet(
        facet: facet,
        selected: selected,
      ),
    );
    if (applied == null || !mounted) return;
    setState(() {
      if (applied.isEmpty) {
        _selected.remove(facet.column);
      } else {
        _selected[facet.column] = applied;
      }
    });
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(widget.title, maxLines: 1, overflow: TextOverflow.ellipsis),
            Text(
              _subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 11, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          if (_reader != null && _schema?.worksTable != null)
            IconButton(
              tooltip: '数据库字段',
              icon: const Icon(Icons.tune_rounded),
              onPressed: _openFieldPage,
            ),
          IconButton(
            key: const ValueKey('actress-db-repair'),
            tooltip: '体检修复这个库',
            icon: _repairing
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.healing_rounded),
            onPressed: _repairing ? null : () => unawaited(_repairLibrary()),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
            child: TextField(
              key: const ValueKey('actress-db-file-search'),
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜标题或番号',
                prefixIcon: const Icon(Icons.search_rounded),
                suffixIcon: _query.isEmpty
                    ? null
                    : IconButton(
                        tooltip: '清除搜索',
                        icon: const Icon(Icons.clear_rounded),
                        onPressed: () => _searchController.clear(),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ),
          if (_showWorkGrid && (_facets.isNotEmpty || _selectedCount > 0))
            _buildFacetBar(colors),
          if (_showWorkGrid &&
              _facets.isEmpty &&
              !_loadingFacets &&
              !_loadingFirst &&
              _error.isEmpty &&
              _works.isNotEmpty)
            _buildNoFacetHint(colors),
          Expanded(child: _body(colors)),
        ],
      ),
    );
  }

  String get _subtitle {
    if (_schema == null) return '外来数据库';
    if (_schema!.worksTable == null) return '外来数据库 · 认不出作品表';
    final parts = <String>[
      '表 $_table',
      _total >= 0 ? '$_total 条' : '读取中…',
      if (_selectedCount > 0) '筛选 $_selectedCount 项',
    ];
    return parts.join(' · ');
  }

  /// 分类筛选条：每个维度一个 chip（列名 + 已选数），点开多选。
  Widget _buildFacetBar(ColorScheme colors) {
    return SizedBox(
      height: 42,
      child: ListView(
        key: const ValueKey('actress-db-file-facets'),
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          for (final facet in _facets)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: FilterChip(
                key: ValueKey('db-facet-${facet.column}'),
                label: Text(
                  _selected[facet.column]?.isNotEmpty == true
                      ? '${_facetLabel(facet.column)} '
                          '${_selected[facet.column]!.length}'
                      : _facetLabel(facet.column),
                  style: const TextStyle(fontSize: 12),
                ),
                selected: _selected[facet.column]?.isNotEmpty == true,
                onSelected: (_) => _pickFacet(facet),
              ),
            ),
          if (_loadingFacets)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8, vertical: 10),
              child: SizedBox.square(
                dimension: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          if (_selectedCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                key: const ValueKey('db-facet-clear'),
                avatar: const Icon(Icons.clear_rounded, size: 14),
                label: const Text('清除筛选', style: TextStyle(fontSize: 12)),
                onPressed: () {
                  setState(() => _selected.clear());
                  _reload();
                },
              ),
            ),
        ],
      ),
    );
  }

  /// 列名转人话（库里字段名多是英文）。副表维度的 key 是
  /// `表.列`（如 video_category.main_category），只拿列名去转，
  /// 给用户看库表名没意义。
  String _facetLabel(String column) => facetDisplayLabel(column);

  /// 一个分类维度都没认出来时的提示条（不静默空白：告诉用户在哪儿
  /// 手动指定，或者这个库本身就没有分类列）。
  Widget _buildNoFacetHint(ColorScheme colors) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
      child: Row(
        children: [
          Icon(Icons.filter_alt_off_outlined, size: 15,
              color: colors.onSurfaceVariant),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '这个库里没认出分类列，点右上角「数据库字段」指定一下',
              style: TextStyle(fontSize: 11.5, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _body(ColorScheme colors) {
    if (_loadingFirst) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error.isNotEmpty) {
      return _message(
        colors,
        _error,
        actions: [
          FilledButton(
            onPressed: () => unawaited(_open()),
            child: const Text('重试'),
          ),
          if (_reader != null)
            OutlinedButton(
              onPressed: _openFieldPage,
              child: const Text('数据库字段'),
            ),
        ],
      );
    }
    final schema = _schema;
    if (schema != null && schema.worksTable == null) {
      return _buildSchemaHelp(colors, schema);
    }
    // 分类卡片优先：搜过词就直接出视频（搜索不绕分类）。
    if (_showDimensionWall) return _buildDimensionCards(colors);
    final facet = _query.isEmpty ? _levelFacet : null;
    if (facet != null) return _buildFacetCards(colors, facet);
    if (_works.isEmpty &&
        _loadingFacets &&
        !_facetWaitExpired &&
        _query.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_works.isEmpty) {
      return _message(
        colors,
        _query.isNotEmpty || _selectedCount > 0
            ? '当前条件下没有作品'
            : '这个库里没有作品',
      );
    }
    return GridView.builder(
      key: const ValueKey('actress-db-file-grid'),
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 160,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 0.58,
      ),
      itemCount: _works.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _works.length) {
          return const Center(
            child: SizedBox.square(
              dimension: 22,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final work = _works[index];
        return _DbWorkCard(
          key: ValueKey('db-work-${work.id ?? work.title}'),
          work: work,
          onTap: () => unawaited(_openWork(work)),
        );
      },
    );
  }

  /// 分类维度卡片墙：一个维度一张卡（分类 / 类型 / 标签 / 系列…），
  /// 点一张进这个维度的取值卡片。库里有几个分类列就摆几张，不漏维度。
  Widget _buildDimensionCards(ColorScheme colors) {
    final facets = _facets;
    return CustomScrollView(
      key: const ValueKey('db-dimension-wall'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 8, 14, 6),
            child: Text(
              '选一个分类维度',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.74,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                final facet = facets[index];
                final total =
                    facet.values.fold<int>(0, (sum, v) => sum + v.count);
                return _DbFacetCard(
                  key: ValueKey('db-dimension-card-${facet.column}'),
                  label: facetDisplayLabel(facet.column),
                  subtitle: '${facet.values.length} 类 · $total 部',
                  coverUrl:
                      facet.values.isEmpty ? '' : facet.values.first.coverUrl,
                  onTap: () => _pickDimension(facet),
                );
              },
              childCount: facets.length,
            ),
          ),
        ),
      ],
    );
  }

  /// 分类层：一个维度的取值铺成卡片墙（封面 + 名字 + 数量），
  /// 点一张进下一层；最后一层之后才是视频卡片列表。
  ///
  /// 分类值自带层级时（`日本AV/有码`），同一维度内再拆成「子分类卡片
  /// 墙」：点中间层继续往里，点叶子才进视频卡片列表。
  Widget _buildFacetCards(ColorScheme colors, GenericDbFacet facet) {
    final separator = _valueSeparator(facet);
    final prefix = _valuePath.join(separator);
    final children = separator.isEmpty
        ? [
            for (final item in facet.values)
              _FacetChild(
                label: item.value,
                full: item.value,
                count: item.count,
                coverUrl: item.coverUrl,
                drillable: false,
              ),
          ]
        : _childFacets(facet, separator, prefix);
    final shownTotal = children.fold<int>(0, (sum, item) => sum + item.count);
    return CustomScrollView(
      key: ValueKey(
        'db-facet-level-${_path.length}-${facet.column}-${_valuePath.length}',
      ),
      slivers: [
        SliverToBoxAdapter(child: _buildCrumb(colors, facet)),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(12, 2, 12, 16),
          sliver: SliverGrid(
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 150,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.74,
            ),
            delegate: SliverChildBuilderDelegate(
              (context, index) {
                if (index == 0) {
                  final cover = children.isEmpty ? '' : children.first.coverUrl;
                  // 还没进子层：这张是「全部」，跳过这个维度直接往下走。
                  if (_valuePath.isEmpty) {
                    return _DbFacetCard(
                      key: const ValueKey('db-facet-all'),
                      label: '全部',
                      subtitle: '$shownTotal 部',
                      coverUrl: cover,
                      onTap: () => _drillInto(facet, null),
                    );
                  }
                  // 进了子层：这张是「本级全部」，看这一前缀下的所有作品。
                  final values = _prefixValues(facet, separator, prefix);
                  return _DbFacetCard(
                    key: const ValueKey('db-facet-here'),
                    label: '本级全部',
                    subtitle: '$shownTotal 部',
                    coverUrl: cover,
                    onTap: () => _drillIntoValues(
                      facet,
                      values,
                      _valuePath.join(separator),
                    ),
                  );
                }
                final child = children[index - 1];
                return _DbFacetCard(
                  key: ValueKey('db-facet-card-${child.full}'),
                  label: child.label,
                  subtitle: child.drillable
                      ? '${child.count} 部 · 有子类'
                      : '${child.count} 部',
                  coverUrl: child.coverUrl,
                  onTap: () {
                    if (child.drillable) {
                      setState(() => _valuePath.add(child.label));
                    } else {
                      _drillInto(facet, child.full);
                    }
                  },
                );
              },
              childCount: children.length + 1,
            ),
          ),
        ),
      ],
    );
  }

  /// 分类值里的层级分隔符。判不出来（比例太低）返回空串——那就按原来的
  /// 平铺摆卡片，不乱拆。
  String _valueSeparator(GenericDbFacet facet) {
    final values = facet.values;
    if (values.length < 4) return '';
    for (final separator in const ['/', '>', '|', ' - ']) {
      var hit = 0;
      for (final item in values) {
        if (item.value.contains(separator)) hit++;
      }
      if (hit >= 2 && hit * 100 ~/ values.length >= 25) return separator;
    }
    return '';
  }

  /// 把这一维的值按 [prefix] 投影成下一层卡片（一个子分类一张）。
  List<_FacetChild> _childFacets(
    GenericDbFacet facet,
    String separator,
    String prefix,
  ) {
    final out = <String, _FacetChild>{};
    for (final item in facet.values) {
      final text = item.value;
      if (prefix.isNotEmpty) {
        if (text == prefix) continue; // 本级自身已经在上一层点过
        if (!text.startsWith('$prefix$separator')) continue;
      }
      final rest = prefix.isEmpty
          ? text
          : text.substring(prefix.length + separator.length);
      if (rest.isEmpty) continue;
      final cut = rest.indexOf(separator);
      final segment = cut < 0 ? rest : rest.substring(0, cut);
      final full = prefix.isEmpty ? segment : '$prefix$separator$segment';
      final previous = out[full];
      out[full] = _FacetChild(
        label: segment,
        full: full,
        count: (previous?.count ?? 0) + item.count,
        coverUrl: (previous != null && previous.coverUrl.isNotEmpty)
            ? previous.coverUrl
            : item.coverUrl,
        drillable: cut >= 0 || (previous?.drillable ?? false),
      );
    }
    final list = out.values.toList()
      ..sort((a, b) => b.count.compareTo(a.count));
    return list;
  }

  /// 某个前缀下的全部完整值（「本级全部」按这些值一起筛）。
  List<String> _prefixValues(
    GenericDbFacet facet,
    String separator,
    String prefix,
  ) {
    if (prefix.isEmpty) {
      return [for (final item in facet.values) item.value];
    }
    final head = '$prefix$separator';
    return [
      for (final item in facet.values)
        if (item.value == prefix || item.value.startsWith(head)) item.value,
    ];
  }

  /// 分类层顶部一条：返回上一级 + 现在看的是哪一维。
  Widget _buildCrumb(ColorScheme colors, GenericDbFacet facet) {
    final trail = <String>[
      for (var index = 0; index < _path.length; index++)
        if (index == _path.length - 1 && _valuePath.isNotEmpty)
          '${facetDisplayLabel(_path[index].column)}·'
              '${_valuePath.join('·')}'
        else
          '${facetDisplayLabel(_path[index].column)}·'
              '${_path[index].value ?? '全部'}',
    ];
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
        children: [
          if (_path.isNotEmpty || _dimension.isNotEmpty || _valuePath.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                key: const ValueKey('db-facet-back'),
                avatar: const Icon(Icons.arrow_back_rounded, size: 14),
                label: const Text('返回', style: TextStyle(fontSize: 12)),
                onPressed: _drillBack,
              ),
            ),
          if (trail.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: ActionChip(
                avatar: const Icon(Icons.home_outlined, size: 14),
                label: Text(
                  trail.join(' / '),
                  style: const TextStyle(fontSize: 12),
                ),
                onPressed: _resetPath,
              ),
            ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 10),
            child: Text(
              '${facetDisplayLabel(facet.column)} · ${facet.values.length} 个',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }

  Widget _message(
    ColorScheme colors,
    String text, {
    List<Widget> actions = const [],
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(height: 14),
              Wrap(spacing: 10, children: actions),
            ],
          ],
        ),
      ),
    );
  }

  /// 认不出作品表时的诊断：把探到的表和字段摆出来，让用户能手动
  /// 指定（不然只报一句“认不出”，用户无从下手）。
  Widget _buildSchemaHelp(ColorScheme colors, GenericDbSchema schema) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          '这个库的表结构没自动认出来。下面是库里探到的表，'
          '点“数据库字段”手动指定哪个是标题、哪个是播放地址。',
          style: TextStyle(color: colors.onSurfaceVariant, height: 1.5),
        ),
        const SizedBox(height: 12),
        for (final table in schema.tables)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: ListTile(
              dense: true,
              title: Text(table.table),
              subtitle: Text(
                table.allColumns.take(12).join('、') +
                    (table.allColumns.length > 12 ? ' …' : ''),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: Text('${table.allColumns.length} 列'),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _openFieldPage,
          icon: const Icon(Icons.tune_rounded),
          label: const Text('数据库字段'),
        ),
      ],
    );
  }
}

/// 分类维度 key 转人话：`video_category.main_category` 这种带表名的
/// key 只取最后一段列名；列名里的英文按常见对应关系翻译。
String facetDisplayLabel(String column) {
  final dot = column.lastIndexOf('.');
  final name = dot >= 0 ? column.substring(dot + 1) : column;
  final lower = name.toLowerCase();
  const map = {
    'category': '分类',
    'main_category': '分类',
    'type': '类型',
    'class': '分类',
    'genre': '题材',
    'tag': '标签',
    'tags': '标签',
    'series': '系列',
    'area': '地区',
    'kind': '种类',
    'group': '分组',
    'theme': '主题',
    'studio': '片商',
  };
  for (final entry in map.entries) {
    if (lower.contains(entry.key)) return entry.value;
  }
  return name;
}

/// 一个分类维度的多选面板：组内多选取并（勾几个都算）。
class _FacetSheet extends StatefulWidget {
  const _FacetSheet({required this.facet, required this.selected});

  final GenericDbFacet facet;
  final Set<String> selected;

  @override
  State<_FacetSheet> createState() => _FacetSheetState();
}

class _FacetSheetState extends State<_FacetSheet> {
  late final _picked = {...widget.selected};

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(context).size.height * 0.7,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      facetDisplayLabel(widget.facet.column),
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  if (_picked.isNotEmpty)
                    TextButton(
                      onPressed: () => setState(_picked.clear),
                      child: const Text('清空'),
                    ),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.facet.values.length,
                itemBuilder: (context, index) {
                  final value = widget.facet.values[index];
                  final checked = _picked.contains(value.value);
                  return CheckboxListTile(
                    dense: true,
                    value: checked,
                    title: Text(
                      value.value,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13),
                    ),
                    secondary: Text(
                      '${value.count}',
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    onChanged: (next) => setState(() {
                      if (next == true) {
                        _picked.add(value.value);
                      } else {
                        _picked.remove(value.value);
                      }
                    }),
                  );
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(_picked),
                  child: Text(
                    _picked.isEmpty ? '不筛选' : '应用（${_picked.length} 项）',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 外来库作品卡：封面 + 标题 + 副标题（番号/女优/日期），点卡直播。
class _DbWorkCard extends StatelessWidget {
  const _DbWorkCard({super.key, required this.work, required this.onTap});

  final GenericDbWork work;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final subtitle = [
      if (work.code.isNotEmpty) work.code,
      if (work.actress.isNotEmpty) work.actress,
      if (work.date.isNotEmpty) work.date,
    ].join(' · ');
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: ColoredBox(
                color: colors.surfaceContainerHighest,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (work.coverUrl.isEmpty)
                      Center(
                        child: Icon(
                          Icons.movie_outlined,
                          color: colors.onSurfaceVariant,
                        ),
                      )
                    else
                      Image.network(
                        work.coverUrl,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Center(
                          child: Icon(
                            Icons.broken_image_outlined,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      ),
                    if (!work.playable)
                      Positioned(
                        left: 4,
                        bottom: 4,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 4,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: const Text(
                            '无地址',
                            style: TextStyle(
                              fontSize: 9,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            work.title.isEmpty
                ? (work.code.isEmpty ? '未命名' : work.code)
                : work.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, height: 1.25),
          ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }
}


/// 分类层里的一张卡片：可能是一个子分类（还能往里钻），也可能就是
/// 最终取值（点它直接进视频卡片列表）。
class _FacetChild {
  const _FacetChild({
    required this.label,
    required this.full,
    required this.count,
    required this.coverUrl,
    required this.drillable,
  });

  /// 这一层显示的名字（不含上层前缀）。
  final String label;

  /// 完整取值（带前缀），进视频列表时按它筛。
  final String full;

  final int count;
  final String coverUrl;

  /// 底下还有更深一层，点它进子分类卡片墙而不是视频列表。
  final bool drillable;
}

/// 分类卡片：用这一分类下首部作品的封面当背景，名字 + 数量压在底部。
/// 取不到封面就退成色块 + 名字，不留白块。
class _DbFacetCard extends StatelessWidget {
  const _DbFacetCard({
    super.key,
    required this.label,
    required this.subtitle,
    required this.coverUrl,
    required this.onTap,
  });

  final String label;
  final String subtitle;
  final String coverUrl;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: ColoredBox(
          color: colors.surfaceContainerHighest,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (coverUrl.isNotEmpty)
                Image.network(
                  coverUrl,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                ),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.transparent, Colors.black87],
                  ),
                ),
              ),
              Positioned(
                left: 8,
                right: 8,
                bottom: 8,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        height: 1.2,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10.5,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
