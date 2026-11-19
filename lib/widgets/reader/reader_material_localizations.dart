import 'package:material_ui/material_ui.dart';

/// material_ui 本地化补齐：外壳是 SDK MaterialApp，只提供 SDK 型的
/// MaterialLocalizations；阅读器子树与它弹出的面板/对话框跑的是
/// material_ui 的 widget，后者要的是 material_ui 自己的
/// MaterialLocalizations（GlobalMaterialLocalizations.delegate，见
/// material_ui-1.11.0/lib/src/global_material_localizations.dart）。
/// mui 的 showModalBottomSheet/showDialog 在打开时就用调用方 context 取
/// mui 本地化（barrier 文案），面板内容里的 mui widget（AppBar 等）也要
/// 它；缺了就在 debug 下断言失败、release 下抛空值。
///
/// Localizations.override 把 mui 的 delegate 插到祖先 delegates 之前，
/// 语言默认取祖先 locale（应用强制 zh_CN），SDK 型的本地化仍由祖先
/// delegates 提供，不重复、不改语言。包在三处：ReaderPage 自己的 build
///（覆盖正文与它直接打开的面板的调用方 context）、每个阅读器面板/
/// 对话框的 builder（路由内容不继承调用方子树，必须在 builder 里再包
/// 一层）、以及测试里直接调面板的假调用方。
class ReaderMaterialLocalizations extends StatelessWidget {
  const ReaderMaterialLocalizations({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Localizations.override(
      context: context,
      delegates: const [GlobalMaterialLocalizations.delegate],
      child: child,
    );
  }
}
