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
import '../services/source_registry.dart';
import '../services/file_text_picker.dart';
import '../services/book_open_preferences.dart';
import '../services/library_store.dart';
import '../services/live_settings.dart';
import '../services/site_health.dart';
import '../widgets/settings/settings_widgets.dart';
import '../widgets/series_detail/moyi_detail_theme.dart';
import 'api_service_page.dart';
import 'bottom_nav_manage_page.dart';
import 'app_update_page.dart';
import 'bytevc2_verify_page.dart';
import 'cached_books_page.dart';
import 'cached_dramas_page.dart';
import 'cultivation_titles_page.dart';
import 'hongguo_login_page.dart';
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
    unawaited(LiveSettingsStore.instance.load());
    final categories = <SettingsCategory>[
      SettingsCategory(
        icon: LucideIcons.palette,
        title: '外观',
        subtitle: '主题模式、OLED 纯黑、背景主题',
        // 用 builder 而不是固定 items：切到深色 / 切回浅色后，分类页重建
        // 时会重新判定，OLED 行不必退出重进就能出现或消失。
        // 播放页布局已按改造批迁进播放器「更多」菜单（设置值不丢、
        // 仍是 PlayerLayoutPreferences 同一支偏好）。
        itemsBuilder: (context) => [
          _themeModeItem(),
          if (isDarkAppearance(
            systemBrightness: MediaQuery.platformBrightnessOf(context),
          ))
            _oledModeItem(),
          _backgroundItem(),
          if (!isWindowsDesktop)
            SettingsItem(
              icon: LucideIcons.layout_grid,
              title: '底部导航管理',
              subtitle: '排序、隐藏与恢复底栏页签',
              onTap: (context, _) => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const BottomNavManagePage(),
                ),
              ),
            ),
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
          if (!isWindowsDesktop) _audioCapsuleItem(),
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
        subtitle: '工具',
        // 播放相关六行（默认静音/跳片头片尾/去广告/自动回退/悬浮窗/
        // 视频解码器）已按改造批迁进播放器「更多」菜单，设置值不丢、
        // 仍走各自原偏好；这里只留 bytevc2 验证这个工具入口（不搬）。
        // 直播设置整类同批摘除：解码行与播放器菜单重复、睡眠默认
        // 迁进直播全屏页的定时弹窗（同一支 LiveSettingsStore 偏好）。
        items: [
          if (!isWindowsDesktop)
            SettingsItem(
              icon: LucideIcons.file_video_camera,
              title: 'bytevc2 转码验证',
              subtitle: '验随包转码器在本机能否落盘、执行与真转码（43 轮验证）',
              onTap: (context, _) => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const Bytevc2VerifyPage(),
                ),
              ),
            ),
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
        icon: LucideIcons.user,
        title: '账号',
        subtitle: '红果账号登录、云端收藏与续播',
        items: [
          SettingsItem(
            icon: LucideIcons.user,
            title: '红果账号',
            subtitle: '手机号登录 / 扫码登录，云端收藏、历史与预约',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const HongguoLoginPage(),
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
          _siteHealthEnabledItem(),
          _siteHealthPickerSortItem(),
          _siteHealthClearItem(),
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
      SettingsCategory(
        icon: LucideIcons.info,
        title: '关于',
        subtitle: '软件更新与版本',
        items: [
          SettingsItem(
            icon: LucideIcons.refresh_cw,
            title: '软件更新',
            subtitle: '检查新版本、下载并安装',
            onTap: (context, _) => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AppUpdatePage()),
            ),
          ),
        ],
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
    // 选文件失败的文案：直接写在弹窗里（弹窗盖在页上，SnackBar 会被
    // 弹窗挡住看不见），与“选文件失败：原因”同款前缀。
    var pickError = '';
    final urlController = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          backgroundColor: moyiSheetFill,
          title: Text(
            jsonOnly ? 'JSON 书源导入' : '书源导入',
            style: const TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              OutlinedButton.icon(
                onPressed: () async {
                  try {
                    final picked = await pickTextFile(
                      label: 'JSON',
                      extensions: ['json'],
                    );
                    if (picked == null) return;
                    setDialogState(() {
                      text = picked.content;
                      pickedName = picked.name;
                      pickError = '';
                    });
                  } catch (e) {
                    setDialogState(() => pickError = '选文件失败：$e');
                  }
                },
                icon: const Icon(Icons.folder_open),
                label: const Text('选择 JSON 文件'),
              ),
              const SizedBox(height: 8),
              Text(
                pickedName.isEmpty ? '未选择文件' : '已选：$pickedName',
                style: const TextStyle(fontSize: 12, color: moyiMutedOnDark),
              ),
              if (pickError.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  pickError,
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.redAccent,
                  ),
                ),
              ],
              if (!jsonOnly) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: urlController,
                  keyboardType: TextInputType.url,
                  style: const TextStyle(color: Colors.white),
                  decoration: const InputDecoration(
                    labelText: '远程书源地址',
                    hintText: '粘贴远程书源地址 http(s)://…',
                    labelStyle: TextStyle(color: moyiMutedOnDark),
                    hintStyle: TextStyle(color: moyiMutedOnDark),
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
              style: TextButton.styleFrom(foregroundColor: moyiBodyOnDark),
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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _appearance.label,
              style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 18, color: moyiMutedOnDark),
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
        backgroundColor: moyiSheetFill,
        title: const Text('主题模式', style: TextStyle(color: Colors.white)),
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
                    title: Text(
                      choice.label,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: choice == _AppearanceChoice.eink
                        ? const Text(
                            '纯黑白、无毛玻璃、无过渡动画，适合墨水屏设备',
                            style: TextStyle(color: moyiMutedOnDark),
                          )
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
              border: Border.all(color: moyiDarkCardBorder),
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
        backgroundColor: moyiSheetFill,
        title: const Text('背景主题', style: TextStyle(color: Colors.white)),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(LucideIcons.ban, color: moyiBodyOnDark),
                title: const Text('默认', style: TextStyle(color: Colors.white)),
                subtitle: const Text(
                  '跟随主题画布',
                  style: TextStyle(color: moyiMutedOnDark),
                ),
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
                  title: Text(
                    preset.name,
                    style: const TextStyle(color: Colors.white),
                  ),
                  onTap: () => Navigator.pop(context, preset.id),
                ),
              ListTile(
                leading: const Icon(LucideIcons.image, color: moyiBodyOnDark),
                title: const Text('从相册选图', style: TextStyle(color: Colors.white)),
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
      // 选图器本身可能起不来（权限被拒/容器无相册桥）：单独套 try，
      // 失败给明确提示，不让异常从点击处理里裸奔出去（B3 核查补）。
      XFile? file;
      try {
        file = await ImagePicker().pickImage(source: ImageSource.gallery);
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('选图失败：$e')));
        }
        return;
      }
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

  // ── 阅读 ──────────────────────────────────────────────────────────────


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

  /// 切后台且听书在播时在桌面显示灵动岛胶囊（封面 + 标题 + 播放/暂停
  /// + 关闭），点胶囊回听书页，回前台自动收起；悬浮窗权限拿不到时
  /// 只有通知栏控制。开启流程照抄视频悬浮窗开关：无权限先打开系统
  /// 设置让用户授予，授予后回来再点一次。
  SettingsItem _audioCapsuleItem() => SettingsItem(
    icon: LucideIcons.audio_lines,
    title: '后台灵动岛胶囊',
    subtitle: '切到后台且听书在播时在桌面显示悬浮胶囊，需要悬浮窗权限',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: AudioPreferences.instance.audioCapsule,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '后台灵动岛胶囊',
        onChanged: (enabled) => unawaited(_setAudioCapsule(context, enabled)),
      ),
    ),
    onTap: (context, setState) {
      final current = AudioPreferences.instance.audioCapsule.value;
      unawaited(_setAudioCapsule(context, !current));
    },
  );

  Future<void> _setAudioCapsule(BuildContext context, bool enabled) async {
    if (!enabled) {
      await AudioPreferences.instance.setAudioCapsule(false);
      return;
    }
    if (await NativePlayer.canDrawOverlays()) {
      await AudioPreferences.instance.setAudioCapsule(true);
      return;
    }
    await NativePlayer.requestOverlayPermission();
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请在系统设置中允许“显示在其他应用的上层”，然后回来再开启')),
      );
    }
  }

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
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              value.label,
              style: TextStyle(fontSize: 13, color: moyiMutedOnDark),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevron_right, size: 18, color: moyiMutedOnDark),
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
        backgroundColor: moyiSheetFill,
        title: const Text('听书变速引擎', style: TextStyle(color: Colors.white)),
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
                    title: Text(
                      value.label,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(switch (value) {
                      AudioRateEngine.wsola =>
                        '与番茄官方同一套算法（FFmpeg atempo），高倍速听感最接近原声',
                      AudioRateEngine.platform => '系统混音器变速，不依赖本应用的 native 库',
                      AudioRateEngine.builtIn =>
                        'Media3 内建 Sonic，最稳（默认，1.0.121 的行为）',
                    }, style: const TextStyle(color: moyiMutedOnDark)),
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

  // ── 站源：站点健康学习（魔蚁同步批 A3）────────────────────────

  /// 总开关（默认开）：按搜索 / 详情 / 播放成功率学习站点健康度，
  /// 供搜索调度与选站弹窗状态点使用；关时不打点不排序。
  SettingsItem _siteHealthEnabledItem() => SettingsItem(
    icon: LucideIcons.activity,
    title: '站点健康排序',
    subtitle: '按搜索 / 详情 / 播放成功率优先调度健康站',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: SiteHealthPrefs.instance.enabled,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '站点健康排序',
        onChanged: (v) => unawaited(SiteHealthPrefs.instance.setEnabled(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = SiteHealthPrefs.instance.enabled.value;
      unawaited(SiteHealthPrefs.instance.setEnabled(!current));
    },
  );

  /// 选站弹窗按健康排序（默认关）：开了弹窗里组内站点按健康分
  /// 降序；默认关保持登记表里的站点顺序。
  SettingsItem _siteHealthPickerSortItem() => SettingsItem(
    icon: LucideIcons.arrow_down_wide_narrow,
    title: '选站弹窗按健康排序',
    subtitle: '切换站点时把更稳的站排前面，默认关',
    trailingBuilder: (context) => ValueListenableBuilder<bool>(
      valueListenable: SiteHealthPrefs.instance.pickerSort,
      builder: (context, value, _) => SettingsSwitch(
        value: value,
        semanticLabel: '选站弹窗按健康排序',
        onChanged: (v) => unawaited(SiteHealthPrefs.instance.setPickerSort(v)),
      ),
    ),
    onTap: (context, setState) {
      final current = SiteHealthPrefs.instance.pickerSort.value;
      unawaited(SiteHealthPrefs.instance.setPickerSort(!current));
    },
  );

  /// 清空健康记录：删掉已学习的成败计数，全部站回到未知。
  SettingsItem _siteHealthClearItem() => SettingsItem(
    icon: LucideIcons.trash,
    title: '清空健康记录',
    subtitle: '删除已学习的站点成败记录，全部站回到未知',
    onTap: (context, setState) => _confirmClear(
      context,
      '清空健康记录',
      '将删除已学习的站点成败记录，全部站回到未知状态。',
      () => SiteHealthStore.instance.clear(),
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
