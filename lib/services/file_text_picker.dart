import 'dart:convert';

import 'package:file_selector/file_selector.dart';

import 'gbk_codec.dart';

/// 选到的每个文件：读成功给 bytes，读失败给 error（单文件失败不掀整批，
/// 由批量导入汇总时写清，不静默吞掉）。
typedef PickedTextFile = ({String name, List<int>? bytes, String? error});

/// 读文件文本：先按 UTF-8 严格解，失败再按 GBK 解（树里已有的
/// gbkDecode，见 gbk_codec.dart），两者都解不出时用宽容 UTF-8
/// 兜底、不抛错。GBK 编码的 py 直接走 XFile.readAsString() 会抛
/// FormatException，选完文件源码框空白、无任何提示，就是这一步
/// 静默死的。BOM 头去掉，避免粘贴进源码框后校验认不出。
String decodePickedText(List<int> bytes) {
  String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    try {
      text = gbkDecode(bytes);
    } catch (_) {
      text = utf8.decode(bytes, allowMalformed: true);
    }
  }
  return text.startsWith('\uFEFF') ? text.substring(1) : text;
}

/// 选一个文本文件并读出全文与文件名；用户取消返回 null。
/// 供“改文件导入”的入口复用：书源 JSON、py 蜘蛛都走它。
/// 选文件器起不来、文件读不到时原样抛错，调用点负责接住并提示，
/// 不在这里静默吞掉。
Future<({String name, String content})?> pickTextFile({
  required String label,
  required List<String> extensions,
}) async {
  final file = await openFile(
    acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  return (name: file.name, content: decodePickedText(bytes));
}

/// 一次选多个文本文件并读出各自的字节；用户取消返回空列表。
/// 选文件器本身起不来时原样抛错（调用点弹“选文件失败”）；
/// 单个文件读不到时只记 error、不掀整批，由批量导入汇总时写清。
Future<List<PickedTextFile>> pickTextFiles({
  required String label,
  required List<String> extensions,
}) async {
  final files = await openFiles(
    acceptedTypeGroups: [XTypeGroup(label: label, extensions: extensions)],
  );
  final picked = <PickedTextFile>[];
  for (final file in files) {
    try {
      picked.add((name: file.name, bytes: await file.readAsBytes(), error: null));
    } catch (e) {
      picked.add((name: file.name, bytes: null, error: e.toString()));
    }
  }
  return picked;
}
