import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/cultivation.dart';

/// 站立大人物：网页游戏选人界面的中央立绘（仿凡人修仙传网页游戏
/// charsel_1：人物站在圆形发光台上，身后一个大圆环传送门），
/// 全部用 [CustomPainter] 画，不依赖外部图片素材。
///
/// 2.5D 质感 + 短剧/漫剧动漫风：袍面左右明暗渐变、有厚度感；
/// 脸精致（眉毛、眼睛带眼白+虹膜+瞳孔+高光、鼻子、嘴、腮红、
/// 面部阴影）；道袍有褶皱/腰带/领口层次；发髻像样。
///
/// 形象按用户发的图定版，不自己编：男的是韩立（user_hanli.jpg：
/// 蓝金袍、金色云纹刺绣、长发 + 横发簪、五官精致冷峻）；女的是
/// 用户发的女修（user_ziling.png 紫灵：紫裙金边、金冠、长发飘飞、
/// 面纱、紫金飘带；user_nangongwan.png 南宫婉：白青裙、金饰、
/// 花饰发髻、青白飘带），仙气飘飘、衣袂飘飞。袍/裙主色仍按所选
/// 服饰袍色走（默认青色道袍时男袍近韩立蓝袍、女裙近南宫婉白青；
/// 选紫色锦袍时女裙就是紫灵紫裙），换服饰时颜色跟着变。
///
/// 平时站立呼吸（轻微浮动 + 光晕脉动 + 发光台光圈脉动）；隔几秒
/// 放一次本职业招牌技能，点一下人物也能立刻放技能：
/// - 天道（剑修）青元剑诀 / 大庚剑阵：韩立手掌前推施法，多把青竹蜂云剑
///   （绿剑带绿光）从身后升起、绕身飞舞，再布成剑阵（剑光连线成阵），
///   最后向前收束斩出。
/// - 逍遥（身法/飞轮）真魔功：残影闪烁瞬移，两只飞轮绕身高速旋转。
/// - 金刚（防御/反伤）泰阳诀：周身张开金色护罩，罩面流光与反伤波纹。
///
/// 武器平时也看得见：天道右手持长剑斜指地面，逍遥一只飞轮在手、
/// 一只飞轮浮在肩侧，金刚身周一圈淡淡的金罩。
/// 性别/脸型/发型/发色/服饰/职业都画在人物身上。
class StandingCharacter extends StatefulWidget {
  const StandingCharacter({
    super.key,
    this.width = 300,
    this.height = 380,
    this.isFemale = false,
    this.costume,
    this.profession = defaultCultivationProfession,
    this.face = defaultCultivationFace,
    this.hairstyle = defaultCultivationHairstyle,
    this.hairColor,
    this.autoCastSkill = true,
  });

  /// 画布宽。
  final double width;

  /// 画布高（比宽大，人物站立全身）。
  final double height;

  /// 性别：男帅哥男、女靓妹女（凡人修真 2 女修气质），只分男女。
  final bool isFemale;

  /// 服饰（默认青色道袍）。
  final CultivationCostume? costume;

  /// 职业（天道/逍遥/金刚），决定姿势、武器与技能。
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
  State<StandingCharacter> createState() => _StandingCharacterState();
}

