/// 档案卡上的数字格式（纯函数，可单测）。
library;

/// 修为：过万显示“x.x万”（如 1.9万），否则原样。
String formatCultivationXp(int xp) {
  if (xp < 10000) return '$xp';
  final value = (xp / 10000).toStringAsFixed(1);
  final trimmed = value.endsWith('.0')
      ? value.substring(0, value.length - 2)
      : value;
  return '$trimmed万';
}

/// 分钟数：不足 1 小时显示“x分钟”，否则显示“x.x小时”（整小时不带小数）。
String formatCultivationMinutes(double minutes) {
  if (minutes <= 0) return '0分钟';
  if (minutes < 60) return '${minutes.round()}分钟';
  final value = (minutes / 60).toStringAsFixed(1);
  final trimmed = value.endsWith('.0')
      ? value.substring(0, value.length - 2)
      : value;
  return '$trimmed小时';
}
