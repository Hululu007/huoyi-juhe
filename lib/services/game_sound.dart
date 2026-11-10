import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cultivation_bgm.dart';

/// 挂机游戏音效：按《凡人修仙传》2.5D 版本那个感觉做——
/// 出剑是剑鸣破空、青元剑诀是剑气上扬、万剑归宗是连珠剑雨、
/// 大庚剑阵是沉钟剑鸣、真魔功是低沉魔啸、泰阳诀是金钟长鸣、
/// 惊蛰十二变是雷鸣化龙；打中是闷响加拼杀音、暴击是脆裂
/// 金鸣加拼杀音、挥剑与出招也叠一层拼杀音；
/// 妖兽死是惨叫低吼、通关是登仙琶音。
///
/// 背景音乐：用户说的“仙凡缘”——树里现成的音频文件只有
/// 一首《修仙缘》mp3（百游《凡人修仙传》网游主题曲 15 秒
/// 片段循环，见 [CultivationBgm]），没有名叫仙凡缘的音频
/// 文件；这里按用户叫法显示为仙凡缘，实际播的就是这首
/// 《修仙缘》，有仙凡缘原文件时直接替换同名文件即可。
/// 音乐和打怪音效可以同时播，音量分开、开关分开（设置里
/// 各有一组开关与音量）。
///
/// 树里现成音效文件有三首：背景乐《修仙缘》mp3、打雷音
/// thunder.mp3（辟邪神雷 / 惊蛰十二变用，见 [playThunder]）
/// 与刀剑拼杀音 sword_clash.mp3（挥剑 / 剑砍中怪物 /
/// 剑剑相碰用，见 [playSwordClash]）；
/// 其余音效用代码合成：22050Hz 单声道 16 位 PCM 写成 wav 存到
/// 应用文档目录，首次播放时生成一次、以后直接播；不用
/// 通用系统提示音代替。测试环境（FLUTTER_TEST）里不建
/// 播放器、不写文件。
class GameSoundService {
  GameSoundService._();

  static final GameSoundService instance = GameSoundService._();

  /// 旧的统一静音键（已废弃，读盘时迁移到音乐/音效两键后删）。
  static const _legacyMutedKey = 'game_sound_muted';

  /// 背景音乐静音键。
  static const _musicMutedKey = 'game_music_muted';

  /// 打怪音效静音键。
  static const _sfxMutedKey = 'game_sfx_muted';

  /// 背景音乐音量键（0..1）。
  static const _musicVolumeKey = 'game_music_volume';

  /// 打怪音效音量键（0..1）。
  static const _sfxVolumeKey = 'game_sfx_volume';

  static const _sampleRate = 22050;

  /// 背景音乐静音（默认开声音），设置里单独开关，落盘。
  final ValueNotifier<bool> musicMutedNotifier = ValueNotifier<bool>(false);

  /// 打怪音效静音（默认开声音），设置里单独开关，落盘。
  final ValueNotifier<bool> sfxMutedNotifier = ValueNotifier<bool>(false);

  /// 背景音乐音量（默认 0.6），设置里单独调，落盘。
  final ValueNotifier<double> musicVolumeNotifier = ValueNotifier<double>(0.6);

  /// 打怪音效音量（默认 1.0），设置里单独调，落盘。
  final ValueNotifier<double> sfxVolumeNotifier = ValueNotifier<double>(1.0);

  bool get musicMuted => musicMutedNotifier.value;
  bool get sfxMuted => sfxMutedNotifier.value;
  double get musicVolume => musicVolumeNotifier.value;
  double get sfxVolume => sfxVolumeNotifier.value;

  Future<void>? _initFuture;
  String? _sfxDir;

  Future<void> ensureInitialized() => _initFuture ??= _init();

  Future<void> _init() async {
    try {
      final sp = await SharedPreferences.getInstance();
      // 旧版只有一个统一静音键：没存过新键时按旧键迁移到两边。
      final legacy = sp.getBool(_legacyMutedKey);
      musicMutedNotifier.value = sp.getBool(_musicMutedKey) ?? legacy ?? false;
      sfxMutedNotifier.value = sp.getBool(_sfxMutedKey) ?? legacy ?? false;
      musicVolumeNotifier.value = (sp.getDouble(_musicVolumeKey) ?? 0.6).clamp(
        0.0,
        1.0,
      );
      sfxVolumeNotifier.value = (sp.getDouble(_sfxVolumeKey) ?? 1.0).clamp(
        0.0,
        1.0,
      );
      if (legacy != null) await sp.remove(_legacyMutedKey);
    } catch (_) {}
  }

