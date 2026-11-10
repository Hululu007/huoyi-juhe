import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../services/cultivation.dart';
import '../cultivation_title_label.dart';
import '../game_hero_portrait.dart';
import '../series_detail/moyi_detail_theme.dart';
import 'cultivation_profile_card_data.dart';

export 'cultivation_profile_card_data.dart';

/// 我的页顶部深色「道友档案」卡（按用户发的别家截图版式重做）。
///
/// 横向宽卡，占满宽度，深色底 + 金色点缀、圆角；左边约 2/3 是信息，
/// 右边约 1/3 是精修人物大图（资源图，按性别切换：白发女修 /
/// 白发男修），占满卡高，圆角裁切贴合卡片，不用 Flutter 手画小人。
/// 卡片宽高比约 2:1（390 宽屏上约 358x190）。
///
/// 左边从上到下：顶部小字“◆ 道友档案 ◆”（整卡居中）；圆形金边境界徽章；
/// 境界名 + 小档大字（一行，FittedBox 缩小兜底）；观影数据行；
/// 主修 / 境界行；金色进度条；总修为 + 到下一境界差多少；
/// 底部一排小药丸标签（主修 / 灵根 / 宗门 / 职业 / 称号 / 性别）。
/// 只改呈现：境界 / 等级 / 修为 / 称号 / 标签的取值都照现有代码，
/// 不动 cultivation.dart 的算分。
///
/// 人物会动：立绘缓慢上下浮动 + 呼吸缩放；隔 5 秒放一次招牌技能，
/// 点一下人物也放一次。女：双手合十放大招（青色光晕 + 扩散光环 +
/// 上升灵光）；男：拔剑万剑归宗（金色剑光 + 九剑齐出 + 剑气横扫）。
/// 静态图姿势不变，动效演的是放招的光效与剑阵，不是换姿势。
class CultivationProfileCard extends StatelessWidget {
  const CultivationProfileCard({
    super.key,
    required this.totalTitles,
    required this.onOpenTitles,
  });

  /// 看过多少部（去重后的历史条目数，由我的页传入）。
  final int totalTitles;

  /// 打开称号排行榜。
  final VoidCallback onOpenTitles;

