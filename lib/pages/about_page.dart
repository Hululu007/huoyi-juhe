import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

import '../widgets/home/home_design.dart';
import '../widgets/settings/settings_widgets.dart';

/// About page styled after PiliPlus: centered logo/name header, a short
/// intro paragraph, then grouped card rows (version, updates, licenses,
/// source code, ...).
class AboutPage extends StatelessWidget {
  const AboutPage({super.key});

  /// Display version, kept in lockstep with pubspec.yaml's
  /// `version`. Without a package_info dependency the value is
  /// static, so test/about_version_test.dart parses the pubspec and fails the
  /// build check when the two drift apart after a version bump.
  static const versionText = '1.0.200 (205)';

  /// Pixel width of the bundled logo (assets/images/app_logo.webp). The logo
  /// is displayed at 80dp, so it only needs re-decoding above 4× DPI; clamping
  /// to the asset's real width keeps a high-DPI device from asking the decoder
  /// to upscale a surface the asset does not have. Keep it in sync with
  /// LOGO_SIZE in scripts/generate_app_icons.py.
  static const _logoPixelWidth = 384;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = HomePalette.of(context);

    return SettingsScaffold(
      title: '关于',
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        children: [
          const _AboutLogo(),
          const SizedBox(height: 12),
          const _AboutHeading(),
          const SizedBox(height: 16),
          Text(
            '什锦铺把小说、短剧、漫剧、漫画和听书聚到一起。'
            '所有签名与解密都在你的手机本地完成，不依赖第三方服务。',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: palette.muted,
              height: 1.55,
            ),
          ),
          const SizedBox(height: 12),
          const _AboutInfoCard(),
          const SizedBox(height: 24),
          Center(
            child: Text(
              '仅限个人学习研究使用\n请遵守相关法律法规',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: palette.muted, height: 1.5),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  /// 版本行点按：把版本号写进剪贴板，并用 SnackBar 明示已复制。
  static void _copyVersion(BuildContext context) {
    unawaited(Clipboard.setData(const ClipboardData(text: versionText)));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已复制版本号')));
  }
}

/// 头部 logo：全幅图片，圆角与投影跟随图版的 15% 板式圆角。
class _AboutLogo extends StatelessWidget {
  const _AboutLogo();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Center(
      // The bundled logo is full-bleed; 12 of 80 keeps the plate's 15%
      // corner radius so the image and the shadow outline agree.
      child: Container(
        key: const ValueKey('about-logo-plate'),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          // 墨水屏没有彩色投影可投；留一圈阴影只会糊成一团黑。
          boxShadow: palette.eink
              ? null
              : [
                  BoxShadow(
                    color: palette.accentText.withValues(alpha: 0.20),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.asset(
            'assets/images/app_logo.webp',
            width: 80,
            height: 80,
            // Decode at the display size rather than the whole 384²
            // surface, which would hold ~590 KB in the image cache for a
            // 80dp logo.
            cacheWidth: (80 * MediaQuery.devicePixelRatioOf(context))
                .round()
                .clamp(80, AboutPage._logoPixelWidth),
            fit: BoxFit.contain,
            excludeFromSemantics: true,
          ),
        ),
      ),
    );
  }
}

/// 头部应用名与一行定位副标题。
class _AboutHeading extends StatelessWidget {
  const _AboutHeading();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return Column(
      children: [
        Text(
          '什锦铺',
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 22,
            height: 1.25,
            fontWeight: FontWeight.bold,
            letterSpacing: -0.3,
            color: palette.ink,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '小说 / 短剧 / 漫剧 / 漫画 / 听书聚合客户端',
          textAlign: TextAlign.center,
          style: TextStyle(color: palette.muted, fontSize: 13),
        ),
      ],
    );
  }
}

/// 信息卡：版本（点按复制）、检查更新、开源许可、源码与反馈。
class _AboutInfoCard extends StatelessWidget {
  const _AboutInfoCard();

  @override
  Widget build(BuildContext context) {
    final palette = HomePalette.of(context);
    return SettingsGroupCard(
      children: [
        SettingsRow(
          icon: LucideIcons.badge_check,
          iconTile: true,
          title: '当前版本',
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                AboutPage.versionText,
                style: TextStyle(fontSize: 13, color: palette.muted),
              ),
              const SizedBox(width: 6),
              Icon(LucideIcons.copy, size: 15, color: palette.muted),
            ],
          ),
          onTap: () => AboutPage._copyVersion(context),
        ),
        SettingsRow(
          icon: LucideIcons.square_arrow_out_up_right,
          iconTile: true,
          title: '检查更新',
          subtitle: '前往 GitHub 发布页查看新版本',
          onTap: () => _launchExternalUrl(
            context,
            'https://github.com/ch6vip/fqapp/releases',
          ),
        ),
        SettingsRow(
          icon: LucideIcons.scale,
          iconTile: true,
          title: '开源许可',
          subtitle: 'GPL-3.0 与第三方组件许可',
          onTap: () => showLicensePage(
            context: context,
            applicationName: '什锦铺',
            applicationVersion: AboutPage.versionText,
            applicationLegalese: '什锦铺基于 GPL-3.0 协议开源，第三方组件遵循其各自的许可协议。',
          ),
        ),
        SettingsRow(
          icon: LucideIcons.code_xml,
          iconTile: true,
          title: '源代码',
          subtitle: 'github.com/ch6vip/fqapp',
          onTap: () =>
              _launchExternalUrl(context, 'https://github.com/ch6vip/fqapp'),
        ),
      ],
    );
  }
}

/// 用外部应用打开 [url]。Android 的包可见性可能让浏览器对 canLaunchUrl
/// 不可见，但仍能处理 ACTION_VIEW，所以这里不做预检查，失败统一走可见提示。
Future<void> _launchExternalUrl(BuildContext context, String url) async {
  final uri = Uri.parse(url);
  var launched = false;
  try {
    launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
  } catch (_) {
    // Report launch failures through the same visible fallback.
  }
  if (!launched && context.mounted) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('无法打开链接')));
  }
}

