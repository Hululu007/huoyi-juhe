import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/cultivation.dart';

/// 档案卡人物：站立施法的成年卡通人物（男帅哥男、女靓妹女，只分男女，
/// 不做孩童体型），全部用 [CustomPainter] 画，不依赖外部图片素材。
/// 人物站着 / 腾空施法，不是盘腿打坐：脚下是发光台、身后是大圆环。
///
/// 画风：2.5D 动漫风，按凡人修仙传游戏（百游那版）2.5D 人物画——
/// 带立体感和明暗、有厚度，不是扁平简笔画，也不是纯 3D。
/// 男版按用户发的韩立图画：蓝金袍 + 金色云纹刺绣（肩头金云纹护肩、
/// 胸前金云纹）、长发垂胸 + 横发簪、五官精致冷峻（细长眼、薄唇、
/// 不笑）；女版按用户发的紫灵 / 南宫婉图画：长发飘飞、金冠、
/// 面纱、紫金 / 青白飘带，仙气飘飘、衣袂飘飞——裙色跟所选服饰走，
/// 紫色锦袍即紫灵紫裙、青色道袍 / 月白儒衫即南宫婉青白裙。
///
/// 脸：眉毛、眼睛（眼白 + 虹膜 + 瞳孔 + 高光，不是两个点）、鼻子
/// （鼻梁阴影）、嘴（唇形；男版薄唇冷峻、女版粉唇）、面部阴影层次
/// （颧骨 / 下颌）、耳朵；女性版更柔和（长睫毛、眉形弯、唇色粉），
/// 另有半透明面纱遮住口鼻下半脸（紫灵式）。
/// 身材：成年比例，头身比约 1:4.5（站姿），不头大身子小。
/// 道袍：衣褶（深色褶线 + 浅色高光）、腰带（带扣 + 明暗）、领口
/// 层次（内外领）、袍面渐变（左上亮、右下暗，2.5D 体积感）。
/// 长发：男版韩立式长发垂到胸前、脑后也有长发，发间一根横发簪；
/// 女版长发垂到腰际、发尾随呼吸飘动。
///
/// 平时凌空微浮、呼吸起伏（上下轻浮 + 光晕脉动 + 光点上升）；隔几秒
/// 放一次本职业招牌技能，点一下小人也能立刻放技能：
/// - 天道（剑修）青元剑诀 / 大庚剑阵：平时青竹蜂云剑（绿剑）在手、
///   两三把小绿剑慢速绕身；放技能时多把绿剑从身后升起、绕身成剑圈
///   布成剑阵（绿光阵环 + 剑光连线），再向前收束斩出，左手掌前推、
///   掌心一团绿光（韩立施展青元剑诀式）。
/// - 逍遥（身法/飞轮）真魔功：平时两只飞轮低透明度慢速绕身；
///   放技能时残影闪烁瞬移，飞轮高速旋转。
/// - 金刚（防御/反伤）泰阳诀：平时周身一层很淡的金色护罩轮廓；
///   放技能时护罩亮起，罩面流光与反伤波纹。
/// 三职业平时也有武器/护罩在身，不只放技能时才出现；技能一眼能
/// 分出：天道是绿剑、逍遥是飞轮 + 残影、金刚是金罩。
/// 服饰（6 套古代服饰）、脸型（3 款）、发型（3 款）、发色（3 色）
/// 都在人物身上画出来：男版袍色 / 镶边 / 腰带 / 纹样按服饰走，
/// 金云纹刺绣与肩头护肩是韩立式固定装饰；
/// 女版裙色按所选服饰走（紫袍紫裙、白袍白青裙），金饰与飘带固定，
/// 头形按脸型走，发式按发型走（女版三种发型都是长发垂下，只是盘发
/// / 披散 / 马尾的扎法不同），发色按所选发色走。
class MeditatingAvatar extends StatefulWidget {
  const MeditatingAvatar({
    super.key,
    this.size = 120,
    this.isFemale = false,
    this.costume,
    this.profession = defaultCultivationProfession,
    this.face = defaultCultivationFace,
    this.hairstyle = defaultCultivationHairstyle,
    this.hairColor,
    this.autoCastSkill = true,
  });

  /// 宽高（正方形）。
  final double size;

  /// 性别微调：男帅哥男、女靓妹女，体型与发式区分，不做孩童体型。
  final bool isFemale;

  /// 服饰（默认青色道袍）。
  final CultivationCostume? costume;

  /// 职业（天道/逍遥/金刚），决定放什么技能。
  final String profession;

  /// 脸型（瓜子脸/方脸/圆脸）。
  final String face;

  /// 发型（道髻/披发/高马尾）。
  final String hairstyle;

  /// 发色（默认黑）。
  final CultivationHairColor? hairColor;

  /// 是否隔几秒自动放一次技能（默认开；点按始终能放）。
  final bool autoCastSkill;

  @override
  State<MeditatingAvatar> createState() => _MeditatingAvatarState();
}

