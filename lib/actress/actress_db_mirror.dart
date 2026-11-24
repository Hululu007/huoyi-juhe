import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as path;
import 'package:sqflite/sqflite.dart';

import 'actress_database.dart';
import 'actress_generic_db.dart';
import 'actress_models.dart';

/// 数据库镜像（2026-11-20 用户令“读取数据库要把作品数量递增
/// 追加上去”）：读主目录（MYTV/db）与补充目录（py 的涩库引擎
/// SikuEngine.DB_DIRS 同款：纯福利/db、女优库、私藏视频、
/// lz/db，2026-11-21 用户令按 py 逻辑读库、改路径）里除当前库
/// 文件之外的其他 .db 文件，把里面的作品按合并规则递增追加进
/// 女优库。主目录只扫一层，补充目录递归扫（与 py 的 os.walk
/// 一致）；收集逻辑见 [collectDbMirrorTargets]。
///
/// 口径调和（写进 REPORT，用户另有说法以用户为准）：当前库文件
/// 本身（MYTV/db/女优库.db）走替换语义——读它只是显示，不写；
/// 追加只针对 MYTV/db 里除当前库文件之外的其他 .db 文件（通用
/// 读库令已确认会有）。所以 [ActressDbMirror.mirrorFile] 遇到
/// 与当前库同一文件时直接跳过，只读不写。
///
/// 合并规则（与 2026-11-19 爬取规则、2026-11-20 两站合并新规
/// 同一口径）：番号 + 播放链接都相同才跳过，任一不同就更新替换；
/// 作品叠加不去重（同番号换站各留一条）；同名女优归一化合并，
/// 没有的新增；分批追加（默认每批 200 条），不覆盖已有作品，
/// 重读不重复加；追加失败不崩、不丢已有数据。
///
/// 源文件只读打开，不动源文件；女优库结构走 persons + works
/// 直读，外来结构走通用读库层（[probeGenericDbSchema] +
/// [GenericDbReader]）。通用作品的播放地址进 works.cover_drama_id、
/// cover_source 记 'chaoliu'，与通用层 toJsonEntry 的 parse=0
/// 直通同一招，播放时按现取的地址播。

/// 镜像的一条作品（中性行结构：与源库结构无关，两种源都先转
/// 成它再合并；单元测试直接喂它，用 [MemoryActressDatabase] 测）。
class ActressDbMirrorWork {
  const ActressDbMirrorWork({
    required this.actress,
    this.title = '',
    this.code = '',
    this.date = '',
    this.category = '',
    this.coverUrl = '',
    this.playUrl = '',
    this.site = '',
    this.coverSource = '',
  });

  /// 通用读库行转镜像行：站记 'chaoliu'（通用播放直通站），
  /// 封面来源站同记 'chaoliu'。
  factory ActressDbMirrorWork.fromGenericWork(GenericDbWork work) {
    return ActressDbMirrorWork(
      actress: work.actress,
      title: work.title,
      code: work.code,
      date: work.date,
      category: work.category,
      coverUrl: work.coverUrl,
      playUrl: work.playUrl,
      site: 'chaoliu',
      coverSource: 'chaoliu',
    );
  }

  /// 女优（归一化后合并用）；为空的行不进库。
  final String actress;

  final String title;

  /// 原始番号文本（可能为空，无番号的作品按标题去重）。
  final String code;

  final String date;
  final String category;
  final String coverUrl;

  /// 播放地址：女优库结构源是 cover_drama_id 存的值，通用源是
  /// 提取出的播放地址。进库后写 works.cover_drama_id。
  final String playUrl;

  /// 去重键里的站：女优库结构源保留原站，通用源为 'chaoliu'。
  final String site;

  /// 封面来源站：女优库结构源保留原 cover_source，通用源为
  /// 'chaoliu'；没有封面时为空（有播放地址的条目也不认站源）。
  final String coverSource;
}

