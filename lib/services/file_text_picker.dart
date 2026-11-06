import 'package:file_selector/file_selector.dart';

/// 选一个文本文件并读出全文与文件名；用户取消返回 null。
/// 供“改文件导入”的入口复用：书源 JSON、py 蜘蛛都走它。
Future<({String name, String content})?> pickTextFile({
  required String label,
  required List<String> extensions,
}) async {
  final file = await openFile(
    acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
  );
  if (file == null) return null;
  return (name: file.name, content: await file.readAsString());
}