  /// 记背景音乐静音偏好；静音时立即停背景乐。
  Future<void> setMusicMuted(bool value) async {
    musicMutedNotifier.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_musicMutedKey, value);
    } catch (_) {}
    if (value) {
      await stopBgm();
    } else {
      await startBgm();
    }
  }

  /// 记打怪音效静音偏好。
  Future<void> setSfxMuted(bool value) async {
    sfxMutedNotifier.value = value;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setBool(_sfxMutedKey, value);
    } catch (_) {}
  }

  /// 记背景音乐音量（0..1），正在播时立即生效。
  Future<void> setMusicVolume(double value) async {
    final volume = value.clamp(0.0, 1.0);
    musicVolumeNotifier.value = volume;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble(_musicVolumeKey, volume);
    } catch (_) {}
    await CultivationBgm.instance.setVolume(volume);
  }

  /// 记打怪音效音量（0..1），下次播放生效。
  Future<void> setSfxVolume(double value) async {
    final volume = value.clamp(0.0, 1.0);
    sfxVolumeNotifier.value = volume;
    try {
      final sp = await SharedPreferences.getInstance();
      await sp.setDouble(_sfxVolumeKey, volume);
    } catch (_) {}
  }

  /// 右上角一键静音：音乐与音效一起开 / 一起关。
  Future<void> setAllMuted(bool value) async {
    await setMusicMuted(value);
    await setSfxMuted(value);
  }

  /// 两边是不是都静音了（右上角喇叭图标用）。
  bool get allMuted => musicMuted && sfxMuted;

  /// 背景乐：仙凡缘（实际文件是《修仙缘》15 秒片段循环）。
  /// 进游戏 tab 就自动播；切走时游戏页调 [stopBgm] 停。
  /// 直接调 [CultivationBgm.play]，不走创建页的静音偏好
  /// （游戏音乐开关只认这里的 [musicMuted]）。
  Future<void> startBgm() async {
    if (musicMuted) return;
    await CultivationBgm.instance.play();
    await CultivationBgm.instance.setVolume(musicVolume);
  }

  /// 停背景乐。
  Future<void> stopBgm() => CultivationBgm.instance.stop();

  /// 点按。
  Future<void> playTap() => _play('tap');

  /// 出剑（剑鸣破空 + 一层刀剑拼杀音）。
  Future<void> playSword() {
    unawaited(playSwordClash());
    return _play('sword');
  }

  /// 放大招：按技能 id 选音效（青元剑诀/大庚剑阵/万剑归宗/
  /// 真魔功/泰阳诀/惊蛰十二变），未知 id 退化为出剑音。
  /// 辟邪神雷（bixie）与惊蛰十二变（jingzhe）走独立打雷音
  /// 文件 [playThunder]，不再用运行时合成的短促版。
  /// 其余出招同时叠一层刀剑拼杀音（[playSwordClash]）。
  Future<void> playSkill(String skillId) {
    if (skillId == 'bixie' || skillId == 'jingzhe') return playThunder();
    unawaited(playSwordClash());
    return _play(skillId);
  }

  /// 上次播打雷音的时间（600ms 防抖用）。
  DateTime? _lastThunderAt;

  /// 打雷音：播独立文件 assets/audio/thunder.mp3（辟邪神雷 /
  /// 惊蛰十二变的主音）。走打怪音效通道：受 sfxMuted 静音
  /// 开关与 sfxVolume 音量控制；600ms 内重复调用只播一次，
  /// 免得大招多波雷叠加炸耳朵；资源加载失败时回退到运行时
  /// 合成的 [_thunderCrack]，不静默无声。
  Future<void> playThunder() async {
    if (sfxMuted) return;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    final now = DateTime.now();
    if (_lastThunderAt != null &&
        now.difference(_lastThunderAt!) < const Duration(milliseconds: 600)) {
      return;
    }
    _lastThunderAt = now;
    AudioPlayer? player;
    try {
      player = AudioPlayer();
      await player.setVolume(sfxVolume);
      await player.play(AssetSource('audio/thunder.mp3'));
      final started = player;
      unawaited(
        Future<void>.delayed(const Duration(seconds: 3)).then((_) async {
          await started.dispose();
        }),
      );
    } on MissingPluginException {
      // 插件不可用时静默跳过，免得拖垮页面。
      try {
        await player?.dispose();
      } catch (_) {}
    } catch (_) {
      // 资源加载失败时回退到合成雷声，别静默无声。
      try {
        await player?.dispose();
      } catch (_) {}
      await _play('bixie');
    }
  }

  /// 上次播刀剑拼杀音的时间（120ms 防抖用）。
  DateTime? _lastSwordClashAt;

  /// 刀剑拼杀音测试可见：上次播拼杀音的时间（防抖测试用）。
  @visibleForTesting
  DateTime? get lastSwordClashAtForTest => _lastSwordClashAt;

  /// 刀剑拼杀音：播独立文件 assets/audio/sword_clash.mp3（挥剑 /
  /// 剑砍中怪物 / 剑剑相碰的清脆金属声：2500/3700/5200Hz 金属
  /// 泛音 + 短促剑刃摩擦噪声，0.45 秒）。走打怪音效通道：受
  /// sfxMuted 静音开关与 sfxVolume 音量控制；120ms 内重复调
  /// 用只播一次，免得连续命中叠加炸耳朵；资源加载失败时静
  /// 默跳过。另一路在战场渲染的挥剑与命中点直接调本方法；
  /// 本文件内的挥剑 / 命中 / 暴击 / 出招（打雷的两招除外）
  /// 也叠一层本音效。
  Future<void> playSwordClash() async {
    if (sfxMuted) return;
    final now = DateTime.now();
    if (_lastSwordClashAt != null &&
        now.difference(_lastSwordClashAt!) <
            const Duration(milliseconds: 120)) {
      return;
    }
    _lastSwordClashAt = now;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    AudioPlayer? player;
    try {
      player = AudioPlayer();
      await player.setVolume(sfxVolume);
      await player.play(AssetSource('audio/sword_clash.mp3'));
      final started = player;
      unawaited(
        Future<void>.delayed(const Duration(seconds: 2)).then((_) async {
          await started.dispose();
        }),
      );
    } on MissingPluginException {
      // 插件不可用时静默跳过，免得拖垮页面。
      try {
        await player?.dispose();
      } catch (_) {}
    } catch (_) {
      // 资源加载失败时静默跳过。
      try {
        await player?.dispose();
      } catch (_) {}
    }
  }

  /// 打中（闷响 + 一层刀剑拼杀音）。
  Future<void> playHit() {
    unawaited(playSwordClash());
    return _play('hit');
  }

  /// 暴击（脆裂金鸣 + 一层刀剑拼杀音）。
  Future<void> playCrit() {
    unawaited(playSwordClash());
    return _play('crit');
  }

  /// 妖兽惨叫（低吼下滑）。
  Future<void> playMonsterCry() => _play('monster_cry');

  /// 通关（登仙琶音）。
  Future<void> playClear() => _play('clear');

  /// 升级 / 突破（登仙琶音 + 低鸣）。
  Future<void> playLevelUp() => _play('level_up');

  /// 打坐轻音（柔和一音）。
  Future<void> playMeditate() => _play('meditate');

  Future<void> _play(String name) async {
    if (sfxMuted) return;
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    try {
      final path = await _soundFile(name);
      if (path == null) return;
      final player = AudioPlayer();
      await player.setVolume(sfxVolume);
      unawaited(
        player
            .play(DeviceFileSource(path))
            .then((_) async {
              await Future<void>.delayed(const Duration(seconds: 2));
              await player.dispose();
            })
            .catchError((Object _) async {
              await player.dispose();
            }),
      );
    } on MissingPluginException {
      // 插件不可用时静默跳过，免得拖垮页面。
    } catch (_) {}
  }

  Future<String?> _soundFile(String name) async {
    final dir = await _dir();
    if (dir == null) return null;
    final file = File('$dir/$name.wav');
    if (!await file.exists()) {
      final bytes = _synthesize(name);
      await file.writeAsBytes(bytes, flush: true);
    }
    return file.path;
  }

  Future<String?> _dir() async {
    if (_sfxDir != null) return _sfxDir;
    try {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/game_sfx');
      if (!await dir.exists()) await dir.create(recursive: true);
      _sfxDir = dir.path;
      return _sfxDir;
    } catch (_) {
      return null;
    }
  }

  /// 按名字合成一段 wav（44 字节头 + 16 位 PCM）。
  List<int> _synthesize(String name) {
    final samples = switch (name) {
      'tap' => _tone(1800, 0.04, 0.5),
      'sword' => _sword(),
      'qingyuan' => _sweep(400, 1600, 0.45, 0.6, shimmer: 2400),
      'dageng' => _bell(const [130, 196, 261], 0.9, 0.7),
      'wanjian' => _arpeggio(
        const [880, 1108, 1318, 1568, 1760, 2093],
        0.09,
        0.55,
      ),
      'zhenmo' => _rumble(0.6),
      'taiyang' => _bell(const [220, 330, 440], 0.7, 0.6),
      'bixie' => _thunderCrack(),
      'qianlan' => _sweep(1600, 300, 0.55, 0.5, shimmer: 3200),
      'jingzhe' => _thunder(),
      'hit' => _thud(160, 0.12),
      'crit' => _crit(),
      'monster_cry' => _cry(),
      'clear' => _arpeggio(const [523, 659, 784, 1046], 0.16, 0.6),
      'level_up' => _levelUp(),
      'meditate' => _tone(660, 0.5, 0.25),
      _ => _tone(1200, 0.08, 0.4),
    };
    return _wav(samples);
  }

  /// 单音正弦，指数衰减。
  List<double> _tone(double freq, double seconds, double volume) {
    final n = (seconds * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final decay = math.exp(-6 * t / seconds);
      out[i] = volume * decay * math.sin(2 * math.pi * freq * t);
    }
    return out;
  }

  /// 扫频正弦（频率从 from 滑到 to）+ 高频闪光。
  List<double> _sweep(
    double from,
    double to,
    double seconds,
    double volume, {
    double? shimmer,
  }) {
    final n = (seconds * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final frac = i / n;
      final freq = from + (to - from) * frac;
      phase += 2 * math.pi * freq / _sampleRate;
      final decay = math.exp(-4 * frac);
      var value = volume * decay * math.sin(phase);
      if (shimmer != null) {
        value +=
            0.15 * decay * math.sin(2 * math.pi * shimmer * i / _sampleRate);
      }
      out[i] = value;
    }
    return out;
  }

  /// 钟鸣：多谐波叠加，长衰减。
  List<double> _bell(List<double> freqs, double seconds, double volume) {
    final n = (seconds * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final decay = math.exp(-3.5 * t / seconds);
      var value = 0.0;
      for (var j = 0; j < freqs.length; j++) {
        value += (j == 0 ? 0.6 : 0.25) * math.sin(2 * math.pi * freqs[j] * t);
      }
      out[i] = volume * decay * value;
    }
    return out;
  }

  /// 琶音：若干单音顺序响起。
  List<double> _arpeggio(List<double> freqs, double step, double volume) {
    final total = (freqs.length * step * _sampleRate).round();
    final out = List<double>.filled(total, 0);
    for (var k = 0; k < freqs.length; k++) {
      final start = (k * step * _sampleRate).round();
      final tone = _tone(freqs[k], step * 1.8, volume);
      for (var i = 0; i < tone.length && start + i < total; i++) {
        out[start + i] += tone[i];
      }
    }
    return out;
  }

  /// 出剑：破空噪声 + 剑鸣。
  List<double> _sword() {
    final random = math.Random(7);
    final n = (0.35 * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final frac = i / n;
      // 破空：前 0.08 秒噪声由强转弱。
      final noise = frac < 0.25
          ? (random.nextDouble() * 2 - 1) * 0.5 * (1 - frac * 4)
          : 0.0;
      // 剑鸣：1568Hz + 2093Hz 金属泛音。
      final ring =
          math.exp(-8 * t) *
          (0.5 * math.sin(2 * math.pi * 1568 * t) +
              0.3 * math.sin(2 * math.pi * 2093 * t));
      out[i] = noise + ring;
    }
    return out;
  }

  /// 真魔功：低沉魔啸（90Hz 颤动 + 311Hz 不协和音）。
  List<double> _rumble(double seconds) {
    final n = (seconds * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final frac = i / n;
      final wobble = 1 + 0.4 * math.sin(2 * math.pi * 7 * t);
      final decay = math.exp(-2.5 * frac);
      out[i] =
          0.55 *
          decay *
          wobble *
          (math.sin(2 * math.pi * 90 * t) +
              0.35 * math.sin(2 * math.pi * 311 * t));
    }
    return out;
  }

  /// 辟邪神雷：雷霆炸裂（噪声爆 + 高频脆响）。
  List<double> _thunderCrack() {
    final random = math.Random(13);
    final n = (0.4 * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final frac = i / n;
      final crack = frac < 0.15
          ? (random.nextDouble() * 2 - 1) * 0.9 * (1 - frac / 0.15)
          : 0.0;
      final ring =
          math.exp(-10 * t) *
          (0.4 * math.sin(2 * math.pi * 1800 * t) +
              0.25 * math.sin(2 * math.pi * 900 * t));
      out[i] = crack + ring;
    }
    return out;
  }

  /// 惊蛰十二变：雷鸣（噪声爆）+ 上扬 + 十二下连珠。
  List<double> _thunder() {
    final random = math.Random(11);
    final n = (1.0 * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final frac = i / n;
      final noise = frac < 0.3
          ? (random.nextDouble() * 2 - 1) * 0.7 * (1 - frac * 3.3)
          : 0.0;
      final rise =
          math.exp(-3 * frac) * math.sin(2 * math.pi * (200 + 1000 * frac) * t);
      // 十二下连珠：每 0.06 秒一记短鸣。
      final tick = (i % (0.06 * _sampleRate).round() == 0)
          ? 0.3 *
                math.exp(-20 * (i % (0.06 * _sampleRate).round()) / _sampleRate)
          : 0.0;
      out[i] = noise + 0.4 * rise + tick;
    }
    return out;
  }

  /// 打中：低频闷响 + 短噪声。
  List<double> _thud(double freq, double seconds) {
    final random = math.Random(3);
    final n = (seconds * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final decay = math.exp(-25 * t);
      out[i] =
          decay *
          (0.7 * math.sin(2 * math.pi * freq * t) +
              0.3 * (random.nextDouble() * 2 - 1));
    }
    return out;
  }

  /// 暴击：脆裂噪声 + 2600Hz 金鸣。
  List<double> _crit() {
    final random = math.Random(5);
    final n = (0.25 * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      final t = i / _sampleRate;
      final crack = i < n * 0.2
          ? (random.nextDouble() * 2 - 1) * 0.8 * (1 - i / (n * 0.2))
          : 0.0;
      final ring = math.exp(-12 * t) * 0.5 * math.sin(2 * math.pi * 2600 * t);
      out[i] = crack + ring;
    }
    return out;
  }

  /// 妖兽惨叫：700Hz 滑到 180Hz，带颤音与低吼噪声。
  List<double> _cry() {
    final random = math.Random(9);
    final seconds = 0.6;
    final n = (seconds * _sampleRate).round();
    final out = List<double>.filled(n, 0);
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final frac = i / n;
      final freq = 700 - 520 * frac;
      phase += 2 * math.pi * freq / _sampleRate;
      final vibrato = 1 + 0.25 * math.sin(2 * math.pi * 9 * i / _sampleRate);
      final decay = math.exp(-2.0 * frac);
      out[i] =
          0.5 * decay * vibrato * math.sin(phase) +
          0.12 * decay * (random.nextDouble() * 2 - 1);
    }
    return out;
  }

  /// 升级：登仙琶音 + 低鸣垫底。
  List<double> _levelUp() {
    final arp = _arpeggio(const [523, 659, 784, 1046, 1318], 0.12, 0.5);
    final pad = _bell(const [130, 196], 0.7, 0.3);
    final n = math.max(arp.length, pad.length);
    final out = List<double>.filled(n, 0);
    for (var i = 0; i < n; i++) {
      out[i] = (i < arp.length ? arp[i] : 0) + (i < pad.length ? pad[i] : 0);
    }
    return out;
  }

  /// 采样值拼成 wav 字节（44 字节头 + 16 位 PCM）。
  List<int> _wav(List<double> samples) {
    final dataSize = samples.length * 2;
    final bytes = <int>[];
    void ascii(String s) => bytes.addAll(s.codeUnits);
    void u32(int v) => bytes.addAll([
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ]);
    void u16(int v) => bytes.addAll([v & 0xFF, (v >> 8) & 0xFF]);
    ascii('RIFF');
    u32(36 + dataSize);
    ascii('WAVE');
    ascii('fmt ');
    u32(16);
    u16(1); // PCM
    u16(1); // 单声道
    u32(_sampleRate);
    u32(_sampleRate * 2);
    u16(2);
    u16(16);
    ascii('data');
    u32(dataSize);
    for (final sample in samples) {
      final clamped = sample.clamp(-1.0, 1.0);
      final value = (clamped * 32767).round();
      u16(value & 0xFFFF);
    }
    return bytes;
  }
}