/// 一次镜像的结果（appended/updated/skipped/failed 四数之和
/// 等于处理过的行数；[error] 非空表示整批中途失败，已处理的部分
/// 仍有效，不回滚）。
class ActressDbMirrorResult {
  const ActressDbMirrorResult({
    this.appended = 0,
    this.updated = 0,
    this.skipped = 0,
    this.failed = 0,
    this.total = 0,
    this.alreadyDone = false,
    this.error,
    this.note,
  });

  final int appended;
  final int updated;
  final int skipped;
  final int failed;

  /// 源文件里的作品总行数（0 表示没数出来或文件为空）。
  final int total;

  /// true = 该文件（指纹未变）已镜像过，本次跳过。
  final bool alreadyDone;
  final String? error;
  final String? note;
}

/// 批量合并（可测核心）：把 [works] 按合并规则写进 [library]。
/// 每人先按名字归一化合并（[ActressDatabase.upsertCrawledPerson]），
/// 再按（人，站，番号键/标题键）比对已有行：没有则新建，有且
/// 播放链接相同则跳过，有且链接不同则更新替换。单条失败只记
/// failed 不抛错；整批失败记 error 返回，不回滚已写部分。
/// [onProgress] 每处理完一条调一次（done 从 1 开始）。
/// [existingPlayUrls] 跨批复用：同一文件内各批共用（personId ->
/// 去重键 -> 已存播放地址），避免每批每人重读全部已有作品
/// （323798 行时每批重读是 O(n^2)，手机上几小时跑不完）。
/// 调用方（[ActressDbMirror.mirrorFile]）每文件建一个；不传时
/// 每批现读（老行为，单测用）。
Future<ActressDbMirrorResult> mirrorWorks({
  required ActressDatabase library,
  required List<ActressDbMirrorWork> works,
  void Function(int done, int total)? onProgress,
  Map<int, Map<String, String>>? existingPlayUrls,
}) async {
  var appended = 0;
  var updated = 0;
  var skipped = 0;
  var failed = 0;
  String? error;
  try {
    // 按女优名分组：同一批里同一个人只建/合一次，之后复用。
    final byPerson = <String, List<ActressDbMirrorWork>>{};
    for (final work in works) {
      final name = work.actress.trim();
      if (name.isEmpty) {
        // 没女优名的行不进库（与 json 镜像同一口径）。
        skipped++;
        continue;
      }
      (byPerson[name] ??= []).add(work);
    }
    var done = skipped;
    for (final entry in byPerson.entries) {
      final name = entry.key;
      final personWorks = entry.value;
      try {
        if (actressTextBlocked(name)) {
          skipped += personWorks.length;
          done += personWorks.length;
          onProgress?.call(done, works.length);
          continue;
        }
        final person = await library.upsertCrawledPerson(name: name);
        if (person == null) {
          skipped += personWorks.length;
          done += personWorks.length;
          onProgress?.call(done, works.length);
          continue;
        }
        // 该人已有作品的去重键 -> 已存播放地址（只存地址串，不存
        // 整行，323798 行时缓存也不会太大）。跨批复用时直接取缓存
        // （同文件内前面批次已写的新行也在缓存里）；否则现读一次
        // （上限 10 万行，超了按“没有”处理，upsertWorks 的冲突
        // 丢弃会兜住，不会重复建行）。
        final useCache = existingPlayUrls != null;
        Map<String, String> existing;
        if (useCache && existingPlayUrls.containsKey(person.localId)) {
          existing = existingPlayUrls[person.localId]!;
        } else {
          existing = <String, String>{};
          try {
            final rows = await library.worksForPerson(
              person.localId,
              offset: 0,
              limit: 100000,
            );
            for (final row in rows) {
              final key = row.codeKey.isNotEmpty
                  ? '${row.site}|code:${row.codeKey}'
                  : '${row.site}|title:${row.titleKey}';
              existing[key] = row.coverDramaId;
            }
          } catch (_) {
            // 读已有行失败：当作空库继续，新行由 upsertWorks 的
            // 冲突丢弃兜住，不会重复建行。
          }
          if (useCache) existingPlayUrls[person.localId] = existing;
        }
        // 批量写：同一个人先收齐再一次写（每批 200 行时逐条写每条
        // 一个事务、每次提交都要落盘，约 95ms/条，323798 行要几
        // 小时；批量后新建按组各一次事务、更新一次事务，约
        // 0.9ms/条）。新建按（站，封面来源）分组调 upsertWorks
        // （它本身一次调用就是一个事务）；更新走批量
        // updateWorkPlayLinks。计数口径与逐条时一字不差：新建
        // 成功记 appended、更新成功记 updated、没找到记 failed、
        // 补地址的返回值不计。
        final toInsert = <(String, String), List<(RosterFilm, String)>>{};
        final toUpdate = <(WorkPlayLinkUpdate, bool, String)>[];
        for (final work in personWorks) {
          done++;
          try {
            final codeKey = normalizeAvCode(work.code);
            final titleKey = actressTitleKey(
              work.title.isEmpty ? work.code : work.title,
            );
            if (codeKey.isEmpty && titleKey.isEmpty) {
              skipped++;
              onProgress?.call(done, works.length);
              continue;
            }
            if (actressTextBlocked(work.code) ||
                actressTextBlocked(work.title)) {
              skipped++;
              onProgress?.call(done, works.length);
              continue;
            }
            final key = codeKey.isNotEmpty
                ? '${work.site}|code:$codeKey'
                : '${work.site}|title:$titleKey';
            final storedUrl = existing[key];
            if (storedUrl == null) {
              (toInsert[(work.site, work.coverSource)] ??= []).add((
                RosterFilm(
                  code: work.code.trim(),
                  title: work.title.trim(),
                  date: work.date.trim(),
                  coverUrl: work.coverUrl.trim(),
                  detailUrl: work.playUrl.trim(),
                  category: work.category.trim(),
                ),
                key,
              ));
              // upsertWorks 只在有封面时才写 cover 字段：没封面
              // 只有播放地址的条目，补一次更新把地址写进
              // cover_drama_id，否则地址丢了。
              if (work.playUrl.trim().isNotEmpty &&
                  work.coverUrl.trim().isEmpty) {
                toUpdate.add((
                  WorkPlayLinkUpdate(
                    site: work.site,
                    codeKey: codeKey,
                    titleKey: titleKey,
                    title: work.title.trim(),
                    date: work.date.trim(),
                    coverSource: work.coverSource,
                    coverDramaId: work.playUrl.trim(),
                    coverUrl: '',
                  ),
                  true,
                  key,
                ));
              }
              existing[key] = work.playUrl.trim();
            } else if (storedUrl == work.playUrl.trim()) {
              // 番号 + 播放链接都相同：跳过，不重复加。
              skipped++;
            } else {
              // 任一不同：更新替换（换链接与封面，标题/日期
              // 有新值时也换，分类不动）。
              toUpdate.add((
                WorkPlayLinkUpdate(
                  site: work.site,
                  codeKey: codeKey,
                  titleKey: titleKey,
                  title: work.title.trim(),
                  date: work.date.trim(),
                  coverSource: work.coverSource,
                  coverDramaId: work.playUrl.trim(),
                  coverUrl: work.coverUrl.trim(),
                ),
                false,
                key,
              ));
              existing[key] = work.playUrl.trim();
            }
          } catch (_) {
            // 单条失败不崩、不影响同批其他条与已有数据。
            failed++;
          }
          onProgress?.call(done, works.length);
        }
        // 落盘：先新建（按组各一次事务），再更新（一次事务）。
        // 写失败时那几条记 failed，并把缓存里已记的地址撤回，
        // 免得同文件后面批次以为已入库而跳过。
        for (final group in toInsert.entries) {
          try {
            await library.upsertWorks(
              person.localId,
              [for (final item in group.value) item.$1],
              coverSource: group.key.$2,
              site: group.key.$1,
            );
            appended += group.value.length;
          } catch (_) {
            failed += group.value.length;
            for (final item in group.value) {
              existing.remove(item.$2);
            }
          }
        }
        if (toUpdate.isNotEmpty) {
          try {
            final results = await library.updateWorkPlayLinks(
              personId: person.localId,
              updates: [for (final item in toUpdate) item.$1],
            );
            for (var i = 0; i < toUpdate.length && i < results.length; i++) {
              // 补地址的返回值不计（旧口径）。
              if (toUpdate[i].$2) continue;
              if (results[i]) {
                updated++;
              } else {
                failed++;
                existing.remove(toUpdate[i].$3);
              }
            }
          } catch (_) {
            // 整批更新失败：非补地址的更新记 failed，撤回缓存。
            for (final item in toUpdate) {
              if (item.$2) continue;
              failed++;
              existing.remove(item.$3);
            }
          }
        }
      } catch (_) {
        // 整个人失败（建/合人物时抛错）：该人的条目此时还没开始
        // 处理，全部记 failed，继续下一个人。
        failed += personWorks.length;
        done += personWorks.length;
        onProgress?.call(done, works.length);
      }
    }
  } catch (e) {
    error = _shortError(e);
  }
  return ActressDbMirrorResult(
    appended: appended,
    updated: updated,
    skipped: skipped,
    failed: failed,
    total: works.length,
    error: error,
  );
}