class _MeditatingAvatarState extends State<MeditatingAvatar>
    with TickerProviderStateMixin {
  late final AnimationController _breathe;
  late final AnimationController _skill;
  Timer? _skillTimer;

  @override
  void initState() {
    super.initState();
    _breathe = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
    _skill = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    );
    if (widget.autoCastSkill) {
      _skillTimer = Timer.periodic(const Duration(seconds: 7), (_) {
        _castSkill();
      });
    }
  }

  /// 放一次技能（已在放时不重复触发）。
  void _castSkill() {
    if (!mounted || _skill.isAnimating) return;
    _skill.forward(from: 0);
  }

  @override
  void dispose() {
    _skillTimer?.cancel();
    _breathe.dispose();
    _skill.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: _castSkill,
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([_breathe, _skill]),
            builder: (context, child) => CustomPaint(
              size: Size.square(widget.size),
              painter: _MeditatingAvatarPainter(
                progress: _breathe.value,
                skillProgress: _skill.value,
                profession: widget.profession,
                costume: widget.costume ?? cultivationCostumes.first,
                face: widget.face,
                hairstyle: widget.hairstyle,
                hairColor:
                    widget.hairColor ?? cultivationHairColors.first,
                isFemale: widget.isFemale,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 颜色小工具：加深 / 提亮（2.5D 明暗都靠它算）。
Color _shade(Color c, double f) =>
    Color.lerp(c, const Color(0xFF000000), f.clamp(0.0, 1.0))!;
Color _tint(Color c, double f) =>
    Color.lerp(c, const Color(0xFFFFFFFF), f.clamp(0.0, 1.0))!;

/// 一帧的画法：光晕、人物（呼吸浮动）、技能层、上升光点。
/// 几何按画布尺寸的比例算，只有呼吸浮动是固定逻辑像素（约 ±4）。
class _MeditatingAvatarPainter extends CustomPainter {
  _MeditatingAvatarPainter({
    required this.progress,
    required this.skillProgress,
    required this.profession,
    required this.costume,
    required this.face,
    required this.hairstyle,
    required this.hairColor,
    this.isFemale = false,
  });

  /// 呼吸循环 0..1。
  final double progress;

  /// 技能进度 0..1（0 = 没放技能）。
  final double skillProgress;

  /// 职业（天道/逍遥/金刚）。
  final String profession;

  /// 服饰。
  final CultivationCostume costume;

  /// 脸型。
  final String face;

  /// 发型。
  final String hairstyle;

  /// 发色。
  final CultivationHairColor hairColor;

  final bool isFemale;

  // 上升光点：各有横向位置与大小。
  static const _dotSlots = <double>[0.16, 0.30, 0.44, 0.58, 0.72, 0.86];
  static const _dotRadii = <double>[2.2, 1.6, 2.6, 1.8, 2.2, 1.5];

  // 青元剑诀 / 大庚剑阵的飞剑数。
  static const _swordCount = 7;

  // 脸部几何（相对画布）：头中心、脸半宽/半高按脸型算。
  // 站姿：头顶约 0.08h、脚约 0.82h，头身比约 1:4.5，不头大身子小。
  double get _headCy => 0.235;
  double _faceRx(double w) => isFemale
      ? w * 0.080
      : switch (face) {
          '方脸' => w * 0.092,
          '圆脸' => w * 0.092,
          _ => w * 0.085,
        };
  double _faceRy(double h) => switch (face) {
        '方脸' => h * 0.082,
        '圆脸' => h * 0.088,
        _ => h * 0.086,
      };

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cycle = progress * math.pi * 2;

    // 呼吸：上下轻浮（±4px）+ 轻微缩放。
    final breathe = math.sin(cycle);
    final floatY = breathe * 4;
    final scale = 1 + 0.02 * breathe;

    // 光晕：大小与透明度缓慢脉动，与呼吸错开相位；外圈冷蓝、
    // 内圈暖金，两层叠出 2.5D 氛围。
    final haloPulse = math.sin(cycle - math.pi / 3);
    final haloRadius = w * 0.38 * (1 + 0.07 * haloPulse);
    final haloAlpha = 0.16 + 0.09 * haloPulse;
    final haloCenter = Offset(cx, h * 0.46 + floatY * 0.5);
    canvas.drawCircle(
      haloCenter,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFB9A8F0).withValues(alpha: haloAlpha),
            const Color(0xFF9FD0F5).withValues(alpha: haloAlpha * 0.55),
            const Color(0xFF9FD0F5).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: haloCenter, radius: haloRadius)),
    );
    canvas.drawCircle(
      haloCenter,
      haloRadius * 0.62,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFFFE9A8).withValues(alpha: haloAlpha * 0.55),
            const Color(0xFFFFE9A8).withValues(alpha: 0),
          ],
        ).createShader(
          Rect.fromCircle(center: haloCenter, radius: haloRadius * 0.62),
        ),
    );

    // 脚下柔和地面阴影（椭圆 + 边缘虚化感的两层）。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, h * 0.86),
        width: w * 0.56,
        height: h * 0.05,
      ),
      Paint()..color = const Color(0xFF7C8DB5).withValues(alpha: 0.22),
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, h * 0.86),
        width: w * 0.44,
        height: h * 0.038,
      ),
      Paint()..color = const Color(0xFF5B6B8C).withValues(alpha: 0.30),
    );

    // 身后大圆环 + 脚下发光台（凡人修仙传选职业页式：人物站发光台、
    // 身后大圆环），平时就有，淡淡的，不抢人物。
    _drawBackdropRing(canvas, w, h, floatY);
    _drawPlatformGlow(canvas, w, h);

    // 逍遥·真魔功：残影画在人物身后（半透明、分身左右闪烁）。
    if (profession == '逍遥' && skillProgress > 0) {
      _drawAfterimages(canvas, w, h, floatY, scale);
    }

    // 金刚平时：周身一层很淡的金色护罩轮廓（放技能时才亮起）。
    if (profession == '金刚' && skillProgress == 0) {
      _drawShieldIdle(canvas, w, h, floatY);
    }
    // 逍遥平时：两只飞轮低透明度慢速绕身。
    if (profession == '逍遥' && skillProgress == 0) {
      _drawWheelsIdle(canvas, w, h, floatY);
    }

    // 天道平时：两三把小飞剑慢速绕身（放技能时才变七剑齐出）。
    if (profession == '天道' && skillProgress == 0) {
      _drawOrbitSwordsIdle(canvas, w, h, floatY);
    }

    canvas.save();
    canvas.translate(cx, h * 0.46 + floatY);
    // 金刚·泰阳诀：放技能时身形微微张开，姿态转沉稳扎实。
    final stanceScale =
        (profession == '金刚' && skillProgress > 0)
            ? 1 + 0.04 * math.sin(skillProgress * math.pi)
            : 1.0;
    canvas.scale(scale * stanceScale);
    canvas.translate(-cx, -h * 0.46);
    _drawFigure(canvas, w, h);
    canvas.restore();

    // 技能层（人物身前/身周的效果）。
    if (skillProgress > 0) {
      switch (profession) {
        case '天道':
          _drawSwords(canvas, w, h, floatY);
        case '逍遥':
          _drawWheels(canvas, w, h, floatY);
        case '金刚':
          _drawShield(canvas, w, h, floatY);
      }
    }

    _drawDots(canvas, w, h);
  }

  // ------------------------------------------------------------------
  // 人物主体：长发背发 → 袍身/长裙 → 领口 → 腰带 → 袖手 →
  // 膝上剑（天道）→ 脖子耳朵 → 脸 → 前发 → 白花（女）。
  // ------------------------------------------------------------------
  void _drawFigure(Canvas canvas, double w, double h) {
    // 男版韩立式长发先画在身后：从头顶垂到腰际、两侧飘逸的发瀑。
    // 女版长发 + 身后飘带同样先画在身后。
    if (isFemale) {
      _drawLongHairBack(canvas, w, h);
      _drawFemaleRibbonsBack(canvas, w, h);
    } else {
      _drawMaleLongHairBack(canvas, w, h);
    }

    // 站姿：袍身 / 长裙从肩垂到脚面（袍摆与鞋在袍函数里画）。
    if (isFemale) {
      _drawFemaleDress(canvas, w, h);
    } else {
      _drawMaleRobe(canvas, w, h);
    }

    _drawNeckAndEars(canvas, w, h);
    _drawHead(canvas, w, h);

    // 胸前碎发压在袍面外面：男版韩立式两缕长发垂到胸前。
    if (!isFemale) _drawMaleFrontLocks(canvas, w, h);
  }

  /// 男版脑后长发（韩立式）：从头顶垂到腰际的发瀑，披发最宽最长、
  /// 道髻半束略收、高马尾束起后发尾向一侧甩，带光泽发丝线。
  void _drawMaleLongHairBack(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final rx = _faceRx(w);
    final ry = _faceRy(h);
    final headCy = h * _headCy;
    final hairDark = _shade(hairColor.color, 0.25);
    final hairLight = _tint(hairColor.color, 0.30);
    // 呼吸飘动：发尾随呼吸左右轻摆。
    final sway = math.sin(progress * math.pi * 2) * w * 0.012;
    final spread = switch (hairstyle) {
      '披发' => 0.21,
      '高马尾' => 0.15,
      _ => 0.18,
    };
    final backPath = Path()
      ..moveTo(cx - rx * 0.9, headCy - ry * 0.6)
      ..quadraticBezierTo(cx - w * 0.16, headCy - ry * 1.1, cx, headCy - ry * 1.15)
      ..quadraticBezierTo(cx + w * 0.16, headCy - ry * 1.1, cx + rx * 0.9, headCy - ry * 0.6)
      ..quadraticBezierTo(cx + w * spread, h * 0.38, cx + w * (spread - 0.02) + sway, h * 0.58)
      ..quadraticBezierTo(cx + w * (spread - 0.01) + sway, h * 0.63, cx + w * 0.13 + sway, h * 0.60)
      ..quadraticBezierTo(cx + w * 0.12, h * 0.45, cx + rx * 0.8, h * 0.34)
      ..quadraticBezierTo(cx, h * 0.30, cx - rx * 0.8, h * 0.34)
      ..quadraticBezierTo(cx - w * 0.12, h * 0.45, cx - w * 0.13 + sway, h * 0.60)
      ..quadraticBezierTo(cx - w * (spread - 0.01) + sway, h * 0.63, cx - w * (spread - 0.02) + sway, h * 0.58)
      ..quadraticBezierTo(cx - w * spread, h * 0.38, cx - rx * 0.9, headCy - ry * 0.6)
      ..close();
    canvas.drawPath(
      backPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [hairColor.color, hairDark, hairLight.withValues(alpha: 0.9)],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(Rect.fromLTWH(cx - w * 0.21, headCy - ry, w * 0.42, h * 0.72)),
    );
    final strand = Paint()
      ..color = hairLight.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, w * 0.006)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final side = i == 0 ? 0.0 : (i == 1 ? -1.0 : 1.0);
      final x0 = cx + side * w * 0.07;
      canvas.drawPath(
        Path()
          ..moveTo(x0, headCy - ry * 0.5)
          ..quadraticBezierTo(x0 + side * w * 0.03, h * 0.42, x0 + side * w * 0.015 + sway, h * 0.56),
        strand,
      );
    }
  }

  /// 男版胸前两缕长发（韩立式）：从鬓角垂到胸前，压在道袍外面，
  /// 发尾随呼吸轻摆。
  void _drawMaleFrontLocks(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final rx = _faceRx(w);
    final ry = _faceRy(h);
    final headCy = h * _headCy;
    final sway = math.sin(progress * math.pi * 2 + 0.6) * w * 0.008;
    final hairPaint = Paint()..color = hairColor.color;
    final hairLight = _tint(hairColor.color, 0.35);
    for (final side in [-1.0, 1.0]) {
      final lockPath = Path()
        ..moveTo(cx + side * rx * 0.85, headCy - ry * 0.2)
        ..quadraticBezierTo(cx + side * rx * 1.15, h * 0.36, cx + side * rx * 1.0 + sway, h * 0.55)
        ..quadraticBezierTo(cx + side * rx * 0.92 + sway, h * 0.565, cx + side * rx * 0.80 + sway, h * 0.50)
        ..quadraticBezierTo(cx + side * rx * 0.72, h * 0.36, cx + side * rx * 0.85, headCy - ry * 0.2)
        ..close();
      canvas.drawPath(lockPath, hairPaint);
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * rx * 0.92, headCy + ry * 0.1)
          ..quadraticBezierTo(cx + side * rx * 1.02, h * 0.36, cx + side * rx * 0.95 + sway, h * 0.50),
        Paint()
          ..color = hairLight.withValues(alpha: 0.6)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, w * 0.005)
          ..strokeCap = StrokeCap.round,
      );
    }
  }

  /// 女版身后飘带（紫灵紫金 / 南宫婉青白式）：两条细长的轻纱飘带
  /// 从肩后向两侧飘飞、末端收尖，随呼吸轻摆；画在人物身后、长发之外。
  void _drawFemaleRibbonsBack(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final sway = math.sin(progress * math.pi * 2) * w * 0.02;
    final sway2 = math.sin(progress * math.pi * 2 + 1.2) * w * 0.02;
    // 右飘带扬起、左飘带横飘：细带（上缘 / 下缘两条曲线在尖端汇合）。
    for (final spec in [
      (1.0, sway, -0.07),
      (-1.0, sway2, 0.01),
    ]) {
      final side = spec.$1;
      final s = spec.$2;
      final lift = spec.$3;
      final start = Offset(cx + side * w * 0.09, h * 0.43);
      final mid = Offset(cx + side * w * 0.28, h * (0.40 + lift));
      final tip = Offset(cx + side * w * 0.37 + s, h * (0.50 + lift));
      final ribbon = Path()
        ..moveTo(start.dx, start.dy - h * 0.008)
        ..quadraticBezierTo(mid.dx, mid.dy - h * 0.022, tip.dx, tip.dy)
        ..quadraticBezierTo(
            mid.dx + side * w * 0.02, mid.dy + h * 0.028, start.dx, start.dy + h * 0.010)
        ..close();
      canvas.drawPath(
        ribbon,
        Paint()..color = Colors.white.withValues(alpha: 0.20),
      );
      canvas.drawPath(
        ribbon,
        Paint()
          ..color = costume.trim.withValues(alpha: 0.5)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, w * 0.008),
      );
      // 飘带尖端一颗金珠（系带扣）。
      canvas.drawCircle(tip, w * 0.006,
          Paint()..color = const Color(0xFFD4AF37).withValues(alpha: 0.8));
    }
  }

  /// 男版道袍（站姿施法）：长袍从肩垂到脚面，袍摆微扬、露出鞋尖；
  /// 手臂按职业摆：天道右手仗剑上扬、左手剑指；逍遥双臂张开引飞轮；
  /// 金刚双掌前推撑金罩。
  void _drawMaleRobe(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final robe = costume.robe;
    final robeDark = _shade(robe, 0.30);
    final robeLight = _tint(robe, 0.30);
    final trim = costume.trim;
    final skin = Paint()..color = const Color(0xFFFFE0BF);

    // 袍身：肩 → 腰 → 垂到脚面的长袍，袍摆带波浪（左上亮、右下暗）。
    final robePaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [robeLight, robe, robeDark],
        stops: const [0.0, 0.45, 1.0],
      ).createShader(Rect.fromLTWH(cx - w * 0.24, h * 0.40, w * 0.48, h * 0.40));
    final bodyPath = Path()
      ..moveTo(cx - w * 0.115, h * 0.40)
      ..quadraticBezierTo(cx - w * 0.16, h * 0.48, cx - w * 0.185, h * 0.60)
      ..quadraticBezierTo(cx - w * 0.21, h * 0.70, cx - w * 0.235, h * 0.775)
      ..quadraticBezierTo(cx - w * 0.12, h * 0.795, cx, h * 0.785)
      ..quadraticBezierTo(cx + w * 0.12, h * 0.795, cx + w * 0.235, h * 0.775)
      ..quadraticBezierTo(cx + w * 0.21, h * 0.70, cx + w * 0.185, h * 0.60)
      ..quadraticBezierTo(cx + w * 0.16, h * 0.48, cx + w * 0.115, h * 0.40)
      ..quadraticBezierTo(cx, h * 0.375, cx - w * 0.115, h * 0.40)
      ..close();
    canvas.drawPath(bodyPath, robePaint);

    // 衣褶：左侧浅色高光褶、右侧深色褶线，顺着袍身垂下来。
    final foldLight = Paint()
      ..color = Colors.white.withValues(alpha: 0.28)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.009)
      ..strokeCap = StrokeCap.round;
    final foldDark = Paint()
      ..color = robeDark.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.010)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 2; i++) {
      final x = cx - w * (0.09 + i * 0.05);
      canvas.drawPath(
        Path()
          ..moveTo(x, h * 0.46)
          ..quadraticBezierTo(x - w * 0.012, h * 0.60, x + w * 0.008, h * 0.74),
        foldLight,
      );
    }
    for (var i = 0; i < 2; i++) {
      final x = cx + w * (0.08 + i * 0.05);
      canvas.drawPath(
        Path()
          ..moveTo(x, h * 0.46)
          ..quadraticBezierTo(x + w * 0.012, h * 0.60, x - w * 0.008, h * 0.74),
        foldDark,
      );
    }
    // 袍身中缝。
    canvas.drawLine(
      Offset(cx, h * 0.475),
      Offset(cx, h * 0.565),
      Paint()
        ..color = robeDark.withValues(alpha: 0.5)
        ..strokeWidth = math.max(1, w * 0.008),
    );
    _drawPattern(canvas, w, h, Paint()..color = trim);
    // 韩立式金色云纹刺绣：肩头金云纹护肩 + 里衣蓝波纹。
    _drawGoldCloudOrnaments(canvas, w, h);

    // 领口：外领（镶边色 V）+ 内领（深色小 V）+ 里衣（浅色三角）。
    final innerShirt = Path()
      ..moveTo(cx - w * 0.038, h * 0.405)
      ..lineTo(cx, h * 0.455)
      ..lineTo(cx + w * 0.038, h * 0.405)
      ..lineTo(cx, h * 0.42)
      ..close();
    canvas.drawPath(innerShirt, Paint()..color = _tint(robe, 0.55));
    final collarPath = Path()
      ..moveTo(cx - w * 0.058, h * 0.405)
      ..lineTo(cx, h * 0.475)
      ..lineTo(cx + w * 0.058, h * 0.405)
      ..lineTo(cx + w * 0.038, h * 0.392)
      ..lineTo(cx, h * 0.442)
      ..lineTo(cx - w * 0.038, h * 0.392)
      ..close();
    canvas.drawPath(collarPath, Paint()..color = trim);
    canvas.drawLine(
      Offset(cx - w * 0.045, h * 0.412),
      Offset(cx, h * 0.458),
      Paint()
        ..color = _shade(trim, 0.35).withValues(alpha: 0.8)
        ..strokeWidth = math.max(1, w * 0.007),
    );

    // 腰带：渐变带身 + 金带扣。
    final beltRect = RRect.fromLTRBR(
      cx - w * 0.185, h * 0.575,
      cx + w * 0.185, h * 0.615,
      Radius.circular(h * 0.02),
    );
    canvas.drawRRect(
      beltRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_tint(costume.belt, 0.25), costume.belt, _shade(costume.belt, 0.35)],
        ).createShader(Rect.fromLTRB(beltRect.left, beltRect.top, beltRect.right, beltRect.bottom)),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(cx - w * 0.026, h * 0.578, cx + w * 0.026, h * 0.612,
          Radius.circular(w * 0.008)),
      Paint()..color = const Color(0xFFD4AF37),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(cx - w * 0.014, h * 0.586, cx + w * 0.014, h * 0.604,
          Radius.circular(w * 0.005)),
      Paint()..color = const Color(0xFF8A6508),
    );

    // 鞋尖：袍摆下露出两只深色布鞋。
    for (final side in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          cx + side * w * 0.105 - w * 0.028, h * 0.782,
          cx + side * w * 0.105 + w * 0.028, h * 0.806,
          Radius.circular(w * 0.012),
        ),
        Paint()..color = const Color(0xFF2B2B33),
      );
      canvas.drawLine(
        Offset(cx + side * w * 0.105 - w * 0.024, h * 0.786),
        Offset(cx + side * w * 0.105 + w * 0.024, h * 0.786),
        Paint()
          ..color = const Color(0xFFD4AF37).withValues(alpha: 0.7)
          ..strokeWidth = math.max(0.8, w * 0.005),
      );
    }

    // 手臂（按职业摆）+ 手。
    switch (profession) {
      case '天道':
        // 右手仗剑上扬，左手掌前推施法（韩立青元剑诀式：掌心绿光）。
        _drawArm(canvas, w, h, 1.0, const Offset(0.21, 0.30), robePaint, robeDark, 0.8);
        _drawArm(canvas, w, h, -1.0, const Offset(-0.17, 0.47), robePaint, robeDark);
        canvas.drawCircle(Offset(cx + w * 0.21, h * 0.30), w * 0.028, skin);
        _drawHandSword(canvas, w, h, Offset(cx + w * 0.21, h * 0.30), -0.95);
        // 左手张开前推：掌心 + 四指张开，掌前一团青元绿光。
        final palm = Offset(cx - w * 0.17, h * 0.47);
        canvas.drawOval(
          Rect.fromCenter(center: palm, width: w * 0.045, height: w * 0.055),
          skin,
        );
        for (var i = 0; i < 4; i++) {
          final a = -math.pi * 0.75 + i * math.pi * 0.22;
          canvas.drawLine(
            Offset(palm.dx + math.cos(a) * w * 0.018, palm.dy + math.sin(a) * w * 0.018),
            Offset(palm.dx + math.cos(a) * w * 0.038, palm.dy + math.sin(a) * w * 0.038),
            Paint()
              ..color = const Color(0xFFFFE0BF)
              ..strokeWidth = math.max(1.2, w * 0.008)
              ..strokeCap = StrokeCap.round,
          );
        }
        final palmGlow = Offset(cx - w * 0.215, h * 0.435);
        canvas.drawCircle(
          palmGlow,
          w * 0.045,
          Paint()
            ..shader = RadialGradient(
              colors: [
                const Color(0xFFB6FFD6).withValues(alpha: 0.85),
                const Color(0xFF22C55E).withValues(alpha: 0.35),
                const Color(0xFF22C55E).withValues(alpha: 0),
              ],
            ).createShader(Rect.fromCircle(center: palmGlow, radius: w * 0.045)),
        );
      case '逍遥':
        // 双臂张开引飞轮。
        for (final side in [-1.0, 1.0]) {
          _drawArm(canvas, w, h, side, Offset(side * 0.25, 0.48), robePaint, robeDark);
          canvas.drawCircle(Offset(cx + side * w * 0.25, h * 0.48), w * 0.027, skin);
        }
      default:
        // 金刚：双掌前推撑金罩。
        for (final side in [-1.0, 1.0]) {
          _drawArm(canvas, w, h, side, Offset(side * 0.22, 0.55), robePaint, robeDark);
          canvas.drawOval(
            Rect.fromCenter(
              center: Offset(cx + side * w * 0.22, h * 0.55),
              width: w * 0.045,
              height: w * 0.055,
            ),
            skin,
          );
        }
    }
  }

  /// 韩立式金色云纹刺绣：肩头两朵金云纹护肩（螺旋云纹 + 金点）与
  /// 里衣上的蓝波纹（蓝金袍式内衬）。
  void _drawGoldCloudOrnaments(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final gold = Paint()
      ..color = const Color(0xFFD4AF37)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * 0.009)
      ..strokeCap = StrokeCap.round;
    final goldFill = Paint()..color = const Color(0xFFD4AF37);
    for (final side in [-1.0, 1.0]) {
      final c = Offset(cx + side * w * 0.115, h * 0.425);
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: w * 0.030),
        math.pi * 0.15, math.pi * 1.25, false, gold,
      );
      canvas.drawArc(
        Rect.fromCircle(center: c, radius: w * 0.016),
        math.pi * 0.9, math.pi * 1.1, false, gold,
      );
      canvas.drawCircle(c, w * 0.006, goldFill);
    }
    // 里衣蓝波纹：领口三角里两道蓝波浪线。
    final wavePaint = Paint()
      ..color = const Color(0xFF7FB3D5).withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, w * 0.006)
      ..strokeCap = StrokeCap.round;
    for (var row = 0; row < 2; row++) {
      final y = h * (0.42 + row * 0.012);
      final wavePath = Path()..moveTo(cx - w * 0.028, y);
      for (var i = 1; i <= 4; i++) {
        wavePath.quadraticBezierTo(
          cx - w * 0.028 + w * 0.014 * i,
          y + (i.isOdd ? -w * 0.006 : w * 0.006),
          cx - w * 0.028 + w * 0.014 * (i + 0.5),
          y,
        );
      }
      canvas.drawPath(wavePath, wavePaint);
    }
  }

  /// 宽袖手臂：肩到手腕的粗线袖（深色描边 + 袍色主线 + 袖口镶边）。
  /// [hand] 是手相对画面中心的位置（x 用 w 计、y 用 h 计）。
  void _drawArm(
    Canvas canvas,
    double w,
    double h,
    double side,
    Offset hand,
    Paint sleevePaint,
    Color sleeveDark, [
    double widthScale = 1.0,
  ]) {
    final cx = w / 2;
    final from = Offset(cx + side * w * 0.10, h * 0.42);
    final to = Offset(cx + hand.dx * w, hand.dy * h);
    // 深色描边（袖的厚度）。
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = sleeveDark
        ..strokeWidth = w * 0.085 * widthScale
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      from,
      to,
      sleevePaint
        ..strokeWidth = w * 0.062 * widthScale
        ..strokeCap = StrokeCap.round,
    );
    // 袖口镶边。
    canvas.drawCircle(
      to,
      w * 0.034,
      Paint()
        ..color = costume.trim
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.010),
    );
  }

  /// 天道持剑：手握剑柄、剑身斜指右上，青竹蜂云剑式绿刃（青元剑诀
  /// 的绿剑）+ 金剑格 + 缠柄。
  void _drawHandSword(Canvas canvas, double w, double h, Offset grip, double angle) {
    canvas.save();
    canvas.translate(grip.dx, grip.dy);
    canvas.rotate(angle);
    // 剑光微晕（绿）。
    canvas.drawLine(
      Offset(0, 0),
      Offset(w * 0.30, 0),
      Paint()
        ..color = const Color(0xFF7CFFB2).withValues(alpha: 0.35)
        ..strokeWidth = w * 0.03
        ..strokeCap = StrokeCap.round,
    );
    // 剑身：从剑格向右渐细的翠绿刃。
    final blade = Path()
      ..moveTo(w * 0.02, -w * 0.011)
      ..lineTo(w * 0.27, -w * 0.004)
      ..lineTo(w * 0.30, 0)
      ..lineTo(w * 0.27, w * 0.004)
      ..lineTo(w * 0.02, w * 0.011)
      ..close();
    canvas.drawPath(
      blade,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: const [Color(0xFFD8FFE8), Color(0xFF4ADE80), Color(0xFF16A34A), Color(0xFF7CFFB2)],
          stops: const [0.0, 0.35, 0.8, 1.0],
        ).createShader(Rect.fromLTWH(w * 0.02, -w * 0.011, w * 0.28, w * 0.022)),
    );
    canvas.drawLine(
      Offset(w * 0.025, 0),
      Offset(w * 0.27, 0),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.75)
        ..strokeWidth = math.max(0.8, w * 0.005),
    );
    // 金剑格 + 缠柄。
    canvas.drawRRect(
      RRect.fromLTRBR(w * 0.004, -w * 0.022, w * 0.022, w * 0.022, Radius.circular(w * 0.006)),
      Paint()..color = const Color(0xFFD4AF37),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(-w * 0.075, -w * 0.009, w * 0.004, w * 0.009, Radius.circular(w * 0.005)),
      Paint()..color = const Color(0xFF4A3226),
    );
    for (var i = 0; i < 3; i++) {
      final x = -w * (0.06 - i * 0.022);
      canvas.drawLine(
        Offset(x, -w * 0.009),
        Offset(x, w * 0.009),
        Paint()
          ..color = const Color(0xFFD4AF37).withValues(alpha: 0.8)
          ..strokeWidth = math.max(0.8, w * 0.005),
      );
    }
    canvas.restore();
  }

  /// 女版长裙（紫灵 / 南宫婉式，站姿施法）：金饰抹胸 + 收腰 +
  /// 长裙摆垂到脚面 + 轻纱飘袖 + 金项链 + 腰间金花扣；裙色按所选
  /// 服饰走——紫色锦袍即紫灵紫裙，青色道袍 / 月白儒衫即南宫婉
  /// 青白裙。手臂：右手优雅上扬施法（天道则仗剑）、左手轻舒。
  void _drawFemaleDress(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final trim = costume.trim;
    // 裙色跟服饰走（紫灵紫 / 南宫婉青白），金饰固定走金色。
    final dressTop = _tint(costume.robe, 0.45);
    final dressMid = costume.robe;
    final dressDark = _shade(costume.robe, 0.35);
    final skin = Paint()..color = const Color(0xFFFFE0BF);

    // 露肩：肩头与锁骨是肤色，抹胸从胸口起。
    final skinPaint = Paint()
      ..shader = RadialGradient(
        center: const Alignment(-0.3, -0.5),
        colors: [const Color(0xFFFFEAD6), const Color(0xFFFFDDBB), const Color(0xFFF2BE96)],
      ).createShader(Rect.fromLTWH(cx - w * 0.15, h * 0.38, w * 0.30, h * 0.10));
    final shoulderPath = Path()
      ..moveTo(cx - w * 0.135, h * 0.415)
      ..quadraticBezierTo(cx - w * 0.10, h * 0.385, cx - w * 0.055, h * 0.395)
      ..lineTo(cx + w * 0.055, h * 0.395)
      ..quadraticBezierTo(cx + w * 0.10, h * 0.385, cx + w * 0.135, h * 0.415)
      ..quadraticBezierTo(cx + w * 0.10, h * 0.45, cx, h * 0.455)
      ..quadraticBezierTo(cx - w * 0.10, h * 0.45, cx - w * 0.135, h * 0.415)
      ..close();
    canvas.drawPath(shoulderPath, skinPaint);

    // 金色抹胸：心形上缘 + 金线镶边。
    final bodicePath = Path()
      ..moveTo(cx - w * 0.135, h * 0.435)
      ..quadraticBezierTo(cx - w * 0.07, h * 0.465, cx, h * 0.445)
      ..quadraticBezierTo(cx + w * 0.07, h * 0.465, cx + w * 0.135, h * 0.435)
      ..quadraticBezierTo(cx + w * 0.155, h * 0.51, cx + w * 0.125, h * 0.575)
      ..quadraticBezierTo(cx, h * 0.60, cx - w * 0.125, h * 0.575)
      ..quadraticBezierTo(cx - w * 0.155, h * 0.51, cx - w * 0.135, h * 0.435)
      ..close();
    canvas.drawPath(
      bodicePath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [dressTop, dressMid, dressDark],
          stops: const [0.0, 0.5, 1.0],
        ).createShader(Rect.fromLTWH(cx - w * 0.16, h * 0.43, w * 0.32, h * 0.18)),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - w * 0.135, h * 0.435)
        ..quadraticBezierTo(cx - w * 0.07, h * 0.465, cx, h * 0.445)
        ..quadraticBezierTo(cx + w * 0.07, h * 0.465, cx + w * 0.135, h * 0.435),
      Paint()
        ..color = const Color(0xFFFFF3B0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, w * 0.010)
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawCircle(Offset(cx, h * 0.50), w * 0.010,
        Paint()..color = const Color(0xFFFFF3B0));
    // 金项链：细链 + 吊坠。
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, h * 0.405), radius: w * 0.045),
      math.pi * 0.25, math.pi * 0.5, false,
      Paint()
        ..color = const Color(0xFFD4AF37)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.008),
    );
    canvas.drawCircle(Offset(cx, h * 0.448), w * 0.009,
        Paint()..color = const Color(0xFFFFD54F));

    // 收腰金腰封（带扣），腰封底色按所选服饰腰带色走。
    final waistRect = RRect.fromLTRBR(
      cx - w * 0.135, h * 0.575, cx + w * 0.135, h * 0.615,
      Radius.circular(h * 0.018),
    );
    canvas.drawRRect(
      waistRect,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [_tint(costume.belt, 0.25), costume.belt, _shade(costume.belt, 0.3)],
        ).createShader(Rect.fromLTRB(waistRect.left, waistRect.top, waistRect.right, waistRect.bottom)),
    );
    // 腰间金花扣（紫灵式金花 + 绿宝石）：五片金花瓣 + 金蕊 + 两颗绿宝。
    final waistFlower = Offset(cx, h * 0.595);
    for (var i = 0; i < 5; i++) {
      final angle = i * math.pi * 2 / 5 - math.pi / 2;
      final px = waistFlower.dx + math.cos(angle) * w * 0.016;
      final py = waistFlower.dy + math.sin(angle) * w * 0.016;
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(angle + math.pi / 2);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: w * 0.016, height: w * 0.024),
        Paint()..color = const Color(0xFFFFD54F),
      );
      canvas.restore();
    }
    canvas.drawCircle(waistFlower, w * 0.009,
        Paint()..color = const Color(0xFFD4AF37));
    for (final side in [-1.0, 1.0]) {
      canvas.drawCircle(
        Offset(waistFlower.dx + side * w * 0.030, waistFlower.dy + h * 0.006),
        w * 0.006,
        Paint()..color = const Color(0xFF2ECC71),
      );
    }

    // 金裙摆：从腰封垂到脚面，裙面金渐变 + 褶线 + 高光 + 波浪裙摆。
    final skirtPath = Path()
      ..moveTo(cx - w * 0.125, h * 0.61)
      ..quadraticBezierTo(cx - w * 0.19, h * 0.68, cx - w * 0.225, h * 0.775)
      ..quadraticBezierTo(cx - w * 0.12, h * 0.795, cx, h * 0.785)
      ..quadraticBezierTo(cx + w * 0.12, h * 0.795, cx + w * 0.225, h * 0.775)
      ..quadraticBezierTo(cx + w * 0.19, h * 0.68, cx + w * 0.125, h * 0.61)
      ..quadraticBezierTo(cx, h * 0.59, cx - w * 0.125, h * 0.61)
      ..close();
    canvas.drawPath(
      skirtPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [dressTop, dressMid, dressDark],
        ).createShader(Rect.fromLTWH(cx - w * 0.23, h * 0.59, w * 0.46, h * 0.21)),
    );
    final skirtFoldDark = Paint()
      ..color = dressDark.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.009)
      ..strokeCap = StrokeCap.round;
    final skirtFoldLight = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.008)
      ..strokeCap = StrokeCap.round;
    for (final side in [-1.0, 1.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * w * 0.06, h * 0.63)
          ..quadraticBezierTo(cx + side * w * 0.075, h * 0.70, cx + side * w * 0.06, h * 0.765),
        skirtFoldDark,
      );
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * w * 0.11, h * 0.635)
          ..quadraticBezierTo(cx + side * w * 0.125, h * 0.70, cx + side * w * 0.11, h * 0.76),
        skirtFoldLight,
      );
    }
    // 轻纱罩裙：服饰袍色半透明罩在金裙外，仙气飘飘。
    final veilPath = Path()
      ..moveTo(cx - w * 0.10, h * 0.62)
      ..quadraticBezierTo(cx - w * 0.22, h * 0.70, cx - w * 0.24, h * 0.79)
      ..quadraticBezierTo(cx, h * 0.815, cx + w * 0.24, h * 0.79)
      ..quadraticBezierTo(cx + w * 0.22, h * 0.70, cx + w * 0.10, h * 0.62)
      ..close();
    canvas.drawPath(
      veilPath,
      Paint()..color = costume.robe.withValues(alpha: 0.28),
    );

    // 金色绣鞋尖：裙摆下露出两只小金鞋。
    for (final side in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          cx + side * w * 0.08 - w * 0.022, h * 0.788,
          cx + side * w * 0.08 + w * 0.022, h * 0.808,
          Radius.circular(w * 0.010),
        ),
        Paint()..color = const Color(0xFFD4AF37),
      );
    }

    // 轻纱飘袖 + 手臂：右手优雅上扬（天道仗剑），左手轻舒下垂。
    if (profession == '天道') {
      _drawSheerArm(canvas, w, h, 1.0, const Offset(0.20, 0.30));
      _drawSheerArm(canvas, w, h, -1.0, const Offset(-0.24, 0.50));
      canvas.drawCircle(Offset(cx + w * 0.20, h * 0.30), w * 0.024, skin);
      _drawHandSword(canvas, w, h, Offset(cx + w * 0.20, h * 0.30), -0.95);
      canvas.drawCircle(Offset(cx - w * 0.24, h * 0.50), w * 0.024, skin);
      // 左手金臂环。
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx - w * 0.225, h * 0.47), radius: w * 0.020),
        -math.pi * 0.2, math.pi * 0.9, false,
        Paint()
          ..color = const Color(0xFFD4AF37)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, w * 0.010),
      );
      // 左手掌前一团青元绿光（与男版韩立同式）。
      final femalePalmGlow = Offset(cx - w * 0.27, h * 0.47);
      canvas.drawCircle(
        femalePalmGlow,
        w * 0.038,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFB6FFD6).withValues(alpha: 0.85),
              const Color(0xFF22C55E).withValues(alpha: 0.35),
              const Color(0xFF22C55E).withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: femalePalmGlow, radius: w * 0.038)),
      );
    } else if (profession == '逍遥') {
      // 双臂张开引飞轮，轻纱袖随风扬起。
      for (final side in [-1.0, 1.0]) {
        _drawSheerArm(canvas, w, h, side, Offset(side * 0.25, 0.47));
        canvas.drawCircle(Offset(cx + side * w * 0.25, h * 0.47), w * 0.024, skin);
      }
    } else {
      // 金刚：双掌前推撑金罩。
      for (final side in [-1.0, 1.0]) {
        _drawSheerArm(canvas, w, h, side, Offset(side * 0.21, 0.55));
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(cx + side * w * 0.21, h * 0.55),
            width: w * 0.040,
            height: w * 0.050,
          ),
          skin,
        );
      }
    }
    // 天道以外：右手掌心一团小金光（施法光晕）。
    if (profession != '天道') {
      final hand = profession == '逍遥'
          ? Offset(cx + w * 0.25, h * 0.47)
          : Offset(cx + w * 0.21, h * 0.55);
      canvas.drawCircle(
        hand,
        w * 0.035,
        Paint()
          ..shader = RadialGradient(
            colors: [
              const Color(0xFFFFE9A8).withValues(alpha: 0.8),
              const Color(0xFFD4AF37).withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: hand, radius: w * 0.035)),
      );
    }
    // 袍面纹样（胸前小标记，按服饰纹样）。
    _drawPattern(canvas, w, h, Paint()..color = trim);
  }

  /// 轻纱飘袖：半透明纱袖（白纱 + 服饰镶边色），袖口飘出肩外带金线边。
  void _drawSheerArm(
    Canvas canvas,
    double w,
    double h,
    double side,
    Offset hand,
  ) {
    final cx = w / 2;
    final from = Offset(cx + side * w * 0.11, h * 0.42);
    final to = Offset(cx + hand.dx * w, hand.dy * h);
    // 纱袖：暖金纱粗线 + 镶边色薄线叠出轻透感（细一点，不发灰）。
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = const Color(0xFFFFF3B0).withValues(alpha: 0.34)
        ..strokeWidth = w * 0.060
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawLine(
      from,
      to,
      Paint()
        ..color = costume.trim.withValues(alpha: 0.22)
        ..strokeWidth = w * 0.044
        ..strokeCap = StrokeCap.round,
    );
    // 袖口飘边：手腕处一小片飘起的纱。
    canvas.drawPath(
      Path()
        ..moveTo(to.dx, to.dy)
        ..quadraticBezierTo(to.dx + side * w * 0.05, to.dy - h * 0.02, to.dx + side * w * 0.07, to.dy + h * 0.02)
        ..quadraticBezierTo(to.dx + side * w * 0.03, to.dy + h * 0.035, to.dx, to.dy + h * 0.01)
        ..close(),
      Paint()..color = Colors.white.withValues(alpha: 0.30),
    );
  }

  /// 天道平时：三把小青竹蜂云剑（绿剑）慢速绕身（放技能时才变七剑齐出）。
  void _drawOrbitSwordsIdle(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY * 0.5;
    for (var i = 0; i < 3; i++) {
      final angle = (i / 3) * math.pi * 2 + progress * math.pi * 2;
      final pos = Offset(
        cx + math.cos(angle) * w * 0.30,
        cy + math.sin(angle) * w * 0.24,
      );
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(angle + math.pi / 2);
      _drawGreenBlade(canvas, w, 0.55);
      canvas.restore();
    }
  }

  /// 脖子（肤色 + 下颌阴影）与耳朵。
  void _drawNeckAndEars(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final rx = _faceRx(w);
    final ry = _faceRy(h);
    final headCy = h * _headCy;
    // 脖子。
    canvas.drawRRect(
      RRect.fromLTRBR(cx - w * 0.032, headCy + ry * 0.55, cx + w * 0.032, h * 0.405,
          Radius.circular(w * 0.02)),
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: const [Color(0xFFF2BE96), Color(0xFFFFE0BF)],
        ).createShader(Rect.fromLTWH(cx - w * 0.032, headCy + ry * 0.5, w * 0.064, h * 0.06)),
    );
    // 耳朵：左右各一，带耳廓线；女版加金耳坠。
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + side * rx * 0.98, headCy + h * 0.01),
          width: w * 0.020,
          height: h * 0.032,
        ),
        Paint()..color = const Color(0xFFFFDDBB),
      );
      canvas.drawArc(
        Rect.fromCenter(
          center: Offset(cx + side * rx * 0.98, headCy + h * 0.01),
          width: w * 0.012,
          height: h * 0.020,
        ),
        -math.pi * 0.5, math.pi * 1.1, false,
        Paint()
          ..color = const Color(0xFFD89B6A).withValues(alpha: 0.8)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, w * 0.006)
          ..strokeCap = StrokeCap.round,
      );
      if (isFemale) {
        canvas.drawCircle(
          Offset(cx + side * rx * 0.98, headCy + h * 0.035),
          w * 0.006,
          Paint()..color = const Color(0xFFD4AF37),
        );
      }
    }
  }

  // ------------------------------------------------------------------
  // 脸：脸型轮廓 + 肤色渐变 + 面部阴影 + 眉眼鼻嘴 + 腮红。
  // 眼睛是眼白 + 虹膜 + 瞳孔 + 高光的完整动漫眼，不是两个点。
  // ------------------------------------------------------------------
  void _drawHead(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final rx = _faceRx(w);
    final ry = _faceRy(h);
    final headCy = h * _headCy;
    final headCenter = Offset(cx, headCy);

    // 脸型轮廓：瓜子脸下巴收尖、方脸下颌方、圆脸偏圆。
    final chinW = switch (face) {
      '方脸' => 0.62,
      '圆脸' => 0.45,
      _ => 0.30,
    };
    final chinY = headCy + ry * (face == '瓜子脸' ? 1.16 : 1.0);
    final facePath = Path()
      ..moveTo(cx - rx * 0.92, headCy - ry * 0.35)
      ..quadraticBezierTo(cx - rx * 1.04, headCy + ry * 0.45,
          cx - rx * chinW, chinY - ry * 0.12)
      ..quadraticBezierTo(cx, chinY + ry * 0.14,
          cx + rx * chinW, chinY - ry * 0.12)
      ..quadraticBezierTo(cx + rx * 1.04, headCy + ry * 0.45,
          cx + rx * 0.92, headCy - ry * 0.35)
      ..quadraticBezierTo(cx + rx * 0.7, headCy - ry * 1.06,
          cx, headCy - ry * 1.08)
      ..quadraticBezierTo(cx - rx * 0.7, headCy - ry * 1.06,
          cx - rx * 0.92, headCy - ry * 0.35)
      ..close();
    // 肤色：左上亮、右下暗的径向渐变（2.5D 体积感）。
    canvas.drawPath(
      facePath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.35, -0.45),
          radius: 1.1,
          colors: const [
            Color(0xFFFFEAD6),
            Color(0xFFFFDDBB),
            Color(0xFFF0B98C),
          ],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(
          Rect.fromCenter(center: headCenter, width: rx * 2.2, height: ry * 2.2),
        ),
    );
    // 面部阴影：右侧颧骨淡淡的暖影 + 下颌底影 + 额头高光。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + rx * 0.55, headCy + ry * 0.30),
        width: rx * 0.7,
        height: ry * 0.55,
      ),
      Paint()..color = const Color(0xFFE8A06A).withValues(alpha: 0.20),
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, chinY - ry * 0.05), radius: rx * 0.5),
      math.pi * 0.25,
      math.pi * 0.5,
      false,
      Paint()
        ..color = const Color(0xFFD89B6A).withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.010)
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - rx * 0.3, headCy - ry * 0.62),
        width: rx * 0.9,
        height: ry * 0.45,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.20),
    );

    // 腮红。
    for (final side in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + side * rx * 0.78, headCy + ry * 0.38),
          width: w * 0.028,
          height: h * 0.016,
        ),
        Paint()
          ..color = const Color(0xFFF6B8C8)
              .withValues(alpha: isFemale ? 0.55 : 0.38),
      );
    }

    final eyeY = headCy + ry * 0.08;
    final eyeDx = w * 0.042;
    final eyeR = w * 0.020;

    // 眉毛：男剑眉（粗、内低外扬）、女弯眉（细、高挑弯弧）。
    for (final side in [-1.0, 1.0]) {
      if (isFemale) {
        canvas.drawArc(
          Rect.fromCircle(
            center: Offset(cx + side * eyeDx, eyeY - h * 0.028),
            radius: w * 0.026,
          ),
          math.pi * 1.15,
          math.pi * 0.7,
          false,
          Paint()
            ..color = _shade(hairColor.color, 0.1)
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1, w * 0.007)
            ..strokeCap = StrokeCap.round,
        );
      } else {
        // 男版韩立式剑眉：细而直、微扬，不粗不凶（冷峻，不是怒容）。
        final brow = Path()
          ..moveTo(cx + side * (eyeDx - w * 0.022), eyeY - h * 0.021)
          ..lineTo(cx + side * (eyeDx + w * 0.024), eyeY - h * 0.026)
          ..lineTo(cx + side * (eyeDx + w * 0.024), eyeY - h * 0.020)
          ..lineTo(cx + side * (eyeDx - w * 0.022), eyeY - h * 0.015)
          ..close();
        canvas.drawPath(brow, Paint()..color = _shade(hairColor.color, 0.1));
      }
    }

    // 眼睛：杏仁眼白 + 虹膜渐变 + 瞳孔 + 两点高光 + 上眼线；
    // 女版虹膜更大、睫毛更长（外眼角三根翘睫）。
    for (final side in [-1.0, 1.0]) {
      final ex = cx + side * eyeDx;
      final irisR = isFemale ? eyeR * 0.78 : eyeR * 0.68;
      // 男版韩立式冷峻细长眼（眼裂更窄、眼尾微扬）；女版杏仁眼更圆。
      final upperLift = isFemale ? 0.95 : 0.68;
      final lowerDrop = isFemale ? 0.75 : 0.52;
      final eyePath = Path()
        ..moveTo(ex - eyeR, eyeY)
        ..quadraticBezierTo(ex, eyeY - eyeR * upperLift, ex + eyeR, eyeY)
        ..quadraticBezierTo(ex, eyeY + eyeR * lowerDrop, ex - eyeR, eyeY)
        ..close();
      canvas.drawPath(eyePath, Paint()..color = Colors.white);
      // 虹膜：棕色渐变 + 深色 rim。
      canvas.drawCircle(
        Offset(ex, eyeY + h * 0.001),
        irisR,
        Paint()
          ..shader = RadialGradient(
            colors: const [Color(0xFF8A5A2A), Color(0xFF4A2C14), Color(0xFF2A1A0C)],
            stops: const [0.0, 0.7, 1.0],
          ).createShader(Rect.fromCircle(center: Offset(ex, eyeY), radius: irisR)),
      );
      canvas.drawCircle(
        Offset(ex, eyeY + h * 0.001),
        irisR * 0.55,
        Paint()..color = const Color(0xFF6B4226),
      );
      // 瞳孔 + 高光。
      canvas.drawCircle(Offset(ex, eyeY + h * 0.001), irisR * 0.42,
          Paint()..color = const Color(0xFF140B06));
      canvas.drawCircle(Offset(ex - irisR * 0.35, eyeY - irisR * 0.35),
          irisR * 0.22, Paint()..color = Colors.white);
      canvas.drawCircle(Offset(ex + irisR * 0.35, eyeY + irisR * 0.4),
          irisR * 0.10, Paint()..color = Colors.white.withValues(alpha: 0.7));
      // 上眼线（眼尾微微上扬；男版细一点，不显凶）。
      canvas.drawPath(
        Path()
          ..moveTo(ex - eyeR * 0.95, eyeY - h * 0.002)
          ..quadraticBezierTo(ex, eyeY - eyeR * 1.05, ex + eyeR * 1.08, eyeY - h * 0.006),
        Paint()
          ..color = const Color(0xFF1A1A1A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, w * (isFemale ? 0.010 : 0.008))
          ..strokeCap = StrokeCap.round,
      );
      // 下眼线淡淡一道。
      canvas.drawPath(
        Path()
          ..moveTo(ex - eyeR * 0.7, eyeY + eyeR * 0.55)
          ..quadraticBezierTo(ex, eyeY + eyeR * 0.8, ex + eyeR * 0.7, eyeY + eyeR * 0.55),
        Paint()
          ..color = const Color(0xFF8A6A5A).withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(0.8, w * 0.006)
          ..strokeCap = StrokeCap.round,
      );
      if (isFemale) {
        // 外眼角三根翘睫。
        for (var i = 0; i < 3; i++) {
          final t = i / 2;
          final sx = ex + side * eyeR * (0.85 + t * 0.15);
          final sy = eyeY - eyeR * (0.55 + t * 0.25);
          canvas.drawLine(
            Offset(sx, sy),
            Offset(sx + side * w * 0.012, sy - h * 0.012 - t * h * 0.004),
            Paint()
              ..color = const Color(0xFF1A1A1A)
              ..strokeWidth = math.max(0.8, w * 0.006)
              ..strokeCap = StrokeCap.round,
          );
        }
      }
    }

    // 鼻子：鼻梁阴影 + 鼻尖小弧。
    canvas.drawLine(
      Offset(cx - w * 0.005, eyeY + h * 0.012),
      Offset(cx - w * 0.003, headCy + ry * 0.55),
      Paint()
        ..color = const Color(0xFFD89B6A).withValues(alpha: 0.55)
        ..strokeWidth = math.max(0.8, w * 0.006)
        ..strokeCap = StrokeCap.round,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, headCy + ry * 0.58), radius: w * 0.011),
      math.pi * 0.15,
      math.pi * 0.7,
      false,
      Paint()
        ..color = const Color(0xFFC98A5A).withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, w * 0.006)
        ..strokeCap = StrokeCap.round,
    );

    // 嘴：男浅笑细线 + 下唇淡影；女粉唇（上唇 M 形、下唇丰满 + 光点）。
    final mouthY = headCy + ry * 0.72;
    if (isFemale) {
      final lipPath = Path()
        ..moveTo(cx - w * 0.020, mouthY)
        ..quadraticBezierTo(cx - w * 0.010, mouthY - h * 0.007, cx, mouthY - h * 0.003)
        ..quadraticBezierTo(cx + w * 0.010, mouthY - h * 0.007, cx + w * 0.020, mouthY)
        ..quadraticBezierTo(cx + w * 0.012, mouthY + h * 0.009, cx, mouthY + h * 0.010)
        ..quadraticBezierTo(cx - w * 0.012, mouthY + h * 0.009, cx - w * 0.020, mouthY)
        ..close();
      canvas.drawPath(lipPath, Paint()..color = const Color(0xFFE87A8A));
      canvas.drawPath(
        Path()
          ..moveTo(cx - w * 0.014, mouthY + h * 0.003)
          ..quadraticBezierTo(cx, mouthY + h * 0.008, cx + w * 0.014, mouthY + h * 0.003),
        Paint()
          ..color = const Color(0xFFF095A0)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, w * 0.007)
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawCircle(Offset(cx - w * 0.005, mouthY + h * 0.005), w * 0.003,
          Paint()..color = Colors.white.withValues(alpha: 0.8));
    } else {
      // 男版韩立式薄唇：冷峻的直线薄唇，不笑；下唇一道淡影。
      canvas.drawLine(
        Offset(cx - w * 0.018, mouthY),
        Offset(cx + w * 0.018, mouthY),
        Paint()
          ..color = const Color(0xFF9A5A40)
          ..strokeWidth = math.max(1, w * 0.008)
          ..strokeCap = StrokeCap.round,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx, mouthY + h * 0.010),
          width: w * 0.020,
          height: h * 0.005,
        ),
        Paint()..color = const Color(0xFFE8A080).withValues(alpha: 0.45),
      );
    }

    // 女版紫灵式面纱：半透明轻纱遮住口鼻下半脸（嘴唇隐约可见）。
    if (isFemale) _drawFaceVeil(canvas, w, h, rx, ry);

    _drawHair(canvas, w, h, rx, ry);
    if (isFemale) {
      _drawFrontLocks(canvas, w, h, rx, ry);
      // 女版紫灵式金冠：额前金色冠饰。
      _drawGoldCrown(canvas, w, h, rx, ry);
    }
  }

  /// 女版身后长发：从头顶垂到腰际的发瀑，两侧飘逸、发尾微卷，
  /// 带光泽发丝线（画在人物身后，_drawFigure 开头调用）。
  void _drawLongHairBack(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final rx = _faceRx(w);
    final ry = _faceRy(h);
    final headCy = h * _headCy;
    // 发尾随呼吸飘动。
    final sway = math.sin(progress * math.pi * 2 + 0.8) * w * 0.015;
    final hairDark = _shade(hairColor.color, 0.25);
    final hairLight = _tint(hairColor.color, 0.30);
    final backPath = Path()
      ..moveTo(cx - rx * 0.9, headCy - ry * 0.6)
      ..quadraticBezierTo(cx - w * 0.16, headCy - ry * 1.1, cx, headCy - ry * 1.15)
      ..quadraticBezierTo(cx + w * 0.16, headCy - ry * 1.1, cx + rx * 0.9, headCy - ry * 0.6)
      ..quadraticBezierTo(cx + w * 0.21, h * 0.38, cx + w * 0.185 + sway, h * 0.55)
      ..quadraticBezierTo(cx + w * 0.20 + sway, h * 0.62, cx + w * 0.15 + sway, h * 0.60)
      ..quadraticBezierTo(cx + w * 0.13, h * 0.45, cx + rx * 0.8, h * 0.34)
      ..quadraticBezierTo(cx, h * 0.30, cx - rx * 0.8, h * 0.34)
      ..quadraticBezierTo(cx - w * 0.13, h * 0.45, cx - w * 0.15 + sway, h * 0.60)
      ..quadraticBezierTo(cx - w * 0.20 + sway, h * 0.62, cx - w * 0.185 + sway, h * 0.55)
      ..quadraticBezierTo(cx - w * 0.21, h * 0.38, cx - rx * 0.9, headCy - ry * 0.6)
      ..close();
    canvas.drawPath(
      backPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [hairColor.color, hairDark, hairLight.withValues(alpha: 0.9)],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(Rect.fromLTWH(cx - w * 0.21, headCy - ry, w * 0.42, h * 0.72)),
    );
    // 光泽发丝线：几道顺着发瀑的亮线。
    final strand = Paint()
      ..color = hairLight.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(0.8, w * 0.006)
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i < 3; i++) {
      final side = i == 0 ? 0.0 : (i == 1 ? -1.0 : 1.0);
      final x0 = cx + side * w * 0.07;
      canvas.drawPath(
        Path()
          ..moveTo(x0, headCy - ry * 0.5)
          ..quadraticBezierTo(x0 + side * w * 0.03, h * 0.42, x0 + side * w * 0.015, h * 0.56),
        strand,
      );
    }
  }

  /// 女版胸前两缕碎发：从鬓角垂到胸口，压在金裙外面。
  void _drawFrontLocks(Canvas canvas, double w, double h, double rx, double ry) {
    final cx = w / 2;
    final headCy = h * _headCy;
    final hairPaint = Paint()..color = hairColor.color;
    for (final side in [-1.0, 1.0]) {
      final lockPath = Path()
        ..moveTo(cx + side * rx * 0.85, headCy - ry * 0.2)
        ..quadraticBezierTo(cx + side * rx * 1.15, h * 0.36, cx + side * rx * 1.0, h * 0.50)
        ..quadraticBezierTo(cx + side * rx * 0.9, h * 0.51, cx + side * rx * 0.82, h * 0.44)
        ..quadraticBezierTo(cx + side * rx * 0.75, h * 0.34, cx + side * rx * 0.85, headCy - ry * 0.2)
        ..close();
      canvas.drawPath(lockPath, hairPaint);
    }
  }

  /// 发型：道髻 / 披发 / 高马尾，发色按所选发色；女版三种发型
  /// 都是长发垂下（盘发 / 披散 / 马尾扎法不同），发间都有一朵白花。
  void _drawHair(Canvas canvas, double w, double h, double rx, double ry) {
    final cx = w / 2;
    final headCy = h * _headCy;
    final headTop = headCy - ry;
    final hairPaint = Paint()..color = hairColor.color;
    final hairLight = _tint(hairColor.color, 0.35);
    // 发盖：盖住头顶，额前发际线带一点波浪。
    final hairPath = Path()
      ..moveTo(cx - rx * 0.98, headCy - ry * 0.1)
      ..quadraticBezierTo(cx - rx * 0.95, headTop - h * 0.025, cx, headTop - h * 0.03)
      ..quadraticBezierTo(cx + rx * 0.95, headTop - h * 0.025, cx + rx * 0.98, headCy - ry * 0.1)
      ..quadraticBezierTo(cx + rx * 0.72, headCy - ry * 0.52, cx + rx * 0.28, headCy - ry * 0.48)
      ..quadraticBezierTo(cx, headCy - ry * 0.58, cx - rx * 0.28, headCy - ry * 0.48)
      ..quadraticBezierTo(cx - rx * 0.72, headCy - ry * 0.52, cx - rx * 0.98, headCy - ry * 0.1)
      ..close();
    canvas.drawPath(hairPath, hairPaint);
    // 发盖光泽：头顶左上一小块高光（收在发盖里面，不露到外面）。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - w * 0.028, headTop + h * 0.012),
        width: w * 0.055,
        height: h * 0.014,
      ),
      Paint()..color = hairLight.withValues(alpha: 0.45),
    );

    final tie = Paint()..color = costume.trim;
    switch (hairstyle) {
      case '披发':
        // 两侧垂发：男垂到肩，女已由身后长发承担，这里只补鬓边碎发。
        for (final side in [-1.0, 1.0]) {
          final fallPath = Path()
            ..moveTo(cx + side * rx * 0.85, headCy - ry * 0.3)
            ..quadraticBezierTo(cx + side * rx * 1.25, h * 0.33,
                cx + side * rx * 1.05, isFemale ? h * 0.46 : h * 0.44)
            ..quadraticBezierTo(cx + side * rx * 0.9, h * 0.38,
                cx + side * rx * 0.72, headCy - ry * 0.1)
            ..close();
          canvas.drawPath(fallPath, hairPaint);
        }
      case '高马尾':
        // 顶髻 + 向右侧甩的马尾（女版马尾更长更飘）。
        canvas.drawCircle(Offset(cx, headTop - h * 0.015), w * 0.030, hairPaint);
        final tailEnd = isFemale ? h * 0.52 : h * 0.30;
        final tailPath = Path()
          ..moveTo(cx + w * 0.02, headTop - h * 0.01)
          ..quadraticBezierTo(cx + w * 0.16, h * 0.14, cx + w * 0.19, tailEnd)
          ..quadraticBezierTo(cx + w * 0.15, tailEnd + h * 0.01, cx + w * 0.12, h * 0.20)
          ..quadraticBezierTo(cx + w * 0.06, h * 0.10, cx + w * 0.02, headTop - h * 0.01)
          ..close();
        canvas.drawPath(tailPath, hairPaint);
        canvas.drawPath(
          Path()
            ..moveTo(cx + w * 0.10, h * 0.12)
            ..quadraticBezierTo(cx + w * 0.15, h * 0.20, cx + w * 0.155, tailEnd - h * 0.03),
          Paint()
            ..color = hairLight.withValues(alpha: 0.6)
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(0.8, w * 0.006),
        );
        canvas.drawRRect(
          RRect.fromLTRBR(cx - w * 0.026, headTop - h * 0.005, cx + w * 0.026,
              headTop + h * 0.012, Radius.circular(h * 0.008)),
          tie,
        );
      default:
        // 道髻：男单髻，女半盘发（小发髻 + 长发垂下）。
        if (isFemale) {
          canvas.drawCircle(Offset(cx, headTop - h * 0.01), w * 0.028, hairPaint);
          canvas.drawArc(
            Rect.fromCircle(center: Offset(cx, headTop - h * 0.01), radius: w * 0.028),
            math.pi * 1.2, math.pi * 0.6, false,
            Paint()
              ..color = hairLight.withValues(alpha: 0.7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(0.8, w * 0.006),
          );
          canvas.drawRRect(
            RRect.fromLTRBR(cx - w * 0.026, headTop + h * 0.008, cx + w * 0.026,
                headTop + h * 0.024, Radius.circular(h * 0.008)),
            tie,
          );
        } else {
          canvas.drawCircle(Offset(cx, headTop - h * 0.02), w * 0.032, hairPaint);
          canvas.drawArc(
            Rect.fromCircle(center: Offset(cx, headTop - h * 0.02), radius: w * 0.032),
            math.pi * 1.2, math.pi * 0.6, false,
            Paint()
              ..color = hairLight.withValues(alpha: 0.7)
              ..style = PaintingStyle.stroke
              ..strokeWidth = math.max(0.8, w * 0.006),
          );
          canvas.drawRRect(
            RRect.fromLTRBR(cx - w * 0.028, headTop, cx + w * 0.028,
                headTop + h * 0.02, Radius.circular(h * 0.008)),
            tie,
          );
        }
    }

    // 男版横发簪（韩立式）：一根横簪穿过发髻、向左侧横出，簪头一颗金珠。
    if (!isFemale) {
      canvas.save();
      canvas.translate(cx - rx * 0.30, headTop - h * 0.008);
      canvas.rotate(-0.10);
      canvas.drawRRect(
        RRect.fromLTRBR(-w * 0.135, -w * 0.006, w * 0.075, w * 0.006,
            Radius.circular(w * 0.006)),
        Paint()..color = const Color(0xFF8A6D3B),
      );
      canvas.drawCircle(
        Offset(-w * 0.135, 0),
        w * 0.010,
        Paint()..color = const Color(0xFFD4AF37),
      );
      canvas.restore();
    }

    // 女版发间白花：右侧鬓边一朵五瓣白花 + 金蕊。
    if (isFemale) _drawWhiteFlower(canvas, w, h, rx, ry);
  }

  /// 女版面纱（紫灵式）：半透明淡紫白轻纱遮住鼻尖以下、下巴以上的
  /// 区域，嘴唇隐约可见；上缘一道淡金纱边。
  void _drawFaceVeil(Canvas canvas, double w, double h, double rx, double ry) {
    final cx = w / 2;
    final headCy = h * _headCy;
    final chinY = headCy + ry * (face == '瓜子脸' ? 1.16 : 1.0);
    final veilPath = Path()
      ..moveTo(cx - rx * 0.82, headCy + ry * 0.48)
      ..quadraticBezierTo(cx, headCy + ry * 0.62, cx + rx * 0.82, headCy + ry * 0.48)
      ..quadraticBezierTo(cx + rx * 0.72, chinY - ry * 0.05, cx, chinY + ry * 0.05)
      ..quadraticBezierTo(cx - rx * 0.72, chinY - ry * 0.05, cx - rx * 0.82, headCy + ry * 0.48)
      ..close();
    canvas.drawPath(
      veilPath,
      Paint()..color = const Color(0xFFEDE7FF).withValues(alpha: 0.45),
    );
    canvas.drawPath(
      Path()
        ..moveTo(cx - rx * 0.82, headCy + ry * 0.48)
        ..quadraticBezierTo(cx, headCy + ry * 0.62, cx + rx * 0.82, headCy + ry * 0.48),
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, w * 0.006)
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 女版金冠（紫灵式）：额前一条金冠底带 + 五根高低不一的金刺。
  void _drawGoldCrown(Canvas canvas, double w, double h, double rx, double ry) {
    final cx = w / 2;
    final headCy = h * _headCy;
    final headTop = headCy - ry;
    final baseY = headTop + h * 0.012;
    final gold = Paint()..color = const Color(0xFFD4AF37);
    final goldLight = Paint()..color = const Color(0xFFFFE9A8);
    canvas.drawRRect(
      RRect.fromLTRBR(cx - rx * 0.72, baseY - h * 0.006, cx + rx * 0.72, baseY + h * 0.008,
          Radius.circular(h * 0.005)),
      gold,
    );
    for (var i = 0; i < 5; i++) {
      final t = i / 4;
      final sx = cx + (t - 0.5) * rx * 1.3;
      final spikeH = h * (0.016 + (1 - (t - 0.5).abs() * 2) * 0.014);
      canvas.drawPath(
        Path()
          ..moveTo(sx - w * 0.010, baseY)
          ..lineTo(sx, baseY - spikeH)
          ..lineTo(sx + w * 0.010, baseY)
          ..close(),
        i == 2 ? goldLight : gold,
      );
    }
    canvas.drawCircle(Offset(cx, baseY - h * 0.032), w * 0.006, goldLight);
  }

  /// 发间白花（凡人修真 2 女修式）：五片白花瓣 + 金色花蕊 + 一片绿叶。
  void _drawWhiteFlower(Canvas canvas, double w, double h, double rx, double ry) {
    final cx = w / 2;
    final headCy = h * _headCy;
    final fcx = cx + rx * 1.02;
    final fcy = headCy - ry * 0.55;
    // 绿叶打底。
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(fcx - w * 0.012, fcy + h * 0.012),
        width: w * 0.020,
        height: h * 0.010,
      ),
      Paint()..color = const Color(0xFF5B8C5A),
    );
    // 五片花瓣。
    for (var i = 0; i < 5; i++) {
      final angle = i * math.pi * 2 / 5 - math.pi / 2;
      final px = fcx + math.cos(angle) * w * 0.013;
      final py = fcy + math.sin(angle) * w * 0.013;
      canvas.save();
      canvas.translate(px, py);
      canvas.rotate(angle + math.pi / 2);
      canvas.drawOval(
        Rect.fromCenter(center: Offset.zero, width: w * 0.016, height: w * 0.024),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      canvas.restore();
    }
    canvas.drawCircle(Offset(fcx, fcy), w * 0.007,
        Paint()..color = const Color(0xFFFFD54F));
    canvas.drawCircle(Offset(fcx, fcy), w * 0.0035,
        Paint()..color = const Color(0xFFB8860B));
  }

  /// 袍面纹样：按服饰的纹样在胸前画一个小标记。
  void _drawPattern(Canvas canvas, double w, double h, Paint trim) {
    final cx = w / 2;
    final patternPaint = Paint()
      ..color = trim.color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.008)
      ..strokeCap = StrokeCap.round;
    switch (costume.pattern) {
      case CultivationCostumePattern.cloud:
        canvas.drawArc(
          Rect.fromCircle(center: Offset(cx, h * 0.56), radius: w * 0.03),
          math.pi * 0.1, math.pi * 1.2, false, patternPaint,
        );
        canvas.drawArc(
          Rect.fromCircle(center: Offset(cx + w * 0.035, h * 0.585), radius: w * 0.018),
          math.pi * 1.1, math.pi * 0.9, false, patternPaint,
        );
      case CultivationCostumePattern.plum:
        for (var i = 0; i < 5; i++) {
          final angle = i * math.pi * 2 / 5 - math.pi / 2;
          canvas.drawCircle(
            Offset(cx + math.cos(angle) * w * 0.022, h * 0.56 + math.sin(angle) * w * 0.022),
            w * 0.009,
            Paint()..color = trim.color.withValues(alpha: 0.85),
          );
        }
      case CultivationCostumePattern.crane:
        canvas.drawArc(
          Rect.fromCircle(center: Offset(cx, h * 0.565), radius: w * 0.035),
          math.pi * 1.15, math.pi * 0.7, false, patternPaint,
        );
        canvas.drawCircle(Offset(cx + w * 0.032, h * 0.545), w * 0.008,
            Paint()..color = trim.color.withValues(alpha: 0.85));
      case CultivationCostumePattern.flame:
        final flamePath = Path()
          ..moveTo(cx, h * 0.525)
          ..quadraticBezierTo(cx + w * 0.028, h * 0.56, cx + w * 0.012, h * 0.59)
          ..quadraticBezierTo(cx + w * 0.02, h * 0.575, cx, h * 0.585)
          ..quadraticBezierTo(cx - w * 0.02, h * 0.575, cx - w * 0.012, h * 0.59)
          ..quadraticBezierTo(cx - w * 0.028, h * 0.56, cx, h * 0.525)
          ..close();
        canvas.drawPath(flamePath, Paint()..color = trim.color.withValues(alpha: 0.85));
      case CultivationCostumePattern.wave:
        for (var row = 0; row < 2; row++) {
          final y = h * (0.545 + row * 0.03);
          final wavePath = Path()..moveTo(cx - w * 0.045, y);
          for (var i = 1; i <= 4; i++) {
            wavePath.quadraticBezierTo(
              cx - w * 0.045 + w * 0.0225 * i,
              y + (i.isOdd ? -w * 0.012 : w * 0.012),
              cx - w * 0.045 + w * 0.0225 * (i + 0.5),
              y,
            );
          }
          canvas.drawPath(wavePath, patternPaint);
        }
    }
  }

  // ------------------------------------------------------------------
  // 背景：身后大圆环（凡人修仙传选职业页式：深色环 + 金色符文刻度）
  // 与脚下发光台（青金光晕圆盘），平时淡淡地在，不抢人物。
  // ------------------------------------------------------------------
  void _drawBackdropRing(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY * 0.5;
    final ringR = w * 0.40;
    // 深色环身。
    canvas.drawCircle(
      Offset(cx, cy),
      ringR,
      Paint()
        ..color = const Color(0xFF2B2B33).withValues(alpha: 0.30)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, w * 0.028),
    );
    // 环身金边（上下两道细线）。
    canvas.drawCircle(
      Offset(cx, cy),
      ringR - w * 0.014,
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.35)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, w * 0.006),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      ringR + w * 0.014,
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.22)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(0.8, w * 0.006),
    );
    // 金色符文刻度：环上 8 个小金点 + 顶部一道亮弧。
    for (var i = 0; i < 8; i++) {
      final angle = i * math.pi * 2 / 8 - math.pi / 2;
      canvas.drawCircle(
        Offset(cx + math.cos(angle) * ringR, cy + math.sin(angle) * ringR),
        w * 0.008,
        Paint()..color = const Color(0xFFD4AF37).withValues(alpha: 0.55),
      );
    }
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx, cy), radius: ringR),
      -math.pi * 0.75,
      math.pi * 0.5,
      false,
      Paint()
        ..color = const Color(0xFFFFE9A8).withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.012)
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 脚下发光台：青金光晕圆盘 + 金边。
  void _drawPlatformGlow(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final cy = h * 0.85;
    final pr = w * 0.30;
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: pr * 2, height: pr * 0.42),
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF9FD0F5).withValues(alpha: 0.34),
            const Color(0xFFFFE9A8).withValues(alpha: 0.18),
            const Color(0xFF9FD0F5).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCenter(center: Offset(cx, cy), width: pr * 2, height: pr * 0.42)),
    );
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy), width: pr * 1.7, height: pr * 0.34),
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.008),
    );
  }

  /// 逍遥平时：两只飞轮低透明度慢速绕身。
  void _drawWheelsIdle(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY;
    for (var k = 0; k < 2; k++) {
      final orbitAngle = progress * math.pi * 2 + k * math.pi;
      final wheelCenter = Offset(
        cx + math.cos(orbitAngle) * w * 0.26,
        cy + math.sin(orbitAngle) * h * 0.14,
      );
      _drawMetalWheel(canvas, wheelCenter, w * 0.070, 0.32, progress * math.pi * 2);
    }
  }

  /// 金刚平时：周身一层很淡的金色护罩轮廓。
  void _drawShieldIdle(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY;
    final shieldR = w * 0.36;
    canvas.drawCircle(
      Offset(cx, cy),
      shieldR,
      Paint()..color = const Color(0xFFD4AF37).withValues(alpha: 0.05),
    );
    canvas.drawCircle(
      Offset(cx, cy),
      shieldR,
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.28)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.008),
    );
  }

  /// 金属飞轮：一只带齿圆环（外圈亮银紫、内圈暗、轮毂亮、一段高光弧）。
  void _drawMetalWheel(
    Canvas canvas,
    Offset center,
    double wheelR,
    double alpha,
    double spin,
  ) {
    // 外圈：暗底 + 亮面双层，做出金属环厚度。
    canvas.drawCircle(
      center,
      wheelR,
      Paint()
        ..color = const Color(0xFF6A5ACD).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, wheelR * 0.22),
    );
    canvas.drawCircle(
      center,
      wheelR,
      Paint()
        ..color = const Color(0xFFC9B8F5).withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, wheelR * 0.10),
    );
    // 高光弧：环上最亮的一段。
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: wheelR),
      spin,
      math.pi * 0.6,
      false,
      Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, wheelR * 0.12)
        ..strokeCap = StrokeCap.round,
    );
    // 轮齿：4 根辐条，随飞轮自转。
    for (var s = 0; s < 4; s++) {
      final a = spin + s * math.pi / 2;
      canvas.drawLine(
        Offset(center.dx - math.cos(a) * wheelR, center.dy - math.sin(a) * wheelR),
        Offset(center.dx + math.cos(a) * wheelR, center.dy + math.sin(a) * wheelR),
        Paint()
          ..color = const Color(0xFFB9A8F0).withValues(alpha: alpha * 0.8)
          ..strokeWidth = math.max(1, wheelR * 0.10),
      );
    }
    canvas.drawCircle(center, wheelR * 0.25,
        Paint()..color = const Color(0xFFD8C8FF).withValues(alpha: alpha));
    canvas.drawCircle(center, wheelR * 0.10,
        Paint()..color = const Color(0xFF8A7BD8).withValues(alpha: alpha));
  }

  /// 青竹蜂云剑（青元剑诀的绿剑）：翠绿剑身 + 白绿刃光 + 金剑格，
  /// 带一层淡淡绿光晕；天道平时绕身与放技能的飞剑都用它。
  void _drawGreenBlade(Canvas canvas, double w, double alpha) {
    // 绿光晕。
    canvas.drawLine(
      Offset(-w * 0.05, 0),
      Offset(w * 0.06, 0),
      Paint()
        ..color = const Color(0xFF7CFFB2).withValues(alpha: alpha * 0.30)
        ..strokeWidth = w * 0.026
        ..strokeCap = StrokeCap.round,
    );
    final blade = Path()
      ..moveTo(w * 0.055, 0)
      ..lineTo(w * 0.015, -w * 0.009)
      ..lineTo(-w * 0.045, -w * 0.002)
      ..lineTo(-w * 0.045, w * 0.002)
      ..lineTo(w * 0.015, w * 0.009)
      ..close();
    canvas.drawPath(
      blade,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: [
            const Color(0xFFD8FFE8).withValues(alpha: alpha),
            const Color(0xFF4ADE80).withValues(alpha: alpha),
            const Color(0xFF16A34A).withValues(alpha: alpha),
          ],
        ).createShader(Rect.fromLTWH(-w * 0.045, -w * 0.009, w * 0.10, w * 0.018)),
    );
    canvas.drawLine(
      Offset(-w * 0.04, 0),
      Offset(w * 0.05, 0),
      Paint()
        ..color = Colors.white.withValues(alpha: alpha * 0.8)
        ..strokeWidth = math.max(0.8, w * 0.005),
    );
    // 金剑格 + 柄。
    canvas.drawRRect(
      RRect.fromLTRBR(-w * 0.052, -w * 0.016, -w * 0.044, w * 0.016,
          Radius.circular(w * 0.005)),
      Paint()..color = const Color(0xFFD4AF37).withValues(alpha: alpha),
    );
    canvas.drawLine(
      Offset(-w * 0.075, 0),
      Offset(-w * 0.052, 0),
      Paint()
        ..color = const Color(0xFF14532D).withValues(alpha: alpha)
        ..strokeWidth = math.max(1.5, w * 0.010)
        ..strokeCap = StrokeCap.round,
    );
  }

  /// 天道·青元剑诀 / 大庚剑阵：7 把青竹蜂云剑（绿剑）从身后升起、
  /// 绕身成剑圈布成剑阵（绿光阵环 + 剑光连线），再向前收束斩出，
  /// 带绿色剑光拖尾。进度 0→0.4 升起、0.3→0.8 绕转布阵、0.7→1 收束。
  void _drawSwords(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY * 0.5;
    final p = skillProgress;
    final appear = (p / 0.15).clamp(0.0, 1.0);
    final fade = p > 0.85 ? ((1 - p) / 0.15).clamp(0.0, 1.0) : 1.0;
    final alpha = appear * fade;
    if (alpha <= 0) return;

    final converge = Offset(cx + w * 0.30, h * 0.38 + floatY * 0.5);
    final gather = ((p - 0.7) / 0.3).clamp(0.0, 1.0);
    final green = const Color(0xFF22C55E);
    final greenLight = const Color(0xFFB6FFD6);

    // 大庚剑阵：绕转布阵时显出绿光阵环 + 人物到每把剑的剑光连线。
    if (p > 0.25 && p < 0.85) {
      final formAlpha = alpha * (p < 0.4 ? (p - 0.25) / 0.15 : 1.0);
      final orbitR = w * 0.30;
      canvas.drawCircle(
        Offset(cx, cy),
        orbitR,
        Paint()
          ..color = green.withValues(alpha: 0.4 * formAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, w * 0.008),
      );
      for (var i = 0; i < _swordCount; i++) {
        final angle = (i / _swordCount) * math.pi * 2 + p * math.pi * 2.5;
        final swordPos = Offset(
          cx + math.cos(angle) * orbitR,
          cy + math.sin(angle) * orbitR * 0.8,
        );
        canvas.drawLine(
          Offset(cx, cy),
          swordPos,
          Paint()
            ..color = greenLight.withValues(alpha: 0.25 * formAlpha)
            ..strokeWidth = math.max(0.8, w * 0.005),
        );
        canvas.drawCircle(
          swordPos,
          w * 0.010,
          Paint()..color = greenLight.withValues(alpha: 0.6 * formAlpha),
        );
      }
    }

    for (var i = 0; i < _swordCount; i++) {
      final angle = (i / _swordCount) * math.pi * 2 + p * math.pi * 2.5;
      final orbitR = w * 0.30;
      final orbit = Offset(
        cx + math.cos(angle) * orbitR,
        cy + math.sin(angle) * orbitR * 0.8,
      );
      final rise = (p / 0.4).clamp(0.0, 1.0);
      final risen = Offset(orbit.dx, orbit.dy + (1 - rise) * h * 0.25);
      final pos = Offset(
        risen.dx + (converge.dx - risen.dx) * gather,
        risen.dy + (converge.dy - risen.dy) * gather,
      );
      final swordAngle = gather > 0
          ? math.atan2(converge.dy - pos.dy, converge.dx - pos.dx)
          : angle + math.pi / 2;

      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(swordAngle);
      // 剑光拖尾（身后一道渐隐绿线）。
      canvas.drawLine(
        Offset(-w * 0.11, 0),
        Offset(-w * 0.08, 0),
        Paint()
          ..color = greenLight.withValues(alpha: alpha * 0.7)
          ..strokeWidth = math.max(1.5, w * 0.012)
          ..strokeCap = StrokeCap.round,
      );
      _drawGreenBlade(canvas, w, alpha);
      canvas.restore();
    }

    // 收束时的剑气闪光（绿）。
    if (gather > 0) {
      final flashR = w * 0.10 * gather;
      canvas.drawCircle(
        converge,
        flashR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              greenLight.withValues(alpha: alpha * 0.8),
              green.withValues(alpha: alpha * 0.25),
              green.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: converge, radius: flashR)),
      );
    }
  }

  /// 逍遥·真魔功：残影在人物身后闪烁（见 _drawAfterimages），这里画
  /// 两只金属飞轮绕身高速旋转 + 暗色魔气。
  void _drawWheels(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY;
    final p = skillProgress;
    final alpha = ((p / 0.15).clamp(0.0, 1.0) *
            (p > 0.85 ? ((1 - p) / 0.15).clamp(0.0, 1.0) : 1.0))
        .clamp(0.0, 1.0);
    if (alpha <= 0) return;

    // 暗色魔气：人物周身几团缓动的紫黑雾。
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2 + p * math.pi * 3;
      final mist = Offset(
        cx + math.cos(angle) * w * 0.26,
        cy + math.sin(angle) * h * 0.16,
      );
      canvas.drawCircle(
        mist,
        w * 0.06,
        Paint()
          ..color = const Color(0xFF5B4A8C).withValues(alpha: alpha * 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }

    // 两只飞轮：绕身高速旋转的金属环。
    for (var k = 0; k < 2; k++) {
      final orbitAngle = p * math.pi * 6 + k * math.pi;
      final wheelCenter = Offset(
        cx + math.cos(orbitAngle) * w * 0.24,
        cy + math.sin(orbitAngle) * h * 0.13,
      );
      _drawMetalWheel(
        canvas,
        wheelCenter,
        w * 0.085,
        alpha * 0.95,
        p * math.pi * 10 + k * math.pi / 2,
      );
    }
  }

  /// 逍遥残影：两个半透明分身在人物两侧左右闪烁瞬移。
  void _drawAfterimages(Canvas canvas, double w, double h, double floatY, double scale) {
    final cx = w / 2;
    final p = skillProgress;
    final flicker = (math.sin(p * math.pi * 6) * 0.5 + 0.5);
    for (var k = 0; k < 2; k++) {
      final side = k == 0 ? -1.0 : 1.0;
      final offset = side * w * 0.09 * (0.6 + 0.4 * flicker);
      final opacity = 0.28 * math.sin(p * math.pi).clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;
      canvas.save();
      canvas.translate(cx + offset, h * 0.46 + floatY);
      canvas.scale(scale);
      canvas.translate(-cx, -h * 0.46);
      canvas.saveLayer(
        null,
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: opacity),
      );
      _drawFigure(canvas, w, h);
      canvas.restore();
      canvas.restore();
    }
  }

  /// 金刚·泰阳诀：周身张开金色护罩，罩面径向渐变光晕 + 流光弧
  /// 与反伤波纹。
  void _drawShield(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.46 + floatY;
    final p = skillProgress;
    final alpha = ((p / 0.2).clamp(0.0, 1.0) *
            (p > 0.8 ? ((1 - p) / 0.2).clamp(0.0, 1.0) : 1.0))
        .clamp(0.0, 1.0);
    if (alpha <= 0) return;

    final shieldR = w * 0.36;
    final gold = const Color(0xFFD4AF37);
    final goldLight = const Color(0xFFFFE9A8);
    final center = Offset(cx, cy);

    // 罩面：径向渐变光晕（中心亮、边缘淡）+ 金边。
    canvas.drawCircle(
      center,
      shieldR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            goldLight.withValues(alpha: alpha * 0.28),
            gold.withValues(alpha: alpha * 0.12),
            gold.withValues(alpha: alpha * 0.02),
          ],
          stops: const [0.0, 0.6, 1.0],
        ).createShader(Rect.fromCircle(center: center, radius: shieldR)),
    );
    canvas.drawCircle(
      center,
      shieldR,
      Paint()
        ..color = gold.withValues(alpha: alpha * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, w * 0.018),
    );
    canvas.drawCircle(
      center,
      shieldR - w * 0.012,
      Paint()
        ..color = goldLight.withValues(alpha: alpha * 0.7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.008),
    );
    // 流光：两段绕罩旋转的亮弧。
    for (var k = 0; k < 2; k++) {
      final start = p * math.pi * 4 + k * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: shieldR),
        start,
        math.pi * 0.5,
        false,
        Paint()
          ..color = goldLight.withValues(alpha: alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(2.5, w * 0.022)
          ..strokeCap = StrokeCap.round,
      );
    }
    // 反伤波纹：两道向外扩散的涟漪环。
    for (var k = 0; k < 2; k++) {
      final ripple = ((p * 1.4 + k * 0.5) % 1.0);
      final rippleR = shieldR * (1 + ripple * 0.35);
      canvas.drawCircle(
        center,
        rippleR,
        Paint()
          ..color = gold.withValues(alpha: alpha * 0.5 * (1 - ripple))
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, w * 0.012),
      );
    }
  }

  void _drawDots(Canvas canvas, double w, double h) {
    for (var i = 0; i < _dotSlots.length; i++) {
      // 每颗光点按自己的相位循环。
      final phase = (progress + i / _dotSlots.length) % 1.0;
      // 从人物下方升到头顶上方。
      final y = h * (0.92 - 0.62 * phase);
      // 上升时左右轻摆。
      final x =
          w * _dotSlots[i] + math.sin((phase + i) * math.pi * 2) * w * 0.015;
      // 快升快现、升到顶渐隐。
      final alpha = phase < 0.15
          ? phase / 0.15
          : 1 - (phase - 0.15) / 0.85;
      final color = i.isEven
          ? const Color(0xFFD8C8FF)
          : const Color(0xFFBFE3FF);
      canvas.drawCircle(
        Offset(x, y),
        _dotRadii[i] * (w / 120),
        Paint()..color = color.withValues(alpha: alpha.clamp(0, 1) * 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_MeditatingAvatarPainter old) =>
      old.progress != progress ||
      old.skillProgress != skillProgress ||
      old.profession != profession ||
      old.costume != costume ||
      old.face != face ||
      old.hairstyle != hairstyle ||
      old.hairColor != hairColor ||
      old.isFemale != isFemale;
}
