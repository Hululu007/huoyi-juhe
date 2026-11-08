import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/cultivation.dart';
import '../services/cultivation_bgm.dart';
import '../widgets/game_hero_portrait.dart';

/// 首次安装全屏创建人物界面：按凡人修仙传网页游戏（2010）选职业界面
/// charsel_1 定版——仙山飘渺背景 + 粒子特效，中央是站立大人物
/// （站在圆形发光台上、身后大圆环传送门，平时站立呼吸、隔几秒放
/// 本职业招牌技能、点一下也能放），顶部三张职业卡可切换选择
/// （天道/逍遥/金刚，点一张中央人物就换成该职业、介绍跟着换）；
/// charsel_3（网页游戏创建角色标准版式）作辅助参考：名字输入框
/// 带筛盅随机按钮、男女切换、右下角进入游戏大按钮。
///
/// 女性版按凡人修真 2 宣传图女修气质画：长发飘飘、发间一朵白花、
/// 金色露肩长裙 + 轻纱飘袖 + 金首饰，仙气飘飘、衣袂飘飘。
///
/// 硬门槛：不创建人物就进不了软件——没有跳过/关闭/“稍后再说”，
/// 返回键也不能绕进主界面（PopScope 禁返回）；只有点「开始修仙」
/// 确认（全部字段落盘）后才通过 [onCreated] 进主界面。
/// 只做成年体型：男对应帅哥男体型、女对应靓妹女体型；
/// 小萝莉孩童体型不做。
class CultivationCreatePage extends StatefulWidget {
  const CultivationCreatePage({super.key, required this.onCreated});

  /// 全部字段落盘后回调（主界面切换入口）。
  final VoidCallback onCreated;

  @override
  State<CultivationCreatePage> createState() => _CultivationCreatePageState();
}