/// 收集镜像源文件（可测纯函数，列表页调它）：主目录 [dbDir] 只扫一层，补充目录 [extraDirs] 递归
/// 扫（与 py 的 os.walk 一致）；只收 .db 文件（大小写不敏感），
/// 去掉当前库文件 [libraryPath]，按归一化路径去重（同一文件
/// 在两个目录里出现也只收一次）。单个目录不存在/扫失败时跳过
/// 它，不影响其他目录，不抛错。
/// 2026-11-22 用户令最终口径：已删除的应用库（女优库应用.db）
/// 与老库（actress.db）永不做镜像源（加载链里也不再回落到它们）。
List<File> collectDbMirrorTargets({
  required Directory dbDir,
  required String libraryPath,
  List<Directory> extraDirs = const [],
}) {
  final seen = <String>{};
  final targets = <File>[];
  void add(File file) {
    final normalized = path.normalize(file.path);
    if (!file.path.toLowerCase().endsWith('.db')) return;
    if (path.equals(normalized, path.normalize(libraryPath))) return;
    final baseName = path.basename(file.path);
    if (baseName == '女优库应用.db' || baseName == 'actress.db') return;
    // 2026-11-23 用户令：共用站点库（MYTV/db/站点库.db）只记播过的片，
    // 绝不做镜像源——不加这一行，哪天镜像护栏一变，播放记录会被追加
    // 进女优库.db。
    if (baseName == '站点库.db') return;
    if (!seen.add(normalized)) return;
    targets.add(file);
  }

  try {
    for (final entity in dbDir.listSync()) {
      if (entity is File) add(entity);
    }
  } catch (_) {
    // 主目录扫失败：返回已收集到的（可能为空），不抛错。
  }
  for (final dir in extraDirs) {
    try {
      for (final entity in dir.listSync(recursive: true)) {
        if (entity is File) add(entity);
      }
    } catch (_) {
      // 该目录不存在/扫失败：跳过，不影响其他目录。
    }
  }
  return targets;
}

