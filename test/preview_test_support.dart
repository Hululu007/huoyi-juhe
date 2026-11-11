import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show FontLoader, rootBundle;
import 'package:flutter_test/flutter_test.dart';

/// 预览/截图类测试的共享支撑。
///
/// 此前各预览测试把字体写死成本机绝对路径
/// （`/home/hatch/flutter/.../MaterialIcons-Regular.otf`、
/// `/home/hatch/.pub-cache/.../flutter_lucide-1.59.0/...`），CI 检出机上
/// 没有这些路径，测试一跑就报 PathNotFoundException。这里一律改成可移植取法：
///
/// * MaterialIcons：先走包内资产 `fonts/MaterialIcons-Regular.otf`
///  （flutter 自身声明的资产，`flutter test` 下可用，CI 已证实），
///   拿不到时再从当前测试执行文件所在 Flutter SDK 推导
///   （`<sdk>/bin/cache/artifacts/material_fonts/...`），还拿不到就跳过
///   （图标变方框，但测试不因此失败）。
/// * Lucide：先走包内资产 `packages/flutter_lucide/lib/fonts/lucide.ttf`，
///   拿不到时在 pub 缓存里找任意已装版本的 `flutter_lucide-*`，
///   再拿不到就跳过（与 preview_capture_test 的做法一致）。
/// * 思源 CJK：只从系统字体目录读，文件不存在就跳过（CI 镜像自带），
///   不再假定某一条绝对路径一定存在。
/// * 预览 PNG 输出目录：优先沿用本机旧目录
///   `/home/hatch/workspace/moyi_style_preview`（存在时行为与原来一致），
///   否则用 `$HOME/workspace/moyi_style_preview`，再否则用包内 `previews/`；
///   可用环境变量 `MOYI_PREVIEW_OUT_DIR` 覆盖。
/// * 预览输入图（如模拟剧照）：优先沿用仓外旧目录
///   `../moyi_style_preview/`，否则用仓内 `test/fixtures/moyi_style_preview/`；
///   可用环境变量 `MOYI_STYLE_PREVIEW_DIR` 覆盖。
///
/// 注意：全部加载必须在 [tester] 的 `runAsync` 里做真异步 IO。
/// testWidgets 体跑在 FakeAsync 区里，直接 `await File.readAsBytes()` 或
/// `await rootBundle.load()` 永远等不到真实 IO 回包、测试会挂死
/// （2026-11-11 探针实测：`await noto.readAsBytes()` 在假时钟区里 180 秒
/// 无返回；改 runAsync 后通过）。
Future<void> loadPreviewFonts(
  WidgetTester tester, {
  bool serif = false,
  bool lucide = false,
  bool monospace = false,
}) async {
  await tester.runAsync(() async {
    final base = serif ? 'NotoSerifCJK' : 'NotoSansCJK';
    ByteData? regular;
    for (final weight in const ['Regular', 'Bold']) {
      final file = _firstExistingFile([
        '/usr/share/fonts/opentype/noto/$base-$weight.ttc',
        '/usr/share/fonts/truetype/noto/$base-$weight.ttc',
        '/usr/share/fonts/noto-cjk/$base-$weight.ttc',
      ]);
      if (file == null) continue;
      final bytes = ByteData.sublistView(await file.readAsBytes());
      if (weight == 'Regular') regular = bytes;
      final loader = FontLoader(base)..addFont(Future.value(bytes));
      await loader.load();
    }
    if (monospace && regular != null) {
      final monoLoader = FontLoader('monospace')
        ..addFont(Future.value(regular));
      await monoLoader.load();
    }

    final icons = await _loadMaterialIcons();
    if (icons != null) {
      final iconLoader = FontLoader('MaterialIcons')
        ..addFont(Future.value(icons));
      await iconLoader.load();
    }

    if (lucide) {
      final lucideBytes = await _loadLucide();
      if (lucideBytes != null) {
        final lucideLoader = FontLoader('packages/flutter_lucide/lucide')
          ..addFont(Future.value(lucideBytes));
        await lucideLoader.load();
      }
    }
  });
}

