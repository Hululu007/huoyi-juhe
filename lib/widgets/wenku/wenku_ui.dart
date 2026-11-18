// 本地最小桶文件，不是上游原文。
//
// 上游 wenku_ui.dart 导出 30 个文件（整套书架 / 档案 / 玻璃界面），
// 传递闭包 57 个文件并依赖 liquid_glass_easy 整包（着色器 + 控制器），
// 本树不引入。阅读设置实际用到的只有以下符号，这里只导出这些：
//   - AppHaptics / HapticCue（上游原文 src/app_haptics.dart）
//   - PerformanceScope / PerformancePreferences（上游原文 src/performance_preferences.dart）
//   - GlassControls / GlassIconButton / JellyTapSurface（本地等效 local_glass_fallback.dart）
export 'local_glass_fallback.dart';
export 'src/app_haptics.dart';
export 'src/performance_preferences.dart';