/// 镜像进度记录：按（路径，大小，修改时间）指纹记哪些文件已
/// 镜像完。文件未变时跳过（重读不重复加也不重复扫大文件）；
/// 文件变了（指纹不同）再跑一次，合并规则兜住不重复加。
/// 每批记一次断点 offset：首跑中途被杀（用户 735MB 的视频库
/// 有 32 万行，首跑很长），下次从断点续跑，不从头重读；
/// 文件一变指纹就变，断点作废、从头重跑（更新过的行在断点前
/// 也会被重新比对，合并规则兜住不重复加）。
/// 记录文件放库文件同目录的 `镜像记录.json`，写失败忽略。
class ActressDbMirrorStateStore {
  ActressDbMirrorStateStore(this.dir);

  final String dir;

  File get file => File(path.join(dir, '镜像记录.json'));

  Map<String, Object?> _readAll() {
    try {
      if (!file.existsSync()) return {};
      final doc = jsonDecode(file.readAsStringSync());
      if (doc is! Map) return {};
      return Map<String, Object?>.from(doc);
    } catch (_) {
      return {};
    }
  }

  bool isDone(String fingerprint) {
    final entry = _readAll()[fingerprint];
    return entry is Map && entry['done'] == true;
  }

  /// 未完成的断点 offset（0 = 没跑过或已跑完）。
  int progressOffset(String fingerprint) {
    final entry = _readAll()[fingerprint];
    if (entry is! Map || entry['done'] == true) return 0;
    return (entry['offset'] as num?)?.toInt() ?? 0;
  }