  static const _gold = moyiGold;
  static const _goldBright = Color(0xFFFFD54F);
  static const _muted = moyiMutedOnDark;
  static const _subText = moyiBodyOnDark;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CultivationSnapshot>(
      valueListenable: CultivationService.instance.snapshotNotifier,
      builder: (context, snapshot, _) {
        final realm = snapshot.realm;
        final currentTitle = currentTitleTier(
          snapshot.totalXp,
          sect: snapshot.sect,
        );
        final isFemale = snapshot.gender == CultivationGender.female;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              color: moyiDarkCardFill,
              border: Border.all(
                color: _gold.withValues(alpha: 0.35),
                width: 1,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(16),
              child: Stack(
                children: [
                  IntrinsicHeight(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(14, 22, 8, 6),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                _titleRow(realm.groupName),
                                const SizedBox(height: 2),
                                _realmRow(context, snapshot, realm),
                                const SizedBox(height: 2),
                                _watchRow(snapshot),
                                const SizedBox(height: 1),
                                _techniqueRow(snapshot, realm),
                                const SizedBox(height: 2),
                                _progressRow(realm, snapshot),
                                const SizedBox(height: 3),
                                _tagsRow(context, snapshot, currentTitle),
                              ],
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 116,
                          child: _ProfileFigure(isFemale: isFemale),
                        ),
                      ],
                    ),
                  ),
                  const Positioned(
                    top: 6,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: Text(
                        '◆ 道友档案 ◆',
                        style: TextStyle(
                          fontSize: 12,
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                          color: _gold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  // 窄屏 + 大字号下标题与境界组徽章会挤爆：标题可缩放、徽章可省略，
  // 徽章（下境界·人界 6 字）本身不缩放，只截尾。
  Widget _titleRow(String groupName) {
    return Row(
      children: [
        const Icon(Icons.auto_graph, size: 14, color: _goldBright),
        const SizedBox(width: 6),
        Flexible(
          child: FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: const Text(
              '道友档案',
              style: TextStyle(
                fontSize: 13,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ),
        ),
        const Spacer(),
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: _gold.withValues(alpha: 0.14),
            ),
            child: Text(
              groupName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 10,
                height: 1.2,
                color: _gold,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _realmRow(
    BuildContext context,
    CultivationSnapshot snapshot,
    RealmInfo realm,
  ) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        _realmBadge(context, realm),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(
                  realm.displayName,
                  style: const TextStyle(
                    fontSize: 17,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  // 窄屏 + 大字号下等级徽章会把用户名挤爆：徽章可缩、文字截尾。
                  Flexible(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        color: _gold.withValues(alpha: 0.18),
                        border: Border.all(color: _gold.withValues(alpha: 0.5)),
                      ),
                      child: Text(
                        realm.levelLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontSize: 11,
                          height: 1.2,
                          fontWeight: FontWeight.w700,
                          color: _gold,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: InkWell(
                      onTap: () => _showRenameDialog(context, snapshot),
                      borderRadius: BorderRadius.circular(4),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              snapshot.username.isEmpty
                                  ? '道友'
                                  : snapshot.username,
                              style: const TextStyle(
                                fontSize: 12,
                                height: 1.2,
                                color: _subText,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 3),
                          const Icon(
                            Icons.edit_outlined,
                            size: 12,
                            color: _muted,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 圆形境界徽章：点开称号排行榜。
  Widget _realmBadge(BuildContext context, RealmInfo realm) {
    return InkWell(
      onTap: onOpenTitles,
      customBorder: const CircleBorder(),
      child: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: const Color(0xFF23233A),
          border: Border.all(color: _gold, width: 1.5),
        ),
        alignment: Alignment.center,
        // 36px 圆徽章里的两行字：大字号下会换行撑爆，整体等比缩小放得下。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                realm.badgeLine1,
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  fontWeight: FontWeight.w700,
                  color: _goldBright,
                ),
              ),
              Text(
                realm.badgeLine2,
                style: const TextStyle(
                  fontSize: 9,
                  height: 1.2,
                  color: _goldBright,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 观影数据行：观影时长 + 看过多少部（照参考图的格式）。
  Widget _watchRow(CultivationSnapshot snapshot) {
    return Text.rich(
      TextSpan(
        children: [
          const TextSpan(
            text: '观影时长 ',
            style: TextStyle(fontSize: 12, height: 1.2, color: _gold),
          ),
          TextSpan(
            text: _formatWatchTime(snapshot.totalSeconds),
            style: const TextStyle(
              fontSize: 13,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: _goldBright,
            ),
          ),
          const TextSpan(
            text: ' 观影 ',
            style: TextStyle(fontSize: 12, height: 1.2, color: _gold),
          ),
          TextSpan(
            text: '$totalTitles 部',
            style: const TextStyle(
              fontSize: 13,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: _goldBright,
            ),
          ),
        ],
      ),
    );
  }

  /// 主修 / 境界行：主修 + 境界修士（如“主修·小说 · 结丹期修士”）。
  Widget _techniqueRow(CultivationSnapshot snapshot, RealmInfo realm) {
    final main = snapshot.mainCategory;
    final head = main != null
        ? '主修·${cultivationCategoryName(main)}'
        : (snapshot.profession.isNotEmpty ? snapshot.profession : null);
    final text = head == null
        ? '${realm.badgeLine1}修士'
        : '$head · ${realm.badgeLine1}修士';
    return Text(
      text,
      style: const TextStyle(fontSize: 12, height: 1.2, color: _gold),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _progressRow(RealmInfo realm, CultivationSnapshot snapshot) {
    if (realm.nextRealmName == null) {
      return const Text(
        '已达顶峰 · 道祖',
        style: TextStyle(fontSize: 12, color: _gold),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: realm.progress,
            minHeight: 4,
            backgroundColor: Colors.white.withValues(alpha: 0.14),
            valueColor: const AlwaysStoppedAnimation<Color>(_gold),
          ),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            Text(
              '总修为 ${formatCultivationXp(snapshot.totalXp)}',
              style: const TextStyle(
                fontSize: 11,
                height: 1.2,
                fontWeight: FontWeight.w700,
                color: _goldBright,
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                '距离还差 ${realm.xpToNext} 修为',
                style: const TextStyle(
                  fontSize: 10,
                  height: 1.2,
                  color: _subText,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _tagsRow(
    BuildContext context,
    CultivationSnapshot snapshot,
    CultivationTitleTier? currentTitle,
  ) {
    final main = snapshot.mainCategory;
    final tags = <String>[
      if (main != null) '主修·${cultivationCategoryName(main)}',
      '灵根·${snapshot.spiritRoot}',
      if (snapshot.sect.isNotEmpty) '宗门·${snapshot.sect}',
      if (snapshot.profession.isNotEmpty) '职业·${snapshot.profession}',
      if (snapshot.gender != null)
        '性别·${cultivationGenderName(snapshot.gender!)}',
    ];
    // 底部小药丸标签：Wrap 全部露出，不横向滚动藏起来。
    final children = <Widget>[
      for (final tag in tags) _tagPill(tag),
      if (currentTitle?.titleName != null)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            color: _gold.withValues(alpha: 0.16),
            border: Border.all(color: _gold.withValues(alpha: 0.4)),
          ),
          child: CultivationTitleLabel(
            title: currentTitle!.titleName!,
            effect: currentTitle.effect,
            style: const TextStyle(
              fontSize: 9,
              height: 1.2,
              fontWeight: FontWeight.w700,
              color: _goldBright,
            ),
          ),
        ),
    ];
    return Wrap(spacing: 5, runSpacing: 4, children: children);
  }

  Widget _tagPill(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 0),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
      ),
      child: Text(
        tag,
        style: const TextStyle(fontSize: 9, height: 1.2, color: _subText),
      ),
    );
  }

  /// 观影总时长：不足 1 小时显示“x分钟”，否则显示“x.x h”（整小时不带小数）。
  String _formatWatchTime(double totalSeconds) {
    final minutes = totalSeconds / 60;
    if (minutes < 60) return '${minutes.round()}分钟';
    final hours = minutes / 60;
    final value = hours.toStringAsFixed(1);
    final trimmed = value.endsWith('.0')
        ? value.substring(0, value.length - 2)
        : value;
    return '$trimmed h';
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    CultivationSnapshot snapshot,
  ) async {
    final controller = TextEditingController(text: snapshot.username);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('改名'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '用户名',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确定'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (ok == true) {
      await CultivationService.instance.renameUser(controller.text);
    }
  }
}

/// 卡片右侧人物立绘：缓慢上下浮动 + 呼吸缩放；隔 5 秒放一次招牌技能，
/// 点一下人物也放一次。动效只改呈现，不动档案数据。
class _ProfileFigure extends StatefulWidget {
  const _ProfileFigure({required this.isFemale});

  final bool isFemale;

  @override
  State<_ProfileFigure> createState() => _ProfileFigureState();
}

class _ProfileFigureState extends State<_ProfileFigure>
    with TickerProviderStateMixin {
  late final AnimationController _idle;
  late final AnimationController _burst;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _idle = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3200),
    )..repeat();
    _burst = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _unleash());
  }

  void _unleash() {
    if (!mounted) return;
    _burst.forward(from: 0);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _idle.dispose();
    _burst.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey('profile-figure'),
      onTap: _unleash,
      behavior: HitTestBehavior.opaque,
      child: AnimatedBuilder(
        animation: Listenable.merge([_idle, _burst]),
        builder: (context, child) {
          final t = _idle.value;
          final floatY = math.sin(t * 2 * math.pi) * 4.0;
          final breathe = 1.0 + 0.015 * math.sin(t * 2 * math.pi);
          final b = _burst.value;
          final burstScale = 1.0 + 0.07 * math.sin(b * math.pi);
          return Stack(
            clipBehavior: Clip.none,
            children: [
              if (b > 0)
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BurstPainter(
                      progress: b,
                      isFemale: widget.isFemale,
                    ),
                  ),
                ),
              Transform.translate(
                offset: Offset(0, floatY),
                child: Transform.scale(
                  scale: breathe * burstScale,
                  child: child,
                ),
              ),
            ],
          );
        },
        child: Image.asset(
          gameHeroAssetForGender(widget.isFemale),
          fit: BoxFit.cover,
          alignment: Alignment.bottomCenter,
          errorBuilder: (context, error, stackTrace) => Image.asset(
            widget.isFemale
                ? gameHeroFemaleLegacyAsset
                : gameHeroMaleLegacyAsset,
            fit: BoxFit.cover,
          ),
        ),
      ),
    );
  }
}

/// 放招特效：女放青色光晕 + 扩散光环 + 上升灵光（双手合十放大招）；
/// 男放金色剑光 + 九剑齐出 + 剑气横扫（拔剑万剑归宗）。
/// 只画光效与剑形，不改人物姿势（静态图姿势变不了）。
class _BurstPainter extends CustomPainter {
  _BurstPainter({required this.progress, required this.isFemale});

  final double progress;
  final bool isFemale;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height * 0.42);
    final p = progress;
    final glowColor = isFemale
        ? const Color(0xFF9FE8FF)
        : const Color(0xFFFFD54F);
    final glowOpacity = (math.sin(p * math.pi) * 0.55).clamp(0.0, 1.0);
    if (glowOpacity > 0.01) {
      final radius = size.width * (0.55 + 0.45 * p);
      final glowPaint = Paint()
        ..shader = RadialGradient(
          colors: [
            glowColor.withValues(alpha: glowOpacity),
            Colors.transparent,
          ],
        ).createShader(Rect.fromCircle(center: c, radius: radius));
      canvas.drawCircle(c, radius, glowPaint);
    }
    if (isFemale) {
      for (var i = 0; i < 2; i++) {
        final rp = (p * 1.3 - i * 0.18).clamp(0.0, 1.0);
        if (rp <= 0 || rp >= 1) continue;
        final ringPaint = Paint()
          ..color = const Color(0xFFBFEFFF).withValues(alpha: (1 - rp) * 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0;
        canvas.drawCircle(c, size.width * (0.18 + 0.55 * rp), ringPaint);
      }
      final sparkPaint = Paint();
      for (var i = 0; i < 7; i++) {
        final a = i / 7 * math.pi * 2;
        final r = size.width * (0.12 + 0.38 * p);
        final x = c.dx + math.cos(a) * r;
        final y = c.dy - p * size.height * 0.28 - math.sin(a) * 6;
        final o = (1 - p) * 0.9;
        if (o <= 0.02) continue;
        sparkPaint.color = const Color(0xFFDFF8FF).withValues(alpha: o);
        canvas.drawCircle(Offset(x, y), 1.6 + 1.2 * (1 - p), sparkPaint);
      }
    } else {
      const n = 9;
      for (var i = 0; i < n; i++) {
        final a = -math.pi / 2 + (i - (n - 1) / 2) * 0.36;
        final d = size.width * (0.10 + 0.42 * p);
        final dir = Offset(math.cos(a), math.sin(a) * 0.9);
        final tip = c + dir * d;
        final o = p < 0.15 ? p / 0.15 : (1 - p);
        if (o <= 0.02) continue;
        final blade = Paint()
          ..color = const Color(
            0xFFEAF7FF,
          ).withValues(alpha: o.clamp(0.0, 1.0) * 0.9)
          ..strokeWidth = 2.5
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(tip - dir * 22, tip, blade);
        final guardPaint = Paint()
          ..color = const Color(
            0xFFFFD54F,
          ).withValues(alpha: o.clamp(0.0, 1.0) * 0.8);
        canvas.drawCircle(tip - dir * 22, 2.2, guardPaint);
      }
      final beamO = math.sin(p * math.pi) * 0.5;
      if (beamO > 0.02) {
        final beamPaint = Paint()
          ..color = Colors.white.withValues(alpha: beamO)
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round;
        final y = c.dy + (p - 0.5) * 30;
        canvas.drawLine(
          Offset(c.dx - size.width * 0.45, y - 18),
          Offset(c.dx + size.width * 0.45, y + 18),
          beamPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _BurstPainter old) =>
      old.progress != progress || old.isFemale != isFemale;
}