class _CultivationCreatePageState extends State<CultivationCreatePage>
    with SingleTickerProviderStateMixin {
  CultivationGender _gender = CultivationGender.male;
  String _sect = cultivationSects.first;
  String _profession = defaultCultivationProfession;
  String _face = defaultCultivationFace;
  String _hairstyle = defaultCultivationHairstyle;
  String _hairColorId = defaultCultivationHairColorId;
  String _costumeId = defaultCultivationCostumeId;

  late String _userId;
  late final TextEditingController _usernameController;
  late final AnimationController _diceController;
  bool _muted = false;
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _userId = generateCultivationUserId();
    _usernameController =
        TextEditingController(text: generateCultivationUsername());
    _diceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _loadMuted();
    // 背景音乐进场自动播（静音偏好落盘；进主界面后停）。
    unawaited(CultivationBgm.instance.playIfEnabled());
  }

  Future<void> _loadMuted() async {
    final muted = await CultivationBgm.instance.isMuted();
    if (mounted) setState(() => _muted = muted);
  }

  @override
  void dispose() {
    _usernameController.dispose();
    _diceController.dispose();
    super.dispose();
  }

  void _refreshIdentity() {
    setState(() {
      _userId = generateCultivationUserId();
      _usernameController.text = generateCultivationUsername();
    });
  }

  /// 筛盅随机：摇骰子动画后随机出一个新用户名（道友+4 位数字）。
  Future<void> _rollUsername() async {
    await _diceController.forward(from: 0);
    if (!mounted) return;
    setState(() {
      _usernameController.text = generateCultivationUsername();
    });
  }

  Future<void> _toggleMute() async {
    final next = !_muted;
    await CultivationBgm.instance.setMuted(next);
    if (mounted) setState(() => _muted = next);
  }

  Future<void> _confirm() async {
    if (_creating) return;
    final username = _usernameController.text.trim();
    if (username.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入用户名')),
      );
      return;
    }
    setState(() => _creating = true);
    await CultivationService.instance.createProfile(
      gender: _gender,
      sect: _sect,
      profession: _profession,
      costumeId: _costumeId,
      face: _face,
      hairstyle: _hairstyle,
      hairColorId: _hairColorId,
      userId: _userId,
      username: username,
    );
    await CultivationBgm.instance.stop();
    if (!mounted) return;
    widget.onCreated();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            const _ImmortalMountainBackground(),
            const _SpiritParticles(),
            SafeArea(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _topBar(),
                    const SizedBox(height: 10),
                    // 顶部职业三卡：带小立绘头像 + 职业名 + 定位，
                    // 点一张切换中央大人物与介绍。
                    _professionCards(),
                    const SizedBox(height: 4),
                    // 中央：站立大人物（发光台 + 身后大圆环），占主要位置。
                    _heroPreview(),
                    const SizedBox(height: 14),
                    // 男女切换（charsel_3 右下角男女切换的竖屏版）。
                    _genderSwitch(),
                    const SizedBox(height: 14),
                    // 名字输入框 + 筛盅随机。
                    _nameField(),
                    const SizedBox(height: 18),
                    _sectionTitle('宗门'),
                    const SizedBox(height: 8),
                    _sectChips(),
                    const SizedBox(height: 18),
                    _sectionTitle('外观定制'),
                    const SizedBox(height: 8),
                    _chipRow(
                      label: '脸型',
                      options: cultivationFaces,
                      selected: _face,
                      onTap: (value) => setState(() => _face = value),
                    ),
                    _chipRow(
                      label: '发型',
                      options: cultivationHairstyles,
                      selected: _hairstyle,
                      onTap: (value) => setState(() => _hairstyle = value),
                    ),
                    _hairColorRow(),
                    _costumeRow(),
                    const SizedBox(height: 14),
                    _idRow(),
                    const SizedBox(height: 20),
                    _startButton(),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return Row(
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '踏入仙途',
                style: TextStyle(
                  color: Color(0xFFF5E6C8),
                  fontSize: 26,
                  fontWeight: FontWeight.bold,
                ),
              ),
              SizedBox(height: 2),
              Text(
                '创建道友档案',
                style: TextStyle(color: Color(0xFFD8C9A3), fontSize: 13),
              ),
            ],
          ),
        ),
        IconButton(
          tooltip: _muted ? '取消静音' : '静音',
          onPressed: _toggleMute,
          icon: Icon(
            _muted ? Icons.volume_off : Icons.volume_up,
            color: const Color(0xFFF5E6C8),
          ),
        ),
      ],
    );
  }

  /// 中央大预览：站立大人物（发光台 + 身后大圆环）+ 头顶称号位 +
  /// 人物下方职业名 + 招牌技能 + 介绍。
  Widget _heroPreview() {
    return Column(
      children: [
        // 头顶称号位：新建人物是炼气初期 Lv.10，暂无称号。
        const Text(
          '炼气初期 · Lv.10',
          style: TextStyle(
            color: Color(0xFFD4AF37),
            fontSize: 15,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        const SizedBox(height: 2),
        GameHeroFullPortrait(
          isFemale: _gender == CultivationGender.female,
          width: 250,
          height: 300,
        ),
        Text(
          _profession,
          style: const TextStyle(
            color: Color(0xFFF5E6C8),
            fontSize: 24,
            fontWeight: FontWeight.bold,
            letterSpacing: 4,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          _displaySkill(_profession),
          style: const TextStyle(
            color: Color(0xFFD4AF37),
            fontSize: 15,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _professionIntro(_profession),
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFFD8C9A3),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '点一下人物放${_displaySkill(_profession)}',
          style: const TextStyle(color: Color(0xFF9FB3C8), fontSize: 12),
        ),
      ],
    );
  }

  Widget _professionCards() {
    return Row(
      children: [
        for (final profession in cultivationProfessions)
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: _ProfessionCard(
                profession: profession,
                selected: _profession == profession,
                onTap: () => setState(() => _profession = profession),
                isFemale: _gender == CultivationGender.female,
                costume: cultivationCostumeById(_costumeId),
                face: _face,
                hairstyle: _hairstyle,
                hairColor: cultivationHairColorById(_hairColorId),
              ),
            ),
          ),
      ],
    );
  }

  /// 男女切换：两个大按钮（男/女），选中金边高亮。
  Widget _genderSwitch() {
    return Row(
      children: [
        for (final entry in [
          ('男', CultivationGender.male),
          ('女', CultivationGender.female),
        ])
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: GestureDetector(
                onTap: () => setState(() => _gender = entry.$2),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
                  decoration: BoxDecoration(
                    color: _gender == entry.$2
                        ? const Color(0xFFD4AF37).withValues(alpha: 0.22)
                        : Colors.black.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _gender == entry.$2
                          ? const Color(0xFFD4AF37)
                          : Colors.white.withValues(alpha: 0.15),
                      width: _gender == entry.$2 ? 2 : 1,
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        entry.$2 == CultivationGender.male
                            ? Icons.male
                            : Icons.female,
                        color: _gender == entry.$2
                            ? const Color(0xFFF5E6C8)
                            : const Color(0xFFD8C9A3),
                        size: 18,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        entry.$1,
                        style: TextStyle(
                          color: _gender == entry.$2
                              ? const Color(0xFFF5E6C8)
                              : const Color(0xFFD8C9A3),
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 名字输入框 + 筛盅随机按钮。
  Widget _nameField() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFD4AF37).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          const Text(
            '用户名：',
            style: TextStyle(color: Color(0xFFD8C9A3), fontSize: 14),
          ),
          Expanded(
            child: TextField(
              controller: _usernameController,
              style: const TextStyle(
                color: Color(0xFFF5E6C8),
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(vertical: 6),
                border: InputBorder.none,
                hintText: '输入想要的名字',
                hintStyle: TextStyle(color: Color(0xFF8A7D5C)),
              ),
            ),
          ),
          // 筛盅随机：点一下摇骰子，随机出一个新用户名。
          RotationTransition(
            turns: Tween<double>(begin: 0, end: 0.12).animate(
              CurvedAnimation(
                parent: _diceController,
                curve: Curves.elasticInOut,
              ),
            ),
            child: IconButton(
              tooltip: '筛盅随机',
              onPressed: _rollUsername,
              icon: const Icon(
                Icons.casino,
                color: Color(0xFFD4AF37),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 道友 ID 行（点刷新换一个）。
  Widget _idRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFD4AF37).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          const Text(
            '道友 ID：',
            style: TextStyle(color: Color(0xFFD8C9A3), fontSize: 14),
          ),
          Expanded(
            child: Text(
              _userId,
              style: const TextStyle(
                color: Color(0xFFF5E6C8),
                fontSize: 15,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            tooltip: '换一个',
            onPressed: _refreshIdentity,
            icon: const Icon(Icons.refresh, color: Color(0xFFD4AF37)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        color: Color(0xFFF5E6C8),
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }

  Widget _chipRow({
    required String label,
    required List<String> options,
    required String selected,
    required ValueChanged<String> onTap,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                label,
                style: const TextStyle(color: Color(0xFFD8C9A3), fontSize: 13),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final option in options)
                  _OptionChip(
                    label: option,
                    selected: selected == option,
                    onTap: () => onTap(option),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _hairColorRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 44,
            child: Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '发色',
                style: TextStyle(color: Color(0xFFD8C9A3), fontSize: 13),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final color in cultivationHairColors)
                  _HairColorChip(
                    color: color,
                    selected: _hairColorId == color.id,
                    onTap: () => setState(() => _hairColorId = color.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _costumeRow() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(
            width: 44,
            child: Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text(
                '服饰',
                style: TextStyle(color: Color(0xFFD8C9A3), fontSize: 13),
              ),
            ),
          ),
          Expanded(
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final costume in cultivationCostumes)
                  _OptionChip(
                    label: costume.name,
                    colorDot: costume.robe,
                    selected: _costumeId == costume.id,
                    onTap: () => setState(() => _costumeId = costume.id),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectChips() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final sect in cultivationSects)
          _OptionChip(
            label: sect,
            selected: _sect == sect,
            onTap: () => setState(() => _sect = sect),
          ),
      ],
    );
  }

  Widget _startButton() {
    return SizedBox(
      height: 52,
      child: ElevatedButton(
        onPressed: _creating ? null : _confirm,
        style: ElevatedButton.styleFrom(
          backgroundColor: const Color(0xFFD4AF37),
          foregroundColor: const Color(0xFF1A1405),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(26),
          ),
        ),
        child: Text(
          _creating ? '正在入道…' : '开始修仙',
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ),
    );
  }
}

/// 创建页展示的招牌技能名：天道按用户新令展示青元剑诀（韩立），
/// 其余沿用系统招牌技能名；系统内的天道招牌技能名（万剑归宗）
/// 在 cultivation.dart 里未动，如需全局改名再定。
String _displaySkill(String profession) {
  return switch (profession) {
    '天道' => '青元剑诀',
    _ => cultivationProfessionSkill(profession),
  };
}

String _professionIntro(String profession) {
  return switch (profession) {
    '天道' => '青元剑诀御剑，青竹蜂云剑绕身，大庚剑阵剑光成阵。',
    '逍遥' => '身法如风，飞轮夺命，遁术无踪。',
    '金刚' => '金身不破，泰阳护体，反伤诸敌。',
    _ => '',
  };
}

/// 职业卡：小立绘头像 + 职业名 + 一句话定位。
class _ProfessionCard extends StatelessWidget {
  const _ProfessionCard({
    required this.profession,
    required this.selected,
    required this.onTap,
    required this.isFemale,
    required this.costume,
    required this.face,
    required this.hairstyle,
    required this.hairColor,
  });

  final String profession;
  final bool selected;
  final VoidCallback onTap;
  final bool isFemale;
  final CultivationCostume costume;
  final String face;
  final String hairstyle;
  final CultivationHairColor hairColor;

  @override
  Widget build(BuildContext context) {
    final role = switch (profession) {
      '天道' => '法术/剑修',
      '逍遥' => '身法/飞轮',
      '金刚' => '防御/反伤',
      _ => '',
    };
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFD4AF37).withValues(alpha: 0.22)
              : Colors.black.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? const Color(0xFFD4AF37)
                : Colors.white.withValues(alpha: 0.15),
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            GameHeroPortrait(
              isFemale: isFemale,
              size: 56,
            ),
            const SizedBox(height: 2),
            Text(
              profession,
              style: TextStyle(
                color: selected
                    ? const Color(0xFFF5E6C8)
                    : const Color(0xFFD8C9A3),
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              role,
              style: const TextStyle(color: Color(0xFF9FB3C8), fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }
}

class _OptionChip extends StatelessWidget {
  const _OptionChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.colorDot,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Color? colorDot;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFD4AF37)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? const Color(0xFFD4AF37)
                : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (colorDot != null) ...[
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: colorDot,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 5),
            ],
            Text(
              label,
              style: TextStyle(
                color: selected
                    ? const Color(0xFF1A1405)
                    : const Color(0xFFF5E6C8),
                fontSize: 13,
                fontWeight: selected ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HairColorChip extends StatelessWidget {
  const _HairColorChip({
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final CultivationHairColor color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: selected
              ? const Color(0xFFD4AF37).withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: selected
                ? const Color(0xFFD4AF37)
                : Colors.white.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: color.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white54),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              color.name,
              style: const TextStyle(color: Color(0xFFF5E6C8), fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

/// 仙山飘渺背景：深色渐变天幕 + 远山剪影 + 云雾，Flutter 代码画，
/// 不依赖外部图片。
class _ImmortalMountainBackground extends StatelessWidget {
  const _ImmortalMountainBackground();

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _MountainPainter(),
      child: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Color(0xFF0B1026),
              Color(0xFF16233F),
              Color(0xFF0E1A2E),
            ],
          ),
        ),
      ),
    );
  }
}

class _MountainPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..style = PaintingStyle.fill;
    // 远山（淡青色剪影）。
    paint.color = const Color(0xFF1E2F4A).withValues(alpha: 0.8);
    final far = Path()
      ..moveTo(0, size.height * 0.62)
      ..lineTo(size.width * 0.18, size.height * 0.42)
      ..lineTo(size.width * 0.36, size.height * 0.58)
      ..lineTo(size.width * 0.55, size.height * 0.38)
      ..lineTo(size.width * 0.72, size.height * 0.56)
      ..lineTo(size.width * 0.88, size.height * 0.44)
      ..lineTo(size.width, size.height * 0.6)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(far, paint);
    // 近山（深色剪影）。
    paint.color = const Color(0xFF0A1220).withValues(alpha: 0.9);
    final near = Path()
      ..moveTo(0, size.height * 0.78)
      ..lineTo(size.width * 0.25, size.height * 0.64)
      ..lineTo(size.width * 0.5, size.height * 0.76)
      ..lineTo(size.width * 0.75, size.height * 0.66)
      ..lineTo(size.width, size.height * 0.78)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(near, paint);
    // 云雾（几团半透明椭圆）。
    paint.color = Colors.white.withValues(alpha: 0.05);
    for (final (x, y, w) in [
      (0.12, 0.30, 0.34),
      (0.55, 0.22, 0.30),
      (0.30, 0.52, 0.40),
      (0.68, 0.48, 0.32),
    ]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(size.width * x, size.height * y),
          width: size.width * w,
          height: size.height * 0.035,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// 粒子特效：漂浮的灵气光点（缓慢上升、明暗闪烁）与飘落的花瓣/光尘，
/// Flutter 代码画，不抢戏、不挡操作（IgnorePointer）。
class _SpiritParticles extends StatefulWidget {
  const _SpiritParticles();

  @override
  State<_SpiritParticles> createState() => _SpiritParticlesState();
}

class _SpiritParticlesState extends State<_SpiritParticles>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  final _random = math.Random(20261105);
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
    _particles = List.generate(28, (_) {
      final rising = _random.nextBool();
      return _Particle(
        x: _random.nextDouble(),
        y: _random.nextDouble(),
        size: rising ? 2 + _random.nextDouble() * 3 : 4 + _random.nextDouble() * 4,
        speed: 0.008 + _random.nextDouble() * 0.02,
        phase: _random.nextDouble() * math.pi * 2,
        rising: rising,
        drift: (_random.nextDouble() - 0.5) * 0.02,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return CustomPaint(
            painter: _ParticlesPainter(_particles, _controller.value),
          );
        },
      ),
    );
  }
}

class _Particle {
  const _Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.phase,
    required this.rising,
    required this.drift,
  });

  final double x;
  final double y;
  final double size;
  final double speed;
  final double phase;
  final bool rising;
  final double drift;
}

class _ParticlesPainter extends CustomPainter {
  _ParticlesPainter(this.particles, this.progress);

  final List<_Particle> particles;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      // 上升的光点从下往上、飘落的花瓣从上往下，循环。
      final t = (p.y + (p.rising ? -1 : 1) * progress * p.speed * 10) % 1.0;
      final dx = (p.x + p.drift * math.sin(progress * math.pi * 2 + p.phase)) %
          1.0;
      final twinkle =
          0.35 + 0.65 * (0.5 + 0.5 * math.sin(progress * math.pi * 4 + p.phase));
      final paint = Paint()
        ..color = (p.rising
                ? const Color(0xFFD4AF37)
                : const Color(0xFFE8B4C8))
            .withValues(alpha: 0.55 * twinkle)
        ..style = PaintingStyle.fill;
      final center = Offset(dx * size.width, t * size.height);
      if (p.rising) {
        canvas.drawCircle(center, p.size, paint);
      } else {
        // 花瓣：小椭圆。
        canvas.drawOval(
          Rect.fromCenter(center: center, width: p.size * 1.6, height: p.size),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlesPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