  void markProgress(String fingerprint, {required int offset, required int total}) {
    try {
      final all = _readAll();
      all[fingerprint] = {
        'done': false,
        'offset': offset,
        'total': total,
        'updatedAt': DateTime.now().toIso8601String(),
      };
      file.writeAsStringSync(jsonEncode(all));
    } catch (_) {
      // 记录写失败不影响镜像本身。
    }
  }

  void markDone(String fingerprint, {required int total}) {
    try {
      final all = _readAll();
      all[fingerprint] = {
        'done': true,
        'total': total,
        'finishedAt': DateTime.now().toIso8601String(),
      };
      file.writeAsStringSync(jsonEncode(all));
    } catch (_) {
      // 记录写失败不影响镜像本身。
    }
  }
}

/// 文件级镜像：只读打开 [sourcePath]，分批读、分批合并进
/// [library]。与当前库同一文件时直接跳过（只显示不写）；
/// 源文件不存在/打不开/结构不对时返回带 error 的结果，不抛错、
/// 不动已有数据。[onProgress] 每批调一次（已追加数，已处理行数，
/// 总行数）——已处理数一直涨，新增数在源库内容已入库时可以是 0，
/// 两数分开显示才看得出在跑、没卡住。
class ActressDbMirror {
  const ActressDbMirror();

  Future<ActressDbMirrorResult> mirrorFile({
    required String sourcePath,
    required ActressDatabase library,
    required String libraryPath,
    int batchSize = 200,
    void Function(int appended, int processed, int total)? onProgress,
    String? stateDir,
  }) async {
    if (path.equals(path.normalize(sourcePath), path.normalize(libraryPath))) {
      return const ActressDbMirrorResult(
        note: '与当前库同一文件，只显示不写',
      );
    }
    final file = File(sourcePath);
    if (!file.existsSync()) {
      return ActressDbMirrorResult(
        error: '数据库文件不存在：${path.basename(sourcePath)}',
      );
    }
    final fingerprint = _fingerprintOf(file);
    final store = ActressDbMirrorStateStore(
      stateDir ?? path.dirname(sourcePath),
    );
    if (store.isDone(fingerprint)) {
      return const ActressDbMirrorResult(alreadyDone: true);
    }
    Database? db;
    try {
      // 2026-11-24 掉线修复：探库独立连接，关完不拖主库的共享连接掉线。
      db = await openDatabase(
        sourcePath,
        readOnly: true,
        singleInstance: false,
      );
      final isActressSchema = await _isActressSchemaDb(db);
      GenericDbReader? reader;
      var total = 0;
      if (isActressSchema) {
        final rows = await db.rawQuery('SELECT COUNT(*) AS n FROM works');
        total = (rows.first['n'] as num?)?.toInt() ?? 0;
      } else {
        final schema = await probeGenericDbSchema(db);
        if (schema.worksTable == null) {
          return ActressDbMirrorResult(
            error: '认不出作品表（没有同时含标题与播放地址的表）',
          );
        }
        reader = GenericDbReader(
          db: db,
          schema: schema,
          mappingStore: GenericDbMappingStore(
            file: File(path.join(path.dirname(sourcePath), '字段映射.json')),
          ),
        );
        total = await reader.countWorks();
      }
      if (total <= 0) {
        store.markDone(fingerprint, total: 0);
        return const ActressDbMirrorResult(total: 0);
      }
      var appended = 0;
      var updated = 0;
      var skipped = 0;
      var failed = 0;
      // 跨批缓存：同一文件内各批共用（personId -> 去重键 -> 已存
      // 播放地址），每人已有作品只读一次，不每批重读。
      final existingCache = <int, Map<String, String>>{};
      // 断点续跑：上次没跑完的从 offset 继续（文件未变才有效，
      // 指纹一变 offset 归零）。
      var offset = store.progressOffset(fingerprint);
      if (offset < 0 || offset >= total) offset = 0;
      while (offset < total) {
        final batch = isActressSchema
            ? await _readActressBatch(db, offset, batchSize)
            : await _readGenericBatch(reader!, offset, batchSize);
        if (batch.isEmpty) break;
        offset += batch.length;
        final result = await mirrorWorks(
          library: library,
          works: batch,
          existingPlayUrls: existingCache,
        );
        appended += result.appended;
        updated += result.updated;
        skipped += result.skipped;
        failed += result.failed;
        onProgress?.call(appended, offset, total);
        store.markProgress(fingerprint, offset: offset, total: total);
      }
      store.markDone(fingerprint, total: total);
      return ActressDbMirrorResult(
        appended: appended,
        updated: updated,
        skipped: skipped,
        failed: failed,
        total: total,
      );
    } catch (e) {
      return ActressDbMirrorResult(error: _shortError(e));
    } finally {
      await db?.close();
    }
  }

