import '../services/desktop_platform.dart';
import '../widgets/desktop_settings_body.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

import '../services/app_theme.dart';
import '../services/audio_preferences.dart';
import '../services/native_player.dart';
import '../services/player_preferences.dart';
import '../services/player_layout_preferences.dart';
import '../services/source_registry.dart';
import '../services/file_text_picker.dart';
import '../services/book_open_preferences.dart';
import '../services/drama_mute_preferences.dart';
import '../services/library_store.dart';
import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_widgets.dart';
import 'api_service_page.dart';
import 'cached_books_page.dart';
import 'cached_dramas_page.dart';
import 'cultivation_titles_page.dart';
import 'library_backup_page.dart';
import 'onekey_py_page.dart';
import 'settings_category_page.dart';
import 'source_management_page.dart';
import 'system_tts_settings_page.dart';
import 'text_replacement_page.dart';

/// Settings home: a list of category entries (PiliPlus multi-level
/// navigation). Each category opens its own CommonSetting-style page.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // 开关读的是 ValueNotifier：先把持久化的值读出来，读到后自动重绘。
    unawaited(BookOpenPreferences.instance.load());
    final categories = <SettingsCategory>[
      SettingsCategory(
        icon: LucideIcons.palette,
        title: '外观',
        subtitle: '主题模式、OLED 纯黑、背景主题、播放页布局',
        // 用 builder 而不是固定 items：切到深色 / 切回浅色后，分类页重建
        // 时会重新判定，OLED 行不必退出重进就能出现或消失。
        // 播放页布局只在手机端有效（Windows 由 DesktopVideoChrome 承担）。
        itemsBuilder: (context) => [
          _themeModeItem(),
          if (isDarkAppearance(
            systemBrightness: MediaQuery.platformBrightnessOf(context),
          ))
            _oledModeItem(),
          _backgroundItem(),
          if (!isWindowsDesktop) _playerLayoutItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.book_open,
        title: '阅读',
        subtitle: '阅读入口、正文替换',
        items: [
          _shelfDirectReaderItem(),
          _discoverDirectReaderItem(),
          SettingsItem(
            icon: LucideIcons.replace,
            title: '正文替换',
            subtitle: '自定义普通文本或正则替换规则',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const TextReplacementPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.headphones,
        title: '听书',
        subtitle: '后台播放、通知栏控制与系统朗读',
        items: [
          _backgroundAudioItem(),
          if (!isWindowsDesktop) _audioRateEngineItem(),
          SettingsItem(
            icon: LucideIcons.mic,
            title: '系统朗读',
            subtitle: '选择 TTS 引擎与语速，支持本地书',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const SystemTtsSettingsPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.film,
        title: '短剧',
        subtitle: '播放',
        items: [
          _muteWhenColdStartItem(),
          if (!isWindowsDesktop) _floatingWindowItem(),
          if (!isWindowsDesktop) _videoDecoderItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.sparkles,
        title: '修仙',
        subtitle: '修为与境界',
        items: [
          SettingsItem(
            icon: LucideIcons.trophy,
            title: '称号排行',
            subtitle: '按修为排的 14 档称号，前三是特效称号',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const CultivationTitlesPage(),
              ),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.list,
        title: '站源',
        subtitle: '内置短剧、自定义与导入站源的开关与检测',
        items: [
          SettingsItem(
            icon: LucideIcons.list,
            title: '站源管理',
            subtitle: '开关站源、检测可用性、添加 MacCMS 与远程 JSON 站源',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const SourceManagementPage(),
              ),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.wand_sparkles,
            title: '一键写PY',
            subtitle: '输网址自动生成 py 并导入站源管理',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const OneKeyPyPage()),
            ),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.book_open,
        title: '书源',
        subtitle: '导入阅读书源（JSON 文件）',
        items: [
          SettingsItem(
            icon: LucideIcons.book_plus,
            title: '书源导入',
            subtitle: '选择 JSON 文件或粘贴远程地址导入，自动识别',
            onTap: (context, _) => _showBookSourceImportDialog(context),
          ),
          SettingsItem(
            icon: LucideIcons.book_down,
            title: 'JSON 书源导入',
            subtitle: '选择 JSON 文件导入，支持单个或数组',
            onTap: (context, _) =>
                _showBookSourceImportDialog(context, jsonOnly: true),
          ),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.database,
        title: '数据',
        subtitle: '备份与恢复、缓存、阅读与播放历史',
        items: [
          SettingsItem(
            icon: LucideIcons.database,
            title: '备份与导入',
            subtitle: '本机备份、恢复与番茄书架导入',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const LibraryBackupPage()),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.bookmark,
            title: '小说离线缓存',
            subtitle: '离线续读、查看占用和清理缓存',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedBooksPage()),
            ),
          ),
          SettingsItem(
            icon: LucideIcons.clapperboard,
            title: '短剧离线缓存',
            subtitle: '短剧下载、离线播放和清理缓存',
            onTap: (context, setState) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const CachedDramasPage()),
            ),
          ),
          _clearHistItem(),
        ],
      ),
      SettingsCategory(
        icon: LucideIcons.cpu,
        title: '服务',
        subtitle: '本地接口地址与可用端点',
        pageBuilder: (_) => const ApiServicePage(),
        items: const [],
      ),
    ];

    return SettingsScaffold(
      title: '设置',
      body: isWindowsDesktop
          ? DesktopSettingsBody(categories: categories)
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              children: [
                SettingsGroupCard(
                  children: [
                    for (final cat in categories)
                      SettingsRow(
                        icon: cat.icon,
                        iconTile: true,
                        title: cat.title,
                        subtitle: cat.subtitle,
                        onTap: () => _openCategory(context, cat),
                      ),
                  ],
                ),
              ],
            ),
    );
  }

  static void _openCategory(BuildContext context, SettingsCategory cat) {
    final pageBuilder = cat.pageBuilder;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder:
            pageBuilder ??
            (_) => SettingsCategoryPage(
              title: cat.title,
              items: cat.items,
              itemsBuilder: cat.itemsBuilder,
            ),
      ),
    );
  }

  // ── 修仙 ──────────────────────────────────────────────────────────────

  // ── 书源 ──────────────────────────────────────────────────────────────

  /// 书源导入：选 JSON 文件导入，或在输入框粘贴远程书源地址 / JSON 内容。
  /// 导入时优先用输入框里的内容，按 classifyBookSourceInput 识别：
  /// http(s) 链接走远程拉取，JSON 对象/数组直接导入。导入走注册表
  /// 现成的 addLegadoImport / addLegadoRemote，导入后在站源管理里可见。
  Future<void> _showBookSourceImportDialog(
    BuildContext context, {
    bool jsonOnly = false,
  }) async {
    var text = '';
    var pickedName = '';
    final urlController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(jsonOnly ? 'JSON 书源导入' : '书源导入'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  final picked = await pickTextFile(
                    label: 'JSON',
                    extensions: ['json'],
                  );
                  if (picked == null) return;
                  setDialogState(() {
                    text = picked.content;
                    pickedName = picked.name;
                  });
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('选择 JSON 文件'),
              ),
              const SizedBox(height: 8),
              Text(
                pickedName.isEmpty ? '未选择文件' : '已选：$pickedName',
                style: const TextStyle(fontSize: 12, color: Colors.grey),
              ),
              if (!jsonOnly) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(
                    labelText: '远程书源地址',
                    hintText: '粘贴远程书源地址 http(s)://…',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setDialogState(() {}),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed:
                  (text.isEmpty && urlController.text.trim().isEmpty)
                  ? null
                  : () => Navigator.of(dialogContext).pop(true),
              child: const Text('导入'),
            ),
          ],
        ),
      ),
    );
    final typed = urlController.text.trim();
    urlController.dispose();
    if (confirmed != true || !context.mounted) return;
    // 优先用输入框里的内容（远程地址或 JSON），没填才用选中的文件内容。
    final effective = typed.isNotEmpty ? typed : text;
    final registry = SourceRegistry.instance;
    try {
      if (jsonOnly) {
        final trimmed = effective.trim();
        if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('所选文件不是 JSON 书源（单个或数组）')),
          );
          return;
        }
        final entries = await registry.addLegadoImport(effective);
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已导入 ${entries.length} 个书源')),
        );
        return;
      }
      switch (classifyBookSourceInput(effective)) {
        case BookSourceImportKind.invalid:
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('输入内容不是有效的书源')),
          );
        case BookSourceImportKind.remote:
          final entries = await registry.addLegadoRemote(effective.trim());
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导入 ${entries.length} 个书源')),
          );
        case BookSourceImportKind.json:
          final entries = await registry.addLegadoImport(effective);
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已导入 ${entries.length} 个书源')),
          );
      }
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入失败：$e')),
      );
    }
  }

  // ── 外观 ──────────────────────────────────────────────────────────────

  /// 主题模式（参考 legado 的 themeMode）：跟随系统 / 浅色 / 深色 / 墨水屏
  /// 四选一，墨水屏既然也是一种外观就并进这个入口，不再单列一个开关。
  SettingsItem _themeModeItem() => SettingsItem(
    icon: LucideIcons.sun_moon,
    title: '主题模式',
    trailingBuilder: (context) => ListenableBuilder(
      listenable: Listenable.merge([themeModeNotifier, einkModeNotifier]),
      builder: (context, _) {
        final palette = HomePalette.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _appearance.label,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 18, color: palette.muted),
          ],
        );
      },
    ),
    onTap: (context, setState) => _showThemeModeDialog(context),
  );

  /// 当前外观：墨水屏优先级最高（深色反白在墨水屏上残影最重），
  /// 没有开墨水屏时再按深色模式取值。
  _AppearanceChoice get _appearance {
    if (einkModeNotifier.value) return _AppearanceChoice.eink;
    switch (themeModeNotifier.value) {
      case ThemeMode.light:
        return _AppearanceChoice.light;
      case ThemeMode.dark:
        return _AppearanceChoice.dark;
      case ThemeMode.system:
        return _AppearanceChoice.system;
    }
  }

  Future<void> _showThemeModeDialog(BuildContext context) async {
    final selected = await showDialog<_AppearanceChoice>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('主题模式'),
        children: [
          RadioGroup<_AppearanceChoice>(
            groupValue: _appearance,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final choice in _AppearanceChoice.values)
                  RadioListTile<_AppearanceChoice>(
                    value: choice,
                    title: Text(choice.label),
                    subtitle: choice == _AppearanceChoice.eink
                        ? const Text('纯黑白、无毛玻璃、无过渡动画，适合墨水屏设备')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await _setAppearance(context, selected);
  }

  /// 主题模式落盘：浅色 / 深色 / 跟随系统写 theme_mode，墨水屏另存
  /// eink_mode。选墨水屏时保留原先的浅色 / 深色值，退出墨水屏能回到它。
  Future<void> _setAppearance(
    BuildContext context,
    _AppearanceChoice choice,
  ) async {
    final eink = choice == _AppearanceChoice.eink;
    final mode = switch (choice) {
      _AppearanceChoice.system => ThemeMode.system,
      _AppearanceChoice.light => ThemeMode.light,
      _AppearanceChoice.dark => ThemeMode.dark,
      _AppearanceChoice.eink => themeModeNotifier.value,
    };
    einkModeNotifier.value = eink;
    themeModeNotifier.value = mode;
    // 墨水屏恒为浅色外观，OLED 纯黑无从生效：一并关掉，否则以后切回深色
    // 会被上一次的纯黑默默接管。
    if (eink) oledModeNotifier.value = false;
    try {
      final sp = await SharedPreferences.getInstance();
      final modeSaved = await sp.setString(themeModeKey, mode.name);
      final einkSaved = await sp.setBool(einkModeKey, eink);
      final oledSaved = eink ? await sp.setBool(oledModeKey, false) : true;
      if (!modeSaved || !einkSaved || !oledSaved) {
        throw StateError('Appearance preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('外观已更新，但未能保存')));
      }
    }
  }

  /// OLED 纯黑：画布纯黑省电，卡片 / 弹层保持近黑，靠描边撑住层次。
  /// 只在深色外观下显示（浅色 / 墨水屏没有可省的黑）。
  SettingsItem _oledModeItem() => SettingsItem(
    icon: LucideIcons.smartphone,
    title: 'OLED 纯黑',
    subtitle: '大面积纯黑省电，仅在深色外观下生效',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: oledModeNotifier,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: 'OLED 纯黑',
        onChanged: (v) => unawaited(_setOledMode(context, v)),
      ),
    ),
    onTap: (context, setState) {
      unawaited(_setOledMode(context, !oledModeNotifier.value));
    },
  );

  Future<void> _setOledMode(BuildContext context, bool value) async {
    oledModeNotifier.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      if (!await sp.setBool(oledModeKey, value)) {
        throw StateError('OLED preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('OLED 纯黑已更新，但未能保存')));
      }
    }
  }

  /// 背景主题：预设色（按当前亮度过滤）或自定义图片，全应用生效，首页
  /// 也跟着换；墨水屏下不生效（纯黑白是硬件约束）。
  SettingsItem _backgroundItem() => SettingsItem(
    icon: LucideIcons.image,
    title: '背景主题',
    subtitle: '全应用背景色或图片，首页也生效',
    trailingBuilder: (context) => ValueListenableBuilder<AppBackground>(
      valueListenable: backgroundNotifier,
      builder: (context, bg, _) {
        if (bg.isImage) return const Icon(LucideIcons.image);
        final color = bg.presetColor;
        if (color != null) {
          return Container(
            width: 24,
            height: 24,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Theme.of(context).dividerColor),
            ),
          );
        }
        return const Text('默认');
      },
    ),
    onTap: (context, setState) {
      unawaited(_pickBackground(context));
    },
  );

  Future<void> _pickBackground(BuildContext context) async {
    final isDark = isDarkAppearance(
      systemBrightness: MediaQuery.platformBrightnessOf(context),
    );
    final presets = [
      for (final preset in backgroundPresets)
        if (preset.dark == isDark) preset,
    ];
    final pick = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('背景主题'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.ban),
                title: const Text('默认'),
                subtitle: const Text('跟随主题画布'),
                onTap: () => Navigator.pop(context, 'default'),
              ),
              for (final preset in presets)
                ListTile(
                  leading: Container(
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: preset.color,
                      shape: BoxShape.circle,
                    ),
                  ),
                  title: Text(preset.name),
                  onTap: () => Navigator.pop(context, preset.id),
                ),
              ListTile(
                leading: const Icon(LucideIcons.image),
                title: const Text('从相册选图'),
                onTap: () => Navigator.pop(context, 'custom'),
              ),
            ],
          ),
        ),
      ),
    );
    if (pick == null || !context.mounted) return;
    await _applyBackgroundPick(context, pick);
  }

  Future<void> _applyBackgroundPick(BuildContext context, String pick) async {
    String? imagePath;
    if (pick == 'custom') {
      final file = await ImagePicker().pickImage(source: ImageSource.gallery);
      if (file == null) return;
      try {
        final docs = await getApplicationDocumentsDirectory();
        final ext = file.path.split('.').last.toLowerCase();
        final safeExt = ['jpg', 'jpeg', 'png', 'webp'].contains(ext)
            ? ext
            : 'jpg';
        final dest = File('${docs.path}/app_background.$safeExt');
        await File(file.path).copy(dest.path);
        imagePath = dest.path;
      } catch (_) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('图片保存失败，背景未改')),
          );
        }
        return;
      }
    }
    final bg = AppBackground.decode(
      pick == 'custom' ? 'custom' : pick,
      imagePath,
    );
    backgroundNotifier.value = bg;
    try {
      final sp = await SharedPreferences.getInstance();
      final idSaved = await sp.setString(backgroundKey, bg.id);
      final imageSaved = bg.isImage
          ? await sp.setString(backgroundImageKey, bg.imagePath!)
          : await sp.remove(backgroundImageKey);
      if (!idSaved || !imageSaved) {
        throw StateError('Background preference was not saved');
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('背景已更新，但未能保存')),
        );
      }
    }
  }

  /// 播放页布局：沉浸式 / 横屏片源自动分屏 / 始终分屏。
  ///
  /// 只影响短剧播放页，Windows 隐藏（桌面已有 304dp 停靠选集面板）。
  SettingsItem _playerLayoutItem() => SettingsItem(
    icon: LucideIcons.columns_2,
    title: '播放页布局',
    subtitle: '短剧可分屏显示选集和评论，横屏时左右分栏',
    trailingBuilder: (context) => ValueListenableBuilder<PlayerLayoutMode>(
      valueListenable: PlayerLayoutPreferences.mode,
      builder: (context, value, _) {
        final palette = HomePalette.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value.shortLabel,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 18, color: palette.muted),
          ],
        );
      },
    ),
    onTap: (context, setState) => _showPlayerLayoutDialog(context),
  );

  Future<void> _showPlayerLayoutDialog(BuildContext context) async {
    final current = PlayerLayoutPreferences.mode.value;
    final selected = await showDialog<PlayerLayoutMode>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('播放页布局'),
        children: [
          RadioGroup<PlayerLayoutMode>(
            groupValue: current,
            onChanged: (value) {
              if (value != null) Navigator.pop(dialogContext, value);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final mode in PlayerLayoutMode.values)
                  RadioListTile<PlayerLayoutMode>(
                    value: mode,
                    title: Text(mode.label),
                    subtitle: Text(mode.description),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await _setPlayerLayout(context, selected);
  }

  Future<void> _setPlayerLayout(
    BuildContext context,
    PlayerLayoutMode value,
  ) async {
    final previous = PlayerLayoutPreferences.mode.value;
    if (previous == value) return;
    PlayerLayoutPreferences.mode.value = value;
    try {
      if (!await PlayerLayoutPreferences.save(value)) {
        throw StateError('Player layout preference was not saved');
      }
    } catch (_) {
      // 落盘失败就退回原选择，避免界面显示与实际不一致。
      PlayerLayoutPreferences.mode.value = previous;
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未能保存播放页布局，已恢复原设置')));
      }
    }
  }

  // ── 阅读 ──────────────────────────────────────────────────────────────

  /// issue #19 第 3 条：点书跳过详情页，直接按上次进度进阅读器（小说/漫画）。
  /// 切后台悬浮窗播放（#24，默认关）：开启且已授予悬浮窗权限时，切到
  /// 后台或锁屏用悬浮小窗继续播；关闭则切后台暂停（现有行为）。
  /// 开启时若无权限，先打开系统设置让用户授予，授予后回来再点一次。
  SettingsItem _floatingWindowItem() => SettingsItem(
    icon: LucideIcons.video,
    title: '切后台悬浮窗播放',
    subtitle: '切到后台或锁屏时用悬浮小窗继续播放，需要悬浮窗权限',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: PlayerPreferences.floatingWindow,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '切后台悬浮窗播放',
        onChanged: (enabled) => unawaited(_setFloatingWindow(context, enabled)),
      ),
    ),
    onTap: (context, setState) {
      final current = PlayerPreferences.floatingWindow.value;
      unawaited(_setFloatingWindow(context, !current));
    },
  );

  Future<void> _setFloatingWindow(BuildContext context, bool enabled) async {
    if (!enabled) {
      await PlayerPreferences.setFloatingWindow(false);
      return;
    }
    if (await NativePlayer.canDrawOverlays()) {
      await PlayerPreferences.setFloatingWindow(true);
      return;
    }
    await NativePlayer.requestOverlayPermission();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请在系统设置中允许“显示在其他应用的上层”，然后回来再开启')),
      );
    }
  }

  /// 默认关＝现有行为（先进详情页）。听书/短剧与加载失败时仍停留在详情页。
  ///
  /// 书架的「我的书」和发现入口分成两条（issue #103）：书架里的书点开多半是
  /// 接着读，首页/搜索里的书往往还要先看简介，一条全局开关会让两边互相干扰。
  SettingsItem _shelfDirectReaderItem() => SettingsItem(
    icon: LucideIcons.book_open,
    title: '书架点书直接进入阅读',
    subtitle: '在书架、阅读历史里点书时跳过详情页，接着上次进度读',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: BookOpenPreferences.instance.shelfDirectReader,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '书架点书直接进入阅读',
        onChanged: (v) =>
            unawaited(BookOpenPreferences.instance.setShelfDirectReader(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = BookOpenPreferences.instance.shelfDirectReader.value;
      unawaited(BookOpenPreferences.instance.setShelfDirectReader(!current));
    },
  );

  SettingsItem _discoverDirectReaderItem() => SettingsItem(
    icon: LucideIcons.search,
    title: '首页与搜索点书直接进入阅读',
    subtitle: '在首页、搜索、榜单、作者页等入口点书时跳过详情页',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: BookOpenPreferences.instance.discoverDirectReader,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '首页与搜索点书直接进入阅读',
        onChanged: (v) =>
            unawaited(BookOpenPreferences.instance.setDiscoverDirectReader(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = BookOpenPreferences.instance.discoverDirectReader.value;
      unawaited(BookOpenPreferences.instance.setDiscoverDirectReader(!current));
    },
  );
  // ── 听书 ──────────────────────────────────────────────────────────────

  SettingsItem _backgroundAudioItem() => SettingsItem(
    icon: LucideIcons.radio,
    title: '后台听书与保活',
    subtitle: '切到后台或锁屏时继续播放，并在通知栏常驻控制卡片',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: AudioPreferences.instance.backgroundPlayback,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '后台听书与保活',
        onChanged: (v) =>
            unawaited(AudioPreferences.instance.setBackgroundPlayback(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = AudioPreferences.instance.backgroundPlayback.value;
      unawaited(AudioPreferences.instance.setBackgroundPlayback(!current));
    },
  );

  /// 听书倍速的变速实现（issue #129）：默认交给系统混音器，高倍速下明显
  /// 没那么「电音」；内建 Sonic 作为厂商实现异常时的回退档。
  ///
  /// 与「视频解码器」同理：audio sink 在 build 时定型，新建播放器才生效。
  SettingsItem _audioRateEngineItem() => SettingsItem(
    icon: LucideIcons.gauge,
    title: '听书变速引擎',
    subtitle: '高倍速发毛、像电音时可在两档间切换，重新进入听书页生效',
    trailingBuilder: (context) => ValueListenableBuilder<AudioRateEngine>(
      valueListenable: AudioPreferences.instance.rateEngine,
      builder: (context, value, _) {
        final palette = HomePalette.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value.label,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 18, color: palette.muted),
          ],
        );
      },
    ),
    onTap: (context, setState) => _showAudioRateEngineDialog(context, setState),
  );

  Future<void> _showAudioRateEngineDialog(
    BuildContext context,
    StateSetter refresh,
  ) async {
    final current = AudioPreferences.instance.rateEngine.value;
    final selected = await showDialog<AudioRateEngine>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('听书变速引擎'),
        children: [
          RadioGroup<AudioRateEngine>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in AudioRateEngine.values)
                  RadioListTile<AudioRateEngine>(
                    value: value,
                    title: Text(value.label),
                    subtitle: Text(switch (value) {
                      AudioRateEngine.wsola =>
                        '与番茄官方同一套算法（FFmpeg atempo），高倍速听感最接近原声',
                      AudioRateEngine.platform => '系统混音器变速，不依赖本应用的 native 库',
                      AudioRateEngine.builtIn =>
                        'Media3 内建 Sonic，最稳（默认，1.0.121 的行为）',
                    }),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    await AudioPreferences.instance.setRateEngine(selected);
    refresh(() {});
  }

  // ── 短剧 ──────────────────────────────────────────────────────────────

  /// 官方设置项「开启应用时默认静音」（`GlobalMuteConfig` 标题，持久层
  /// `open_mute_when_cold_start`，默认 false＝有声起播）。
  SettingsItem _muteWhenColdStartItem() => SettingsItem(
    icon: LucideIcons.volume_x,
    title: '开启应用时默认静音',
    subtitle: '进入短剧时静音播放，可在播放页取消',
    // Switch 走 ValueListenableBuilder，翻转后无需依赖页面的 setState。
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: DramaMutePreferences.instance.muteWhenColdStart,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '开启应用时默认静音',
        onChanged: (v) => unawaited(DramaMutePreferences.instance.set(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = DramaMutePreferences.instance.muteWhenColdStart.value;
      unawaited(DramaMutePreferences.instance.set(!current));
    },
  );

  /// 视频解码器（issue #92）：硬解异常的机型可以手动切软解。
  ///
  /// 只有**新起的播放器**会采用新设置——ExoPlayer 的 renderer 在 build 时
  /// 定型，所以行内说明写明需重新进入播放页。
  SettingsItem _videoDecoderItem() => SettingsItem(
    icon: LucideIcons.monitor_play,
    title: '视频解码器',
    subtitle: '画面异常（黑屏、卡住、绿屏）时改用软解，重新进入播放页生效',
    trailingBuilder: (context) => FutureBuilder<VideoDecoderPreference>(
      future: PlayerPreferences.loadVideoDecoder(),
      builder: (context, snapshot) {
        final palette = HomePalette.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              (snapshot.data ?? VideoDecoderPreference.automatic).label,
              style: TextStyle(fontSize: 13, color: palette.muted),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 18, color: palette.muted),
          ],
        );
      },
    ),
    onTap: (context, setState) => _showVideoDecoderDialog(context, setState),
  );

  Future<void> _showVideoDecoderDialog(
    BuildContext context,
    StateSetter refresh,
  ) async {
    final current = await PlayerPreferences.loadVideoDecoder();
    if (!context.mounted) return;
    final selected = await showDialog<VideoDecoderPreference>(
      context: context,
      builder: (c) => SimpleDialog(
        title: const Text('视频解码器'),
        children: [
          RadioGroup<VideoDecoderPreference>(
            groupValue: current,
            onChanged: (v) {
              if (v != null) Navigator.pop(c, v);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final value in VideoDecoderPreference.values)
                  RadioListTile<VideoDecoderPreference>(
                    value: value,
                    title: Text(value.label),
                    subtitle: value == VideoDecoderPreference.software
                        ? const Text('更耗电，但能绕开部分芯片的硬解缺陷')
                        : null,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
    if (selected == null || !context.mounted) return;
    try {
      await DecoderPreferenceCache.set(selected);
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('解码器设置未能保存')));
      }
      return;
    }
    refresh(() {});
  }

  // ── 数据 ──────────────────────────────────────────────────────────────

  SettingsItem _clearHistItem() => SettingsItem(
    icon: LucideIcons.trash,
    title: '清空历史',
    subtitle: '删除全部阅读/播放历史与累计时长',
    onTap: (context, setState) => _confirmClear(
      context,
      '清空历史',
      '确定清空全部阅读/播放历史与累计时长吗？',
      LibraryStore.instance.clearReadingData,
    ),
  );

  Future<void> _confirmClear(
    BuildContext context,
    String title,
    String message,
    Future<void> Function() action,
  ) async {
    final ok = await showSettingsConfirmDialog(
      context: context,
      title: title,
      message: message,
      confirmLabel: '清空',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await action();
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('已清空')));
      }
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('清空失败，请重试')));
      }
    }
  }
}

/// 主题模式的可选项：三种深浅色模式 + 墨水屏。墨水屏本不是 ThemeMode，
/// 但用户眼里它就是第四种外观，所以放进同一个选择器（同 legado）。
enum _AppearanceChoice {
  system('跟随系统'),
  light('浅色'),
  dark('深色'),
  eink('墨水屏');

  const _AppearanceChoice(this.label);

  final String label;
}
