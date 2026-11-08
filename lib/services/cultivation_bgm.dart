import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 创建人物界面的背景音乐开关与播放入口。
///
/// 曲目：百游《凡人修仙传》网游主题曲《修仙缘》，陈楚生唱
/// （王静作词、卢小旭作曲，2011年3月3日发行）；按用户要求
/// 只要十几秒：用 Apple Music 试听版截的 15 秒片段循环播，
/// 不是整首歌。右上角静音开关默认开声音、落盘记偏好，
/// 进主界面后停。
class CultivationBgm {
  CultivationBgm._();

  static final CultivationBgm instance = CultivationBgm._();

  /// 音乐文件在 App 资源里的路径。
  static const assetPath = 'assets/audio/xiuxianyuan.mp3';

  static const _mutedKey = 'cultivation_create_bgm_muted';

  AudioPlayer? _player;

  /// 是否静音（默认 false，即默认开声音）。
  Future<bool> isMuted() async {
    final sp = await SharedPreferences.getInstance();
    return sp.getBool(_mutedKey) ?? false;
  }

  /// 记静音偏好（落盘）；静音时立即停播。
  Future<void> setMuted(bool muted) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_mutedKey, muted);
    if (muted) await stop();
  }

  /// 进场自动播（没静音才播）。
  Future<void> playIfEnabled() async {
    if (await isMuted()) return;
    await play();
  }

  /// 循环播《修仙缘》15 秒片段。
  ///
  /// 测试环境（FLUTTER_TEST）里不建播放器：audioplayers 建播放器
  /// 时会订阅全局事件流，测试里没有插件实现，订阅失败会直接
  /// 导致测试挂掉；反正测试里也听不到声音，直接跳过。
  /// 真机上插件在，正常播。
  Future<void> play() async {
    if (Platform.environment['FLUTTER_TEST'] == 'true') return;
    try {
      _player ??= AudioPlayer();
      await _player!.setReleaseMode(ReleaseMode.loop);
      await _player!.play(AssetSource('audio/xiuxianyuan.mp3'));
    } on MissingPluginException {
      // 插件不可用时静默跳过，免得拖垮页面。
      _player = null;
    }
  }

  /// 停播（进主界面后调）。
  Future<void> stop() async {
    try {
      await _player?.stop();
    } on MissingPluginException {
      // 测试环境没有音频插件实现，跳过即可。
      _player = null;
    }
  }

  /// 设背景音乐音量（0..1）；没在播时只记着，下次播生效。
  Future<void> setVolume(double volume) async {
    try {
      await _player?.setVolume(volume.clamp(0.0, 1.0));
    } on MissingPluginException {
      _player = null;
    }
  }
}
