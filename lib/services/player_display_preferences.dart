import 'package:shared_preferences/shared_preferences.dart';

/// 播放页画面模式与旋转：对照 hongguoTV `VideoFrameMode` 与
/// `VideoRotation`（`kotlin-tv/core/.../ViewingTools.kt` 与
/// `PlaybackComfort.kt`）。
///
/// 对照的三档是 FIT（完整画面）/ ZOOM（等比铺满）/ FILL（拉伸铺满），
/// 旋转是 0 / 90 / 180 / 270 四档（`VideoRotation.normalize`：
/// 不在表里的值归 0）。
///
/// 本地落位情况：
/// - 适应（FIT）与等比铺满（ZOOM）已能走现有通道：分别对应
///   `is_fill_screen` 的关与开（`PlayerPanelPreferences`），竖屏
///   非全屏时生效；横屏全屏对照与本地都强制完整显示（`fitFor`）。
/// - 拉伸铺满（FILL）本地没有对应档：`VideoFit` 只有
///   `fillFrame`（等比铺满裁切）与 `contain`（适应），拉伸要加
///   `VideoFit.fill` 并改 `PlayerVideoLayout.fitFor` 与 chrome
///   的透传——那两个文件不在本次归属内，[PlayerDisplayMode.fill]
///   先只做状态与落盘，弹层里置灰并注明，不造假入口。
/// - 旋转 0°/180° 可直接在播放页的 `RotatedBox` 上叠加元数据
///   修正角；90°/270° 要把旋转后的宽高交给
///   `PlayerVideoLayout.calculate` 重新排画面矩形，同样待 chrome
///   接线，弹层里置灰并注明。
class PlayerDisplayPreferences {
  const PlayerDisplayPreferences._();

  static const displayModeKey = 'player_display_mode';
  static const rotationKey = 'player_video_rotation';

  /// 没存过档位时返回 null，调用方按现有「画面撑满」开关推导。
  static Future<PlayerDisplayMode?> loadMode() async {
    final preferences = await SharedPreferences.getInstance();
    return PlayerDisplayMode.fromStored(preferences.getString(displayModeKey));
  }

  static Future<void> saveMode(PlayerDisplayMode mode) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(displayModeKey, mode.name);
  }

  static Future<int> loadRotation() async {
    final preferences = await SharedPreferences.getInstance();
    return PlayerRotation.normalize(preferences.getInt(rotationKey) ?? 0);
  }

  static Future<void> saveRotation(int degrees) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(rotationKey, PlayerRotation.normalize(degrees));
  }
}

/// 画面模式：对照 `VideoFrameMode` 的三档，文案照对照的中文。
enum PlayerDisplayMode {
  /// 完整画面：整幅画面都显示，黑边留着。
  fit('完整画面'),

  /// 等比铺满：按比例放大铺满画面，多余的裁掉。
  zoom('等比铺满'),

  /// 拉伸铺满：不按比例，直接拉满画面（待播放器布局接线，见文件头）。
  fill('拉伸铺满');

  const PlayerDisplayMode(this.label);

  final String label;

  static PlayerDisplayMode? fromStored(String? value) {
    if (value == null) return null;
    for (final mode in PlayerDisplayMode.values) {
      if (mode.name == value) return mode;
    }
    return null;
  }

  /// 本次归属内能立即生效的档位（只走现有 `is_fill_screen` 通道）。
  bool get appliableNow => this != fill;
}

/// 旋转角：对照 `VideoRotation`，只认 0 / 90 / 180 / 270。
class PlayerRotation {
  const PlayerRotation._();

  static const options = <int>[0, 90, 180, 270];

  static int normalize(int degrees) =>
      options.contains(degrees) ? degrees : 0;

  /// 本次归属内能立即生效的角度：只改 `RotatedBox` 的叠加角，
  /// 不动画面矩形排布，所以只有 0°/180°；90°/270° 待 chrome 接线。
  static bool appliableNow(int degrees) =>
      normalize(degrees) == 0 || normalize(degrees) == 180;
}