  String _fingerprintOf(File file) {
    try {
      final stat = file.statSync();
      return '${file.path}|${stat.size}|${stat.modified.millisecondsSinceEpoch}';
    } catch (_) {
      return file.path;
    }
  }

  Future<bool> _isActressSchemaDb(Database db) async {
    try {
      final tables = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table'",
      );
      final names = tables
          .map((row) => row['name']?.toString() ?? '')
          .toSet();
      if (!names.contains('persons') || !names.contains('works')) {
        return false;
      }
      final columns = await db.rawQuery('PRAGMA table_info(works)');
      return columns.any((col) => col['name'] == 'code_key');
    } catch (_) {
      return false;
    }
  }

  Future<List<ActressDbMirrorWork>> _readActressBatch(
    Database db,
    int offset,
    int limit,
  ) async {
    final rows = await db.rawQuery(
      'SELECT p.display_name AS actress, w.code_display AS code, '
      'w.title AS title, w.date AS date, w.category AS category, '
      'w.cover_source AS cover_source, w.cover_drama_id AS play_url, '
      'w.cover_url AS cover_url, w.site AS site '
      'FROM works w JOIN persons p ON p.id = w.person_id '
      'ORDER BY w.rowid LIMIT ? OFFSET ?',
      [limit, offset],
    );
    return [
      for (final row in rows)
        ActressDbMirrorWork(
          actress: row['actress']?.toString() ?? '',
          code: row['code']?.toString() ?? '',
          title: (() {
            final title = row['title']?.toString() ?? '';
            if (title.isNotEmpty) return title;
            return row['code']?.toString() ?? '';
          })(),
          date: row['date']?.toString() ?? '',
          category: row['category']?.toString() ?? '',
          coverUrl: row['cover_url']?.toString() ?? '',
          playUrl: row['play_url']?.toString() ?? '',
          site: row['site']?.toString() ?? '',
          coverSource: row['cover_source']?.toString() ?? '',
        ),
    ];
  }

  Future<List<ActressDbMirrorWork>> _readGenericBatch(
    GenericDbReader reader,
    int offset,
    int limit,
  ) async {
    final works = await reader.works(offset: offset, limit: limit);
    return [for (final work in works) ActressDbMirrorWork.fromGenericWork(work)];
  }
}

String _shortError(Object e) {
  final text = e.toString().replaceAll('\n', ' ').trim();
  return text.length > 120 ? '${text.substring(0, 120)}…' : text;
}