class _StandingCharacterState extends State<StandingCharacter>
    with TickerProviderStateMixin {
  late final AnimationController _breathe;
  late final AnimationController _skill;
  Timer? _openTimer;
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
      // 开场不久就放一次技能：创建页中央大人物一亮相就是施展技能的
      // 动态姿势（不是站着不动等 7 秒），之后每 7 秒再放一次。
      // 开场定时器要存下来，dispose 时一起取消，否则树拆了它还挂着，
      // 测试会报「Timer is still pending」。
      _openTimer = Timer(const Duration(milliseconds: 800), _castSkill);
      _skillTimer = Timer.periodic(const Duration(seconds: 7), (_) {
        _castSkill();
      });
    }
  }

  @override
  void didUpdateWidget(covariant StandingCharacter oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换职业/换性别时立刻放一次该职业技能，中央人物马上跟着变。
    if (widget.autoCastSkill &&
        (widget.profession != oldWidget.profession ||
            widget.isFemale != oldWidget.isFemale)) {
      _castSkill();
    }
  }

  /// 放一次技能：从头放（换职业/换性别时立刻重放该职业技能，
  /// 中央人物马上跟着变，不用等上一轮放完）。
  void _castSkill() {
    if (!mounted) return;
    _skill.forward(from: 0);
  }

  @override
  void dispose() {
    _openTimer?.cancel();
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
        width: widget.width,
        height: widget.height,
        child: RepaintBoundary(
          child: AnimatedBuilder(
            animation: Listenable.merge([_breathe, _skill]),
            builder: (context, child) => CustomPaint(
              size: Size(widget.width, widget.height),
              painter: _StandingCharacterPainter(
                progress: _breathe.value,
                skillProgress: _skill.value,
                profession: widget.profession,
                costume: widget.costume ?? cultivationCostumes.first,
                face: widget.face,
                hairstyle: widget.hairstyle,
                hairColor: widget.hairColor ?? cultivationHairColors.first,
                isFemale: widget.isFemale,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 一帧的画法：身后大圆环、发光圆台、人物（呼吸浮动）、技能层、上升光点。
/// 几何按画布尺寸的比例算，只有呼吸浮动是固定逻辑像素（约 ±3）。
class _StandingCharacterPainter extends CustomPainter {
  _StandingCharacterPainter({
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

  static const _dotSlots = <double>[0.14, 0.28, 0.44, 0.58, 0.72, 0.86];
  static const _dotRadii = <double>[2.2, 1.6, 2.6, 1.8, 2.2, 1.5];
  static const _swordCount = 7;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final cx = w / 2;
    final cycle = progress * math.pi * 2;

    // 呼吸：上下轻浮（±3px）+ 轻微缩放。
    final breathe = math.sin(cycle);
    final floatY = breathe * 3;
    final scale = 1 + 0.012 * breathe;

    // 身后大圆环（传送门/光环）：深色环体 + 金边 + 内侧灵气辉光。
    final ringCenter = Offset(cx, h * 0.44);
    final ringR = w * 0.46;
    final ringPulse = 0.5 + 0.5 * math.sin(cycle - math.pi / 3);
    canvas.drawCircle(
      ringCenter,
      ringR,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF9FD0F5).withValues(alpha: 0.10 + 0.06 * ringPulse),
            const Color(0xFFB9A8F0).withValues(alpha: 0.05),
            const Color(0xFFB9A8F0).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: ringCenter, radius: ringR)),
    );
    canvas.drawCircle(
      ringCenter,
      ringR,
      Paint()
        ..color = const Color(0xFF141C2E)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(6, w * 0.035),
    );
    canvas.drawCircle(
      ringCenter,
      ringR,
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.55 + 0.25 * ringPulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.008),
    );
    // 环上金色符文点。
    for (var i = 0; i < 8; i++) {
      final a = i * math.pi / 4 + progress * math.pi / 6;
      canvas.drawCircle(
        Offset(ringCenter.dx + math.cos(a) * ringR,
            ringCenter.dy + math.sin(a) * ringR),
        math.max(2, w * 0.012),
        Paint()..color = const Color(0xFFD4AF37).withValues(alpha: 0.85),
      );
    }

    // 人物身后光晕。
    final haloCenter = Offset(cx, h * 0.48 + floatY * 0.5);
    final haloRadius = w * 0.34 * (1 + 0.06 * math.sin(cycle - math.pi / 3));
    canvas.drawCircle(
      haloCenter,
      haloRadius,
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFFB9A8F0).withValues(alpha: 0.20),
            const Color(0xFF9FD0F5).withValues(alpha: 0.10),
            const Color(0xFF9FD0F5).withValues(alpha: 0),
          ],
        ).createShader(Rect.fromCircle(center: haloCenter, radius: haloRadius)),
    );

    // 圆形发光台：三层椭圆（外辉光 + 台面 + 内圈金光）+ 脉动光圈。
    final platformCenter = Offset(cx, h * 0.90);
    final platformW = w * 0.80;
    final platformH = h * 0.075;
    canvas.drawOval(
      Rect.fromCenter(
          center: platformCenter,
          width: platformW * 1.12,
          height: platformH * 1.9),
      Paint()
        ..color = const Color(0xFF7FD0E8)
            .withValues(alpha: 0.10 + 0.08 * ringPulse),
    );
    canvas.drawOval(
      Rect.fromCenter(
          center: platformCenter, width: platformW, height: platformH),
      Paint()
        ..shader = RadialGradient(
          colors: [
            const Color(0xFF3E6B8C),
            const Color(0xFF1E3A55),
            const Color(0xFF12233A),
          ],
        ).createShader(Rect.fromCenter(
            center: platformCenter, width: platformW, height: platformH)),
    );
    canvas.drawOval(
      Rect.fromCenter(
          center: platformCenter, width: platformW, height: platformH),
      Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.008),
    );
    canvas.drawOval(
      Rect.fromCenter(
          center: platformCenter,
          width: platformW * 0.62,
          height: platformH * 0.55),
      Paint()
        ..color = const Color(0xFF9FD0F5)
            .withValues(alpha: 0.22 + 0.14 * ringPulse)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.2, w * 0.006),
    );
    // 台下地面阴影。
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx, h * 0.925),
          width: w * 0.55,
          height: h * 0.02),
      Paint()..color = const Color(0xFF000000).withValues(alpha: 0.30),
    );

    // 逍遥·真魔功：残影画在人物身后。
    if (profession == '逍遥' && skillProgress > 0) {
      _drawAfterimages(canvas, w, h, floatY, scale);
    }

    canvas.save();
    canvas.translate(cx, h * 0.50 + floatY);
    final stanceScale =
        (profession == '金刚' && skillProgress > 0)
            ? 1 + 0.03 * math.sin(skillProgress * math.pi)
            : 1.0;
    canvas.scale(scale * stanceScale);
    canvas.translate(-cx, -h * 0.50);
    _drawFigure(canvas, w, h);
    canvas.restore();

    // 平时也看得见的武器（天道持剑、逍遥飞轮、金刚淡金罩）。
    _drawIdleWeapon(canvas, w, h, floatY);

    // 技能层。
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

  // ---------- 人物 ----------

  void _drawFigure(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final robe = costume.robe;
    final robeDark =
        Color.lerp(robe, const Color(0xFF000000), 0.28) ?? robe;
    final robeLight =
        Color.lerp(robe, const Color(0xFFFFFFFF), 0.30) ?? robe;
    final trim = costume.trim;
    final belt = costume.belt;
    final skin = const Color(0xFFFFE0BF);
    final skinShade = const Color(0xFFF0C49A);
    final hairPaint = Paint()..color = hairColor.color;
    final gold = const Color(0xFFD4AF37);
    final goldLight = const Color(0xFFFFE9A8);

    // 身后长发画在袍身之后：女版向左飘散（紫灵/南宫婉长发飘飞），
    // 男版韩立长发垂到腰后两侧。
    if (isFemale) {
      _drawFemaleBackHair(canvas, w, h, hairPaint);
    } else {
      _drawMaleBackHair(canvas, w, h, hairPaint);
    }

    // 靴尖（袍摆下露出一点）。
    final bootPaint = Paint()..color = const Color(0xFF2B2118);
    for (final side in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromLTRBR(
          cx + side * w * 0.055 - w * 0.028,
          h * 0.845,
          cx + side * w * 0.055 + w * 0.028,
          h * 0.885,
          Radius.circular(h * 0.012),
        ),
        bootPaint,
      );
    }

    // 袍身/裙摆：肩到摆的修长身形，左右明暗渐变（2.5D 厚度感）。
    final shoulderHalf = isFemale ? w * 0.145 : w * 0.175;
    final waistHalf = isFemale ? w * 0.115 : w * 0.145;
    final hemHalf = isFemale ? w * 0.20 : w * 0.185;
    final robePath = Path()
      ..moveTo(cx - shoulderHalf, h * 0.265)
      ..quadraticBezierTo(cx - waistHalf - w * 0.015, h * 0.38,
          cx - waistHalf, h * 0.485)
      ..quadraticBezierTo(cx - hemHalf, h * 0.68, cx - hemHalf, h * 0.855)
      ..quadraticBezierTo(cx, h * 0.875, cx + hemHalf, h * 0.855)
      ..quadraticBezierTo(cx + hemHalf, h * 0.68, cx + waistHalf, h * 0.485)
      ..quadraticBezierTo(cx + waistHalf + w * 0.015, h * 0.38,
          cx + shoulderHalf, h * 0.265)
      ..quadraticBezierTo(cx, h * 0.235, cx - shoulderHalf, h * 0.265)
      ..close();
    // 女版裙摆上身金色、裙摆袍色：先整件画袍色，再在胸前叠金色抹胸。
    canvas.drawPath(
      robePath,
      Paint()
        ..shader = LinearGradient(
          colors: [robeLight, robe, robeDark],
          stops: const [0.0, 0.55, 1.0],
        ).createShader(
            Rect.fromLTRB(cx - hemHalf, h * 0.25, cx + hemHalf, h * 0.86)),
    );
    // 袍面褶皱：几道从腰垂到摆的弧线。
    final foldPaint = Paint()
      ..color = robeDark.withValues(alpha: 0.55)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.006)
      ..strokeCap = StrokeCap.round;
    for (final fx in [-0.62, -0.22, 0.22, 0.62]) {
      final foldPath = Path()
        ..moveTo(cx + hemHalf * fx * 0.55, h * 0.52)
        ..quadraticBezierTo(cx + hemHalf * fx * 0.8, h * 0.68,
            cx + hemHalf * fx, h * 0.845);
      canvas.drawPath(foldPath, foldPaint);
    }
    // 袍面纹样（胸前）。
    _drawPattern(canvas, w, h, Paint()..color = trim);

    if (isFemale) {
      // 金色露肩抹胸 + 金项链 + 腰间花结（凡人修真 2 女修上身）。
      final bodicePath = Path()
        ..moveTo(cx - shoulderHalf * 0.72, h * 0.275)
        ..quadraticBezierTo(cx, h * 0.325, cx + shoulderHalf * 0.72, h * 0.275)
        ..quadraticBezierTo(cx + waistHalf * 0.85, h * 0.36, cx + waistHalf * 0.8,
            h * 0.42)
        ..quadraticBezierTo(cx, h * 0.44, cx - waistHalf * 0.8, h * 0.42)
        ..quadraticBezierTo(cx - waistHalf * 0.85, h * 0.36,
            cx - shoulderHalf * 0.72, h * 0.275)
        ..close();
      canvas.drawPath(
        bodicePath,
        Paint()
          ..shader = LinearGradient(
            colors: [goldLight, gold, const Color(0xFF9A7B1E)],
            stops: const [0.0, 0.55, 1.0],
          ).createShader(
              Rect.fromLTRB(cx - shoulderHalf * 0.75, h * 0.27,
                  cx + shoulderHalf * 0.75, h * 0.44)),
      );
      // 抹胸上缘金边。
      canvas.drawPath(
        Path()
          ..moveTo(cx - shoulderHalf * 0.72, h * 0.275)
          ..quadraticBezierTo(cx, h * 0.325, cx + shoulderHalf * 0.72, h * 0.275),
        Paint()
          ..color = goldLight
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, w * 0.009)
          ..strokeCap = StrokeCap.round,
      );
      // 金项链。
      canvas.drawPath(
        Path()
          ..moveTo(cx - w * 0.045, h * 0.26)
          ..quadraticBezierTo(cx, h * 0.315, cx + w * 0.045, h * 0.26),
        Paint()
          ..color = gold
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, w * 0.007),
      );
      canvas.drawCircle(Offset(cx, h * 0.305), w * 0.011, Paint()..color = gold);
      // 腰带：金腰带 + 腰间花结。
      canvas.drawRRect(
        RRect.fromLTRBR(cx - waistHalf - w * 0.008, h * 0.475,
            cx + waistHalf + w * 0.008, h * 0.505, Radius.circular(h * 0.014)),
        Paint()..color = gold,
      );
      _drawSmallFlower(canvas, Offset(cx, h * 0.49), w * 0.020);
      // 裙摆金边。
      canvas.drawPath(
        Path()
          ..moveTo(cx - hemHalf, h * 0.855)
          ..quadraticBezierTo(cx, h * 0.875, cx + hemHalf, h * 0.855),
        Paint()
          ..color = gold.withValues(alpha: 0.9)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, w * 0.009)
          ..strokeCap = StrokeCap.round,
      );
    } else {
      // 男版韩立：金色云纹刺绣（胸前两道金云纹）+ 交领金边 +
      // 领口 V 形镶边 + 腰带 + 带结。
      final goldEmbroidery = Paint()
        ..color = const Color(0xFFD4AF37).withValues(alpha: 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1.5, w * 0.009)
        ..strokeCap = StrokeCap.round;
      for (final side in [-1.0, 1.0]) {
        canvas.drawArc(
          Rect.fromCircle(
              center: Offset(cx + side * w * 0.055, h * 0.40),
              radius: w * 0.026),
          math.pi * 0.1,
          math.pi * 1.1,
          false,
          goldEmbroidery,
        );
        // 交领金边：从领口斜下到腰。
        canvas.drawLine(
          Offset(cx + side * w * 0.045, h * 0.30),
          Offset(cx + side * w * 0.012, h * 0.47),
          goldEmbroidery,
        );
      }
      final collarPath = Path()
        ..moveTo(cx - w * 0.055, h * 0.27)
        ..lineTo(cx, h * 0.335)
        ..lineTo(cx + w * 0.055, h * 0.27)
        ..lineTo(cx + w * 0.035, h * 0.26)
        ..lineTo(cx, h * 0.305)
        ..lineTo(cx - w * 0.035, h * 0.26)
        ..close();
      canvas.drawPath(collarPath, Paint()..color = trim);
      canvas.drawRRect(
        RRect.fromLTRBR(cx - waistHalf - w * 0.008, h * 0.475,
            cx + waistHalf + w * 0.008, h * 0.505, Radius.circular(h * 0.014)),
        Paint()..color = belt,
      );
      canvas.drawCircle(
          Offset(cx, h * 0.49), w * 0.020, Paint()..color = trim);
    }

    // 女版飘带：紫灵紫金飘带 + 南宫婉青白飘带，从腰间向两侧飘飞。
    if (isFemale) _drawRibbons(canvas, w, h);

    // 手臂与手（姿势按职业分）。
    _drawArms(canvas, w, h, robe, robeDark, trim, skin, gold);

    // 脖子 + 头 + 脸 + 发。
    canvas.drawRRect(
      RRect.fromLTRBR(cx - w * 0.022, h * 0.20, cx + w * 0.022, h * 0.265,
          Radius.circular(w * 0.02)),
      Paint()..color = skinShade,
    );
    _drawHead(canvas, w, h, Paint()..color = skin, Paint()..color = skinShade, hairPaint, gold, Paint()..color = trim);
  }

  /// 女版身后长发：向左飘的大片头发 + 几缕垂到腰间的发丝。
  void _drawFemaleBackHair(
      Canvas canvas, double w, double h, Paint hairPaint) {
    final cx = w / 2;
    // 向左飘的主发片（风吹向左侧）：收窄、尖端收细，分两缕画，
    // 像发丝一样飘，不是一整块黑布。
    final flowPath = Path()
      ..moveTo(cx - w * 0.05, h * 0.10)
      ..quadraticBezierTo(cx - w * 0.22, h * 0.055, cx - w * 0.33, h * 0.13)
      ..quadraticBezierTo(cx - w * 0.30, h * 0.16, cx - w * 0.24, h * 0.175)
      ..quadraticBezierTo(cx - w * 0.14, h * 0.15, cx - w * 0.08, h * 0.14)
      ..quadraticBezierTo(cx - w * 0.05, h * 0.12, cx - w * 0.05, h * 0.10)
      ..close();
    canvas.drawPath(flowPath, hairPaint);
    // 第二缕飘发（更细、更低，带一点弧度）。
    final flowPath2 = Path()
      ..moveTo(cx - w * 0.07, h * 0.16)
      ..quadraticBezierTo(cx - w * 0.20, h * 0.17, cx - w * 0.28, h * 0.235)
      ..quadraticBezierTo(cx - w * 0.22, h * 0.25, cx - w * 0.15, h * 0.22)
      ..quadraticBezierTo(cx - w * 0.10, h * 0.19, cx - w * 0.07, h * 0.16)
      ..close();
    canvas.drawPath(flowPath2, hairPaint);
    // 发丝高光：主发片上一道淡色细线。
    canvas.drawPath(
      Path()
        ..moveTo(cx - w * 0.08, h * 0.105)
        ..quadraticBezierTo(cx - w * 0.20, h * 0.08, cx - w * 0.29, h * 0.135),
      Paint()
        ..color = const Color(0xFF6B5A7A)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.005)
        ..strokeCap = StrokeCap.round,
    );
    // 右侧垂到腰间的长发。
    final fallPath = Path()
      ..moveTo(cx + w * 0.07, h * 0.12)
      ..quadraticBezierTo(cx + w * 0.16, h * 0.30, cx + w * 0.13, h * 0.52)
      ..quadraticBezierTo(cx + w * 0.10, h * 0.54, cx + w * 0.08, h * 0.50)
      ..quadraticBezierTo(cx + w * 0.10, h * 0.30, cx + w * 0.05, h * 0.14)
      ..close();
    canvas.drawPath(fallPath, hairPaint);
    // 左侧垂发一缕。
    final fallLeft = Path()
      ..moveTo(cx - w * 0.08, h * 0.13)
      ..quadraticBezierTo(cx - w * 0.17, h * 0.32, cx - w * 0.14, h * 0.50)
      ..quadraticBezierTo(cx - w * 0.11, h * 0.50, cx - w * 0.10, h * 0.34)
      ..quadraticBezierTo(cx - w * 0.09, h * 0.20, cx - w * 0.06, h * 0.14)
      ..close();
    canvas.drawPath(fallLeft, hairPaint);
  }

  /// 男版韩立身后长发：两侧各一缕垂到腰后（发簪束起、其余披散）。
  void _drawMaleBackHair(
      Canvas canvas, double w, double h, Paint hairPaint) {
    final cx = w / 2;
    for (final side in [-1.0, 1.0]) {
      final fallPath = Path()
        ..moveTo(cx + side * w * 0.07, h * 0.12)
        ..quadraticBezierTo(cx + side * w * 0.14, h * 0.30,
            cx + side * w * 0.11, h * 0.52)
        ..quadraticBezierTo(cx + side * w * 0.085, h * 0.53,
            cx + side * w * 0.075, h * 0.50)
        ..quadraticBezierTo(cx + side * w * 0.09, h * 0.30,
            cx + side * w * 0.05, h * 0.14)
        ..close();
      canvas.drawPath(fallPath, hairPaint);
    }
  }

  /// 手臂：天道右手持剑、左手前推施法掌；逍遥右手托飞轮、左手拂袖；
  /// 金刚双臂下垂握拳。女版是轻纱飘袖（半透明淡金大袖）。
  void _drawArms(Canvas canvas, double w, double h, Color robe,
      Color robeDark, Color trim, Color skin, Color gold) {
    final cx = w / 2;
    final sleevePaint = isFemale
        ? (Paint()
          ..color = const Color(0xFFFFE9A8).withValues(alpha: 0.70))
        : (Paint()..color = robe);
    final sleeveShade = Paint()
      ..color = (isFemale
              ? const Color(0xFFF5D98A)
              : robeDark)
          .withValues(alpha: isFemale ? 0.60 : 1.0);
    final line = Paint()
      ..color = trim.withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * 0.007)
      ..strokeCap = StrokeCap.round;

    // 左臂（画面左）：天道韩立手掌前推施法（青元剑诀施法掌），其余自然下垂/拂袖。
    if (profession == '天道') {
      // 左袖从肩斜向胸前，掌心向前推出。
      final leftSleeve = Path()
        ..moveTo(cx - w * 0.14, h * 0.28)
        ..quadraticBezierTo(cx - w * 0.24, h * 0.36, cx - w * 0.19, h * 0.44)
        ..quadraticBezierTo(cx - w * 0.15, h * 0.46, cx - w * 0.12, h * 0.42)
        ..quadraticBezierTo(cx - w * 0.13, h * 0.35, cx - w * 0.09, h * 0.30)
        ..close();
      canvas.drawPath(leftSleeve, isFemale ? sleeveShade : sleevePaint);
      // 施法掌：掌心向前，五指微张，掌前一团绿光。
      final hand = Offset(cx - w * 0.175, h * 0.435);
      canvas.drawCircle(hand, w * 0.028, Paint()..color = skin);
      for (var f = 0; f < 4; f++) {
        final fa = -math.pi * 0.7 + f * math.pi * 0.18;
        canvas.drawLine(
          hand,
          Offset(hand.dx + math.cos(fa) * w * 0.035,
              hand.dy + math.sin(fa) * w * 0.035),
          line..strokeWidth = math.max(1.5, w * 0.009),
        );
      }
      canvas.drawCircle(
        Offset(hand.dx - w * 0.045, hand.dy - h * 0.01),
        w * 0.020,
        Paint()
          ..color = const Color(0xFF7DF0B0).withValues(alpha: 0.55)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    } else {
      // 左袖自然垂到腰侧（女版轻纱袖向外飘）。
      final leftSleeve = Path()
        ..moveTo(cx - w * 0.14, h * 0.28)
        ..quadraticBezierTo(cx - w * (isFemale ? 0.30 : 0.23), h * 0.42,
            cx - w * (isFemale ? 0.27 : 0.20), h * 0.56)
        ..quadraticBezierTo(cx - w * (isFemale ? 0.22 : 0.17), h * 0.58,
            cx - w * (isFemale ? 0.20 : 0.15), h * 0.52)
        ..quadraticBezierTo(cx - w * 0.15, h * 0.40, cx - w * 0.09, h * 0.30)
        ..close();
      canvas.drawPath(leftSleeve, isFemale ? sleevePaint : sleevePaint);
      canvas.drawCircle(Offset(cx - w * (isFemale ? 0.235 : 0.185), h * 0.55),
          w * 0.026, Paint()..color = skin);
    }

    // 右臂（画面右）：天道持剑、逍遥托轮、金刚握拳。
    if (profession == '天道') {
      final rightSleeve = Path()
        ..moveTo(cx + w * 0.14, h * 0.28)
        ..quadraticBezierTo(cx + w * 0.25, h * 0.40, cx + w * 0.22, h * 0.52)
        ..quadraticBezierTo(cx + w * 0.18, h * 0.54, cx + w * 0.16, h * 0.48)
        ..quadraticBezierTo(cx + w * 0.16, h * 0.38, cx + w * 0.09, h * 0.30)
        ..close();
      canvas.drawPath(rightSleeve, isFemale ? sleeveShade : sleevePaint);
      // 持剑的手。
      canvas.drawCircle(Offset(cx + w * 0.21, h * 0.525), w * 0.028,
          Paint()..color = skin);
    } else if (profession == '逍遥') {
      // 右臂横托：袖向外张开，掌心向上托飞轮。
      final rightSleeve = Path()
        ..moveTo(cx + w * 0.14, h * 0.28)
        ..quadraticBezierTo(cx + w * 0.28, h * 0.38, cx + w * 0.27, h * 0.47)
        ..quadraticBezierTo(cx + w * 0.22, h * 0.50, cx + w * 0.18, h * 0.44)
        ..quadraticBezierTo(cx + w * 0.16, h * 0.36, cx + w * 0.09, h * 0.30)
        ..close();
      canvas.drawPath(rightSleeve, isFemale ? sleevePaint : sleevePaint);
      canvas.drawCircle(Offset(cx + w * 0.255, h * 0.46), w * 0.027,
          Paint()..color = skin);
    } else {
      // 金刚：右臂下垂，拳头紧握在腰侧。
      final rightSleeve = Path()
        ..moveTo(cx + w * 0.14, h * 0.28)
        ..quadraticBezierTo(cx + w * 0.24, h * 0.42, cx + w * 0.21, h * 0.57)
        ..quadraticBezierTo(cx + w * 0.17, h * 0.59, cx + w * 0.15, h * 0.52)
        ..quadraticBezierTo(cx + w * 0.15, h * 0.40, cx + w * 0.09, h * 0.30)
        ..close();
      canvas.drawPath(rightSleeve, isFemale ? sleeveShade : sleevePaint);
      canvas.drawCircle(Offset(cx + w * 0.195, h * 0.565), w * 0.028,
          Paint()..color = skin);
      // 金刚左手也是拳。
      canvas.drawCircle(Offset(cx - w * (isFemale ? 0.235 : 0.185), h * 0.55),
          w * 0.028, Paint()..color = skin);
    }
  }

  /// 女版飘带：两条从腰间飘出的长带（左紫金、右青白），带尖收细，
  /// 随呼吸轻摆（按 progress 的正弦摆一点）。
  void _drawRibbons(Canvas canvas, double w, double h) {
    final cx = w / 2;
    final sway = math.sin(progress * math.pi * 2) * w * 0.012;
    // 左：紫金飘带。
    final leftRibbon = Path()
      ..moveTo(cx - w * 0.10, h * 0.50)
      ..quadraticBezierTo(cx - w * 0.26, h * 0.52 + sway, cx - w * 0.38,
          h * 0.60 + sway)
      ..quadraticBezierTo(cx - w * 0.30, h * 0.62 + sway, cx - w * 0.20,
          h * 0.58)
      ..quadraticBezierTo(cx - w * 0.13, h * 0.54, cx - w * 0.10, h * 0.53)
      ..close();
    canvas.drawPath(
        leftRibbon, Paint()..color = const Color(0xFF9B6BD8).withValues(alpha: 0.85));
    canvas.drawPath(
      Path()
        ..moveTo(cx - w * 0.10, h * 0.50)
        ..quadraticBezierTo(cx - w * 0.26, h * 0.52 + sway, cx - w * 0.38,
            h * 0.60 + sway),
      Paint()
        ..color = const Color(0xFFD4AF37)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(1, w * 0.006),
    );
    // 右：青白飘带。
    final rightRibbon = Path()
      ..moveTo(cx + w * 0.10, h * 0.50)
      ..quadraticBezierTo(cx + w * 0.26, h * 0.54 - sway, cx + w * 0.36,
          h * 0.63 - sway)
      ..quadraticBezierTo(cx + w * 0.28, h * 0.65 - sway, cx + w * 0.19,
          h * 0.59)
      ..quadraticBezierTo(cx + w * 0.13, h * 0.55, cx + w * 0.10, h * 0.53)
      ..close();
    canvas.drawPath(
        rightRibbon, Paint()..color = const Color(0xFFBFE8E0).withValues(alpha: 0.85));
    // 腰间金花饰（紫灵腰间金花 + 绿宝石）。
    _drawSmallFlower(canvas, Offset(cx, h * 0.49), w * 0.022);
    canvas.drawCircle(Offset(cx - w * 0.03, h * 0.515), w * 0.007,
        Paint()..color = const Color(0xFF2FBF71));
    canvas.drawCircle(Offset(cx + w * 0.03, h * 0.515), w * 0.007,
        Paint()..color = const Color(0xFF2FBF71));
  }

  /// 袍面纹样：按服饰的纹样在胸前画一个小标记。
  void _drawPattern(Canvas canvas, double w, double h, Paint trim) {
    final cx = w / 2;
    final patternPaint = Paint()
      ..color = trim.color.withValues(alpha: 0.85)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1, w * 0.008)
      ..strokeCap = StrokeCap.round;
    final py = isFemale ? h * 0.60 : h * 0.40;
    switch (costume.pattern) {
      case CultivationCostumePattern.cloud:
        canvas.drawArc(
          Rect.fromCircle(center: Offset(cx, py), radius: w * 0.03),
          math.pi * 0.1,
          math.pi * 1.2,
          false,
          patternPaint,
        );
        canvas.drawArc(
          Rect.fromCircle(center: Offset(cx + w * 0.035, py + h * 0.025),
              radius: w * 0.018),
          math.pi * 1.1,
          math.pi * 0.9,
          false,
          patternPaint,
        );
      case CultivationCostumePattern.plum:
        for (var i = 0; i < 5; i++) {
          final angle = i * math.pi * 2 / 5 - math.pi / 2;
          canvas.drawCircle(
            Offset(cx + math.cos(angle) * w * 0.022,
                py + math.sin(angle) * w * 0.022),
            w * 0.009,
            Paint()..color = trim.color.withValues(alpha: 0.85),
          );
        }
      case CultivationCostumePattern.crane:
        canvas.drawArc(
          Rect.fromCircle(center: Offset(cx, py), radius: w * 0.035),
          math.pi * 1.15,
          math.pi * 0.7,
          false,
          patternPaint,
        );
        canvas.drawCircle(
          Offset(cx + w * 0.032, py - h * 0.02),
          w * 0.008,
          Paint()..color = trim.color.withValues(alpha: 0.85),
        );
      case CultivationCostumePattern.flame:
        final flamePath = Path()
          ..moveTo(cx, py - h * 0.035)
          ..quadraticBezierTo(cx + w * 0.028, py, cx + w * 0.012, py + h * 0.03)
          ..quadraticBezierTo(cx + w * 0.02, py + h * 0.015, cx, py + h * 0.025)
          ..quadraticBezierTo(cx - w * 0.02, py + h * 0.015, cx - w * 0.012,
              py + h * 0.03)
          ..quadraticBezierTo(cx - w * 0.028, py, cx, py - h * 0.035)
          ..close();
        canvas.drawPath(
            flamePath, Paint()..color = trim.color.withValues(alpha: 0.85));
      case CultivationCostumePattern.wave:
        for (var row = 0; row < 2; row++) {
          final y = py + row * h * 0.03;
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

  /// 小白花（五瓣）：女版发间与腰间花结用。
  void _drawSmallFlower(Canvas canvas, Offset center, double r) {
    final petal = Paint()..color = const Color(0xFFFFFFFF);
    final heart = Paint()..color = const Color(0xFFFFE9A8);
    for (var i = 0; i < 5; i++) {
      final a = i * math.pi * 2 / 5 - math.pi / 2;
      canvas.drawCircle(
        Offset(center.dx + math.cos(a) * r * 0.62,
            center.dy + math.sin(a) * r * 0.62),
        r * 0.55,
        petal,
      );
    }
    canvas.drawCircle(center, r * 0.38, heart);
  }

  /// 紫灵小金冠：三尖金冠 + 当中一颗宝石。
  void _drawCrown(Canvas canvas, Offset center, double r, Color gold) {
    final crownPath = Path()
      ..moveTo(center.dx - r, center.dy + r * 0.4)
      ..lineTo(center.dx - r * 0.5, center.dy - r * 0.7)
      ..lineTo(center.dx - r * 0.15, center.dy + r * 0.1)
      ..lineTo(center.dx, center.dy - r * 1.0)
      ..lineTo(center.dx + r * 0.15, center.dy + r * 0.1)
      ..lineTo(center.dx + r * 0.5, center.dy - r * 0.7)
      ..lineTo(center.dx + r, center.dy + r * 0.4)
      ..close();
    canvas.drawPath(crownPath, Paint()..color = gold);
    canvas.drawCircle(
        Offset(center.dx, center.dy - r * 0.1), r * 0.18,
        Paint()..color = const Color(0xFF9B6BD8));
  }

  /// 青花（南宫婉发髻上的青色小花）：五瓣青色 + 白心。
  void _drawSmallFlowerTeal(Canvas canvas, Offset center, double r) {
    final petal = Paint()..color = const Color(0xFF7FD0C8);
    for (var i = 0; i < 5; i++) {
      final a = i * math.pi * 2 / 5 - math.pi / 2;
      canvas.drawCircle(
        Offset(center.dx + math.cos(a) * r * 0.62,
            center.dy + math.sin(a) * r * 0.62),
        r * 0.55,
        petal,
      );
    }
    canvas.drawCircle(center, r * 0.38,
        Paint()..color = const Color(0xFFFFFFFF));
  }

  void _drawHead(Canvas canvas, double w, double h, Paint skin,
      Paint skinShade, Paint hairPaint, Color gold, Paint trim) {
    final cx = w / 2;
    // 脸型：瓜子脸偏长带尖下巴、方脸偏方、圆脸偏圆；女版脸略小略尖。
    final (double rx, double ry) = switch (face) {
      '方脸' => (w * 0.088, h * 0.078),
      '圆脸' => (w * 0.092, h * 0.080),
      _ => (w * 0.082, h * 0.086),
    };
    final headCenter = Offset(cx, h * 0.155);
    // 面部阴影：右侧淡淡的阴影面（2.5D 明暗）。
    canvas.drawOval(
      Rect.fromCenter(center: headCenter, width: rx * 2, height: ry * 2),
      skin,
    );
    canvas.drawOval(
      Rect.fromCenter(
          center: Offset(cx + rx * 0.45, h * 0.16),
          width: rx * 0.9,
          height: ry * 1.7),
      Paint()..color = const Color(0xFFF0C49A).withValues(alpha: 0.35),
    );
    canvas.drawOval(
      Rect.fromCenter(center: headCenter, width: rx * 1.7, height: ry * 1.7),
      skin,
    );
    if (face == '瓜子脸') {
      final chinPath = Path()
        ..moveTo(cx - rx * 0.45, h * 0.155 + ry * 0.55)
        ..quadraticBezierTo(
            cx, h * 0.155 + ry * 1.25, cx + rx * 0.45, h * 0.155 + ry * 0.55)
        ..close();
      canvas.drawPath(chinPath, skin);
    }

    _drawHair(canvas, w, h, hairPaint, rx, ry, gold);

    // 眉毛：男版韩立剑眉（直、眉头低眉尾高挑、冷峻），女版细弯眉。
    final browPaint = Paint()
      ..color = hairColor.color
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(1.2, w * (isFemale ? 0.007 : 0.009))
      ..strokeCap = StrokeCap.round;
    for (final side in [-1.0, 1.0]) {
      if (isFemale) {
        canvas.drawPath(
          Path()
            ..moveTo(cx + side * w * 0.028, h * 0.125)
            ..quadraticBezierTo(cx + side * w * 0.048, h * 0.112,
                cx + side * w * 0.068, h * 0.126),
          browPaint,
        );
      } else {
        canvas.drawLine(
          Offset(cx + side * w * 0.026, h * 0.130),
          Offset(cx + side * w * 0.070, h * 0.117),
          browPaint,
        );
      }
    }
    // 眼睛：眼白 + 虹膜 + 瞳孔 + 高光 + 上眼线，女版眼睛更大、睫毛更长。
    final eyeDy = h * 0.152;
    final eyeRx = w * (isFemale ? 0.021 : 0.018);
    final eyeRy = h * (isFemale ? 0.016 : 0.011);
    final irisR = w * (isFemale ? 0.0135 : 0.0115);
    for (final side in [-1.0, 1.0]) {
      final eyeCenter = Offset(cx + side * w * 0.048, eyeDy);
      canvas.drawOval(
        Rect.fromCenter(
            center: eyeCenter, width: eyeRx * 2, height: eyeRy * 2),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      canvas.drawCircle(
          eyeCenter, irisR, Paint()..color = const Color(0xFF3A2A1A));
      canvas.drawCircle(eyeCenter, irisR * 0.55,
          Paint()..color = const Color(0xFF000000));
      canvas.drawCircle(
          Offset(eyeCenter.dx - irisR * 0.3, eyeCenter.dy - irisR * 0.35),
          irisR * 0.28,
          Paint()..color = const Color(0xFFFFFFFF));
      // 上眼线。
      canvas.drawArc(
        Rect.fromCenter(
            center: eyeCenter, width: eyeRx * 2.1, height: eyeRy * 2.1),
        math.pi * 1.15,
        math.pi * 0.7,
        false,
        Paint()
          ..color = const Color(0xFF2A2018)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.2, w * 0.008)
          ..strokeCap = StrokeCap.round,
      );
      if (isFemale) {
        // 眼尾小睫毛。
        canvas.drawLine(
          Offset(eyeCenter.dx + side * eyeRx, eyeCenter.dy - eyeRy * 0.4),
          Offset(eyeCenter.dx + side * (eyeRx + w * 0.012),
              eyeCenter.dy - eyeRy * 1.1),
          Paint()
            ..color = const Color(0xFF2A2018)
            ..strokeWidth = math.max(1, w * 0.006)
            ..strokeCap = StrokeCap.round,
        );
      }
      // 腮红（女版才有，男版韩立冷峻不画腮红）。
      if (isFemale) {
        canvas.drawCircle(
          Offset(cx + side * w * 0.068, h * 0.185),
          w * 0.011,
          Paint()..color = const Color(0xFFF6B8C8).withValues(alpha: 0.65),
        );
      }
    }
    // 鼻子：小小一笔。
    canvas.drawLine(
      Offset(cx + w * 0.004, h * 0.165),
      Offset(cx + w * 0.002, h * 0.185),
      Paint()
        ..color = const Color(0xFFD8A87E)
        ..strokeWidth = math.max(1, w * 0.006)
        ..strokeCap = StrokeCap.round,
    );
    // 嘴：男版韩立冷峻一字唇，女版樱桃小口 + 紫灵半透明面纱遮下半脸。
    if (isFemale) {
      final lipPath = Path()
        ..moveTo(cx - w * 0.016, h * 0.205)
        ..quadraticBezierTo(cx, h * 0.212, cx + w * 0.016, h * 0.205)
        ..quadraticBezierTo(cx, h * 0.218, cx - w * 0.016, h * 0.205)
        ..close();
      canvas.drawPath(
          lipPath, Paint()..color = const Color(0xFFD96A7A));
      // 面纱：淡紫白轻纱遮住口鼻下半脸（半透明，嘴唇若隐若现）。
      final veilPath = Path()
        ..moveTo(cx - rx * 0.85, h * 0.178)
        ..quadraticBezierTo(cx, h * 0.195, cx + rx * 0.85, h * 0.178)
        ..quadraticBezierTo(cx + rx * 0.7, h * 0.235, cx, h * 0.245)
        ..quadraticBezierTo(cx - rx * 0.7, h * 0.235, cx - rx * 0.85, h * 0.178)
        ..close();
      canvas.drawPath(
          veilPath,
          Paint()
            ..color = const Color(0xFFE8E0F5).withValues(alpha: 0.32));
      canvas.drawPath(
        Path()
          ..moveTo(cx - rx * 0.85, h * 0.178)
          ..quadraticBezierTo(cx, h * 0.195, cx + rx * 0.85, h * 0.178),
        Paint()
          ..color = const Color(0xFFD4AF37).withValues(alpha: 0.7)
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1, w * 0.005),
      );
    } else {
      canvas.drawLine(
        Offset(cx - w * 0.014, h * 0.205),
        Offset(cx + w * 0.014, h * 0.205),
        Paint()
          ..color = const Color(0xFF9A5A4A)
          ..strokeWidth = math.max(1.2, w * 0.008)
          ..strokeCap = StrokeCap.round,
      );
    }
    // 耳环：女版金色小耳坠。
    if (isFemale) {
      for (final side in [-1.0, 1.0]) {
        canvas.drawCircle(Offset(cx + side * rx * 1.02, h * 0.175),
            w * 0.006, Paint()..color = gold);
      }
    }
  }

  /// 发型：道髻（男单髻/女双髻 + 长发飘）、披发（两侧垂发到腰）、
  /// 高马尾（顶髻 + 向一侧甩的马尾）。女版发间固定一朵白花。
  void _drawHair(Canvas canvas, double w, double h, Paint hairPaint,
      double rx, double ry, Color gold) {
    final cx = w / 2;
    final headTop = h * 0.155 - ry;
    // 发盖：盖住头顶的头发。
    final hairPath = Path()
      ..moveTo(cx - rx * 0.98, h * 0.155)
      ..quadraticBezierTo(cx - rx * 0.9, headTop - h * 0.015, cx,
          headTop - h * 0.02)
      ..quadraticBezierTo(cx + rx * 0.9, headTop - h * 0.015, cx + rx * 0.98,
          h * 0.155)
      ..quadraticBezierTo(cx + rx * 0.55, h * 0.115, cx, h * 0.122)
      ..quadraticBezierTo(cx - rx * 0.55, h * 0.115, cx - rx * 0.98, h * 0.155)
      ..close();
    canvas.drawPath(hairPath, hairPaint);
    // 刘海碎发：额前两缕。
    for (final side in [-1.0, 1.0]) {
      final bangPath = Path()
        ..moveTo(cx + side * w * 0.02, h * 0.115)
        ..quadraticBezierTo(cx + side * w * 0.05, h * 0.14,
            cx + side * w * 0.035, h * 0.155)
        ..quadraticBezierTo(cx + side * w * 0.02, h * 0.14,
            cx + side * w * 0.02, h * 0.115)
        ..close();
      canvas.drawPath(bangPath, hairPaint);
    }

    final tie = Paint()..color = costume.trim;
    switch (hairstyle) {
      case '披发':
        for (final side in [-1.0, 1.0]) {
          final fallPath = Path()
            ..moveTo(cx + side * rx * 0.85, h * 0.13)
            ..quadraticBezierTo(cx + side * rx * 1.3, h * 0.25,
                cx + side * rx * 1.1, h * 0.48)
            ..quadraticBezierTo(cx + side * rx * 0.9, h * 0.46,
                cx + side * rx * 0.75, h * 0.28)
            ..close();
          canvas.drawPath(fallPath, hairPaint);
        }
      case '高马尾':
        canvas.drawCircle(
            Offset(cx, headTop - h * 0.012), w * 0.028, hairPaint);
        // 马尾向左侧飘甩。
        final tailPath = Path()
          ..moveTo(cx - w * 0.01, headTop - h * 0.008)
          ..quadraticBezierTo(cx - w * 0.20, h * 0.08, cx - w * 0.26, h * 0.26)
          ..quadraticBezierTo(cx - w * 0.22, h * 0.28, cx - w * 0.17, h * 0.16)
          ..quadraticBezierTo(cx - w * 0.10, h * 0.06, cx - w * 0.01,
              headTop - h * 0.008)
          ..close();
        canvas.drawPath(tailPath, hairPaint);
        canvas.drawRRect(
          RRect.fromLTRBR(cx - w * 0.024, headTop - h * 0.002,
              cx + w * 0.024, headTop + h * 0.012, Radius.circular(h * 0.006)),
          tie,
        );
      default:
        // 道髻：男单髻，女双髻（左右各一个小发髻 + 发带）。
        if (isFemale) {
          for (final side in [-1.0, 1.0]) {
            canvas.drawCircle(
                Offset(cx + side * w * 0.10, h * 0.085), w * 0.026, hairPaint);
            canvas.drawRRect(
              RRect.fromLTRBR(cx + side * w * 0.10 - w * 0.022, h * 0.105,
                  cx + side * w * 0.10 + w * 0.022, h * 0.12,
                  Radius.circular(h * 0.006)),
              tie,
            );
          }
          // 女版双髻间一朵白花 + 紫灵小金冠。
          _drawSmallFlower(canvas, Offset(cx + w * 0.075, h * 0.075), w * 0.020);
          _drawCrown(canvas, Offset(cx, headTop - h * 0.035), w * 0.030, gold);
        } else {
          canvas.drawCircle(
              Offset(cx, headTop - h * 0.015), w * 0.030, hairPaint);
          canvas.drawRRect(
            RRect.fromLTRBR(cx - w * 0.026, headTop - h * 0.002,
                cx + w * 0.026, headTop + h * 0.015, Radius.circular(h * 0.006)),
            tie,
          );
          // 男版道髻金簪。
          canvas.drawLine(
            Offset(cx - w * 0.04, headTop - h * 0.015),
            Offset(cx + w * 0.04, headTop - h * 0.015),
            Paint()
              ..color = gold
              ..strokeWidth = math.max(1.5, w * 0.008)
              ..strokeCap = StrokeCap.round,
          );
        }
    }
    // 女版：披发/高马尾时发间一朵白花 + 一朵青花（南宫婉花饰发髻）。
    if (isFemale && hairstyle != '道髻') {
      _drawSmallFlower(canvas, Offset(cx + w * 0.085, h * 0.095), w * 0.020);
      _drawSmallFlowerTeal(canvas, Offset(cx - w * 0.085, h * 0.105), w * 0.016);
      _drawCrown(canvas, Offset(cx, headTop - h * 0.035), w * 0.024, gold);
    }
  }

  // ---------- 平时看得见的武器 ----------

  void _drawIdleWeapon(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    switch (profession) {
      case '天道':
        _drawSwordInHand(canvas, w, h, floatY);
      case '逍遥':
        // 一只飞轮托在右手掌心，一只浮在左肩侧缓慢旋转。
        _drawWheel(
            canvas, Offset(cx + w * 0.255, h * 0.44 + floatY * 0.5),
            w * 0.075, progress * math.pi * 2, 1.0);
        _drawWheel(
            canvas, Offset(cx - w * 0.30, h * 0.38 + floatY * 0.5),
            w * 0.065, -progress * math.pi * 2, 0.9);
      case '金刚':
        // 身周一圈淡淡的金罩（平时也看得见）。
        final cy = h * 0.50 + floatY * 0.5;
        final shieldR = w * 0.38;
        canvas.drawCircle(
          Offset(cx, cy),
          shieldR,
          Paint()
            ..color = const Color(0xFFD4AF37).withValues(alpha: 0.10)
            ..style = PaintingStyle.fill,
        );
        canvas.drawCircle(
          Offset(cx, cy),
          shieldR,
          Paint()
            ..color = const Color(0xFFD4AF37).withValues(alpha: 0.30)
            ..style = PaintingStyle.stroke
            ..strokeWidth = math.max(1.5, w * 0.010),
        );
        // 双拳金光。
        for (final fx in [0.195, -0.20]) {
          canvas.drawCircle(
            Offset(cx + w * fx, h * 0.56 + floatY * 0.5),
            w * 0.035,
            Paint()
              ..color = const Color(0xFFFFE9A8).withValues(alpha: 0.35)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
          );
        }
    }
  }

  /// 天道平时持剑：右手握剑，剑身斜指右下地面，剑光微亮。
  void _drawSwordInHand(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final hand = Offset(cx + w * 0.21, h * 0.525 + floatY * 0.5);
    // 御剑势：剑斜指右上前方（施展技能的动态持剑姿势，不是垂剑站立）。
    final angle = -math.pi * 0.32;
    canvas.save();
    canvas.translate(hand.dx, hand.dy);
    canvas.rotate(angle);
    // 剑身：长菱形，银白带金边。
    final bladeLen = h * 0.28;
    final blade = Path()
      ..moveTo(bladeLen, 0)
      ..lineTo(bladeLen * 0.92, -w * 0.010)
      ..lineTo(w * 0.02, -w * 0.007)
      ..lineTo(-w * 0.01, 0)
      ..lineTo(w * 0.02, w * 0.007)
      ..lineTo(bladeLen * 0.92, w * 0.010)
      ..close();
    canvas.drawPath(
        blade,
        Paint()
          ..shader = LinearGradient(
            colors: [
              const Color(0xFFD8FFE8),
              const Color(0xFF2FBF71),
              const Color(0xFFD4AF37),
            ],
          ).createShader(Rect.fromLTRB(0, -w * 0.01, bladeLen, w * 0.01)));
    // 剑格（金）+ 剑柄（深色）+ 剑首。
    canvas.drawRRect(
      RRect.fromLTRBR(-w * 0.008, -w * 0.022, w * 0.012, w * 0.022,
          Radius.circular(w * 0.006)),
      Paint()..color = const Color(0xFFD4AF37),
    );
    canvas.drawRRect(
      RRect.fromLTRBR(-w * 0.055, -w * 0.008, -w * 0.008, w * 0.008,
          Radius.circular(w * 0.006)),
      Paint()..color = const Color(0xFF3A2A1A),
    );
    canvas.drawCircle(Offset(-w * 0.058, 0), w * 0.010,
        Paint()..color = const Color(0xFFD4AF37));
    canvas.restore();
    // 剑尖一点寒光。
    canvas.drawCircle(
      Offset(hand.dx + math.cos(angle) * h * 0.28,
          hand.dy + math.sin(angle) * h * 0.28),
      w * 0.012,
      Paint()
        ..color = const Color(0xFFFFFFFF).withValues(alpha: 0.8)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  /// 一只飞轮：带齿圆环 + 辐条 + 中心宝石。
  void _drawWheel(
      Canvas canvas, Offset center, double r, double spin, double alpha) {
    final rim = Paint()
      ..color = const Color(0xFF8A7BD8).withValues(alpha: alpha * 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(2, r * 0.22);
    canvas.drawCircle(center, r, rim);
    for (var s = 0; s < 4; s++) {
      final a = spin + s * math.pi / 2;
      canvas.drawLine(
        Offset(center.dx - math.cos(a) * r, center.dy - math.sin(a) * r),
        Offset(center.dx + math.cos(a) * r, center.dy + math.sin(a) * r),
        Paint()
          ..color = const Color(0xFFB9A8F0).withValues(alpha: alpha * 0.8)
          ..strokeWidth = math.max(1, r * 0.10),
      );
    }
    canvas.drawCircle(center, r * 0.28,
        Paint()..color = const Color(0xFFD8C8FF).withValues(alpha: alpha));
  }

  // ---------- 技能 ----------

  /// 天道·万剑归宗：7 把飞剑从身后升起、绕身成剑圈，再向前收束斩出。
  void _drawSwords(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.50 + floatY * 0.5;
    final p = skillProgress;
    final appear = (p / 0.15).clamp(0.0, 1.0);
    final fade = p > 0.85 ? ((1 - p) / 0.15).clamp(0.0, 1.0) : 1.0;
    final alpha = appear * fade;
    if (alpha <= 0) return;
    final converge = Offset(cx + w * 0.30, h * 0.38 + floatY * 0.5);
    final gather = ((p - 0.7) / 0.3).clamp(0.0, 1.0);
    // 大庚剑阵：0.55→0.85 飞剑收成环形剑阵（定点成阵、剑光连线）。
    final arrayT = ((p - 0.55) / 0.3).clamp(0.0, 1.0) * (1 - gather);
    // 青竹蜂云剑：绿剑身 + 淡绿剑光（韩立青元剑诀）。
    const gold = Color(0xFF2FBF71);
    const goldLight = Color(0xFFB8F5D0);
    final swordPositions = <Offset>[];
    for (var i = 0; i < _swordCount; i++) {
      final angle = (i / _swordCount) * math.pi * 2 + p * math.pi * 2.5;
      final orbitR = w * 0.32;
      final orbit = Offset(
        cx + math.cos(angle) * orbitR,
        cy + math.sin(angle) * orbitR * 0.8,
      );
      final rise = (p / 0.4).clamp(0.0, 1.0);
      final risen = Offset(orbit.dx, orbit.dy + (1 - rise) * h * 0.25);
      // 剑阵定点：环形均匀排布。
      final fixedAngle = (i / _swordCount) * math.pi * 2 - math.pi / 2;
      final arrayPos = Offset(
        cx + math.cos(fixedAngle) * orbitR,
        cy + math.sin(fixedAngle) * orbitR * 0.8,
      );
      final orbitPos = Offset(
        risen.dx + (arrayPos.dx - risen.dx) * arrayT,
        risen.dy + (arrayPos.dy - risen.dy) * arrayT,
      );
      final pos = Offset(
        orbitPos.dx + (converge.dx - orbitPos.dx) * gather,
        orbitPos.dy + (converge.dy - orbitPos.dy) * gather,
      );
      swordPositions.add(pos);
      final swordAngle = gather > 0
          ? math.atan2(converge.dy - pos.dy, converge.dx - pos.dx)
          : angle + math.pi / 2;
      canvas.save();
      canvas.translate(pos.dx, pos.dy);
      canvas.rotate(swordAngle);
      canvas.drawLine(
        Offset(-w * 0.09, 0),
        Offset(-w * 0.02, 0),
        Paint()
          ..color = goldLight.withValues(alpha: alpha * 0.7)
          ..strokeWidth = math.max(1.5, w * 0.012)
          ..strokeCap = StrokeCap.round,
      );
      final blade = Path()
        ..moveTo(w * 0.055, 0)
        ..lineTo(w * 0.015, -w * 0.008)
        ..lineTo(-w * 0.045, 0)
        ..lineTo(w * 0.015, w * 0.008)
        ..close();
      canvas.drawPath(blade, Paint()..color = gold.withValues(alpha: alpha));
      canvas.drawCircle(Offset(-w * 0.05, 0), w * 0.008,
          Paint()..color = goldLight.withValues(alpha: alpha));
      canvas.restore();
    }
    // 大庚剑阵剑光连线：相邻飞剑连线 + 连向阵心，绿光成阵。
    if (arrayT > 0.05) {
      final linePaint = Paint()
        ..color = const Color(0xFF7DF0B0).withValues(alpha: alpha * 0.7 * arrayT)
        ..strokeWidth = math.max(1.2, w * 0.007)
        ..strokeCap = StrokeCap.round;
      for (var i = 0; i < _swordCount; i++) {
        canvas.drawLine(swordPositions[i],
            swordPositions[(i + 1) % _swordCount], linePaint);
        canvas.drawLine(swordPositions[i], Offset(cx, cy), linePaint);
      }
      canvas.drawCircle(
        Offset(cx, cy),
        w * 0.05 * arrayT,
        Paint()
          ..color = const Color(0xFF7DF0B0).withValues(alpha: alpha * 0.5 * arrayT)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
      );
    }
    // 施法掌前绿光团（青元剑诀施法时掌心发光）。
    canvas.drawCircle(
      Offset(cx - w * 0.22, h * 0.425 + floatY * 0.5),
      w * 0.045 * appear,
      Paint()
        ..color = const Color(0xFF7DF0B0).withValues(alpha: alpha * 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    if (gather > 0) {
      final flashR = w * 0.10 * gather;
      canvas.drawCircle(
        converge,
        flashR,
        Paint()
          ..shader = RadialGradient(
            colors: [
              goldLight.withValues(alpha: alpha * 0.8),
              gold.withValues(alpha: alpha * 0.25),
              gold.withValues(alpha: 0),
            ],
          ).createShader(Rect.fromCircle(center: converge, radius: flashR)),
      );
    }
  }

  /// 逍遥·真魔功：两只飞轮绕身高速旋转 + 暗色魔气。
  void _drawWheels(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.50 + floatY;
    final p = skillProgress;
    final alpha = ((p / 0.15).clamp(0.0, 1.0) *
            (p > 0.85 ? ((1 - p) / 0.15).clamp(0.0, 1.0) : 1.0))
        .clamp(0.0, 1.0);
    if (alpha <= 0) return;
    for (var i = 0; i < 4; i++) {
      final angle = i * math.pi / 2 + p * math.pi * 3;
      canvas.drawCircle(
        Offset(cx + math.cos(angle) * w * 0.28,
            cy + math.sin(angle) * h * 0.16),
        w * 0.06,
        Paint()
          ..color = const Color(0xFF5B4A8C).withValues(alpha: alpha * 0.25)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
      );
    }
    for (var k = 0; k < 2; k++) {
      final orbitAngle = p * math.pi * 6 + k * math.pi;
      _drawWheel(
        canvas,
        Offset(cx + math.cos(orbitAngle) * w * 0.26,
            cy + math.sin(orbitAngle) * h * 0.13),
        w * 0.085,
        p * math.pi * 10 + k * math.pi / 2,
        alpha,
      );
    }
  }

  /// 逍遥残影：两个半透明分身在人物两侧左右闪烁瞬移。
  void _drawAfterimages(
      Canvas canvas, double w, double h, double floatY, double scale) {
    final cx = w / 2;
    final p = skillProgress;
    final flicker = (math.sin(p * math.pi * 6) * 0.5 + 0.5);
    for (var k = 0; k < 2; k++) {
      final side = k == 0 ? -1.0 : 1.0;
      final offset = side * w * 0.09 * (0.6 + 0.4 * flicker);
      final opacity = 0.28 * math.sin(p * math.pi).clamp(0.0, 1.0);
      if (opacity <= 0.01) continue;
      canvas.save();
      canvas.translate(cx + offset, h * 0.50 + floatY);
      canvas.scale(scale);
      canvas.translate(-cx, -h * 0.50);
      canvas.saveLayer(
        null,
        Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: opacity),
      );
      _drawFigure(canvas, w, h);
      canvas.restore();
      canvas.restore();
    }
  }

  /// 金刚·泰阳诀：周身张开金色护罩，罩面有流光弧与反伤波纹。
  void _drawShield(Canvas canvas, double w, double h, double floatY) {
    final cx = w / 2;
    final cy = h * 0.50 + floatY;
    final p = skillProgress;
    final alpha = ((p / 0.2).clamp(0.0, 1.0) *
            (p > 0.8 ? ((1 - p) / 0.2).clamp(0.0, 1.0) : 1.0))
        .clamp(0.0, 1.0);
    if (alpha <= 0) return;
    final shieldR = w * 0.40;
    const gold = Color(0xFFD4AF37);
    const goldLight = Color(0xFFFFE9A8);
    canvas.drawCircle(
        Offset(cx, cy), shieldR, Paint()..color = gold.withValues(alpha: alpha * 0.12));
    canvas.drawCircle(
      Offset(cx, cy),
      shieldR,
      Paint()
        ..color = gold.withValues(alpha: alpha * 0.9)
        ..style = PaintingStyle.stroke
        ..strokeWidth = math.max(2, w * 0.018),
    );
    for (var k = 0; k < 2; k++) {
      final start = p * math.pi * 4 + k * math.pi;
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: shieldR),
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
    for (var k = 0; k < 2; k++) {
      final ripple = ((p * 1.4 + k * 0.5) % 1.0);
      canvas.drawCircle(
        Offset(cx, cy),
        shieldR * (1 + ripple * 0.35),
        Paint()
          ..color = gold.withValues(alpha: alpha * 0.5 * (1 - ripple))
          ..style = PaintingStyle.stroke
          ..strokeWidth = math.max(1.5, w * 0.012),
      );
    }
  }

  void _drawDots(Canvas canvas, double w, double h) {
    for (var i = 0; i < _dotSlots.length; i++) {
      final phase = (progress + i / _dotSlots.length) % 1.0;
      final y = h * (0.92 - 0.62 * phase);
      final x =
          w * _dotSlots[i] + math.sin((phase + i) * math.pi * 2) * w * 0.015;
      final alpha = phase < 0.15 ? phase / 0.15 : 1 - (phase - 0.15) / 0.85;
      final color = i.isEven
          ? const Color(0xFFD8C8FF)
          : const Color(0xFFBFE3FF);
      canvas.drawCircle(
        Offset(x, y),
        _dotRadii[i] * (w / 300),
        Paint()..color = color.withValues(alpha: alpha.clamp(0, 1) * 0.9),
      );
    }
  }

  @override
  bool shouldRepaint(_StandingCharacterPainter old) =>
      old.progress != progress ||
      old.skillProgress != skillProgress ||
      old.profession != profession ||
      old.costume != costume ||
      old.face != face ||
      old.hairstyle != hairstyle ||
      old.hairColor != hairColor ||
      old.isFemale != isFemale;
}