File? _firstExistingFile(List<String> paths) {
  for (final path in paths) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  return null;
}

/// MaterialIcons：包内资产优先，SDK 推导兜底，都没有则返回 null。
Future<ByteData?> _loadMaterialIcons() async {
  try {
    return await rootBundle.load('fonts/MaterialIcons-Regular.otf');
  } catch (_) {
    // 测试跑在 flutter_tester 下，执行文件在
    // <sdk>/bin/cache/artifacts/engine/<platform>/flutter_tester，
    // 往上 5 级就是 SDK 根目录。
    final candidates = <String>[];
    try {
      var dir = File(Platform.resolvedExecutable).parent;
      for (var i = 0; i < 5; i++) {
        dir = dir.parent;
      }
      candidates.add(
        '${dir.path}/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
    } catch (_) {}
    final flutterRoot = Platform.environment['FLUTTER_ROOT'];
    if (flutterRoot != null && flutterRoot.isNotEmpty) {
      candidates.add(
        '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      );
    }
    for (final path in candidates) {
      final file = File(path);
      if (file.existsSync()) {
        return ByteData.sublistView(await file.readAsBytes());
      }
    }
    return null;
  }
}

/// Lucide：包内资产优先，pub 缓存里任意已装版本兜底，都没有则返回 null。
Future<ByteData?> _loadLucide() async {
  try {
    return await rootBundle.load(
      'packages/flutter_lucide/lib/fonts/lucide.ttf',
    );
  } catch (_) {
    try {
      final pubCache = Platform.environment['PUB_CACHE'] ??
          '${Platform.environment['HOME'] ?? ''}/.pub-cache';
      final hosted = Directory('$pubCache/hosted/pub.dev');
      if (await hosted.exists()) {
        await for (final entry in hosted.list()) {
          final name = entry.path.split(Platform.pathSeparator).last;
          if (!name.startsWith('flutter_lucide-')) continue;
          final file = File(
            '${entry.path}/lib/fonts/lucide.ttf',
          );
          if (await file.exists()) {
            return ByteData.sublistView(await file.readAsBytes());
          }
        }
      }
    } catch (_) {}
    return null;
  }
}

/// 预览 PNG 的输出目录（不保证已存在，调用方按原有做法自行创建父目录）。
Directory previewOutDir() {
  final override = Platform.environment['MOYI_PREVIEW_OUT_DIR'];
  if (override != null && override.isNotEmpty) return Directory(override);
  const legacy = '/home/hatch/workspace/moyi_style_preview';
  if (Directory(legacy).existsSync()) return Directory(legacy);
  final home = Platform.environment['HOME'];
  if (home != null && home.isNotEmpty) {
    return Directory('$home/workspace/moyi_style_preview');
  }
  return Directory('previews');
}

/// 预览 PNG 的输出路径：`previewOutPath('channel.png')`。
String previewOutPath(String name) => '${previewOutDir().path}/$name';

/// 找到预览输入图（如模拟剧照 still_mock.png）。
///
/// 候选顺序：环境变量指定的目录 → 仓外旧目录（`../moyi_style_preview/`，
/// 本机行为与原来一致）→ 本机绝对旧目录 → 仓内夹带
/// `test/fixtures/moyi_style_preview/`（CI 靠它兜底）。都找不到时抛错，
/// 并列出试过的所有路径，不留悬空引用。
File resolvePreviewFixture(String name) {
  final candidates = <String>[];
  final override = Platform.environment['MOYI_STYLE_PREVIEW_DIR'];
  if (override != null && override.isNotEmpty) {
    candidates.add('$override/$name');
  }
  candidates.addAll([
    '../moyi_style_preview/$name',
    '/home/hatch/workspace/moyi_style_preview/$name',
    'test/fixtures/moyi_style_preview/$name',
    'fixtures/moyi_style_preview/$name',
  ]);
  for (final path in candidates) {
    final file = File(path);
    if (file.existsSync()) return file;
  }
  throw StateError(
    'preview fixture $name not found; tried: ${candidates.join(', ')}',
  );
}
