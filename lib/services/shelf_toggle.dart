import 'package:flutter/material.dart';
import 'package:material_ui/material_ui.dart' as mui;

import '../models/media_item.dart';
import 'shelf_store.dart';

/// 「加入书架」的共用动作（issue #103）。
///
/// 详情页有自己的实现（`detail_page.dart`）。阅读器、漫画阅读器这类没有详情页的
/// 界面也要能加书架，提示语与「书架没起来」的兜底保持一致，所以收在这里。
bool inShelf(MediaItem item) => ShelfStore.instance.containsItem(item);

/// 对 [context] 发一条书架提示。
///
/// 阅读器跑在 material_ui 的 Scaffold 上：SDK 的 ScaffoldMessenger 祖先
/// （MaterialApp 自带的那个）名下没有 SDK Scaffold，SDK 的 showSnackBar
/// 在 debug 下断言失败、release 下静默丢提示。漫画阅读器是 SDK Scaffold，
/// 走 SDK 那条。所以先看调用方祖先里有没有 mui 的 ScaffoldMessenger，
/// 有就走 mui，没有再走 SDK，两边提示文案一致。
void _showShelfSnackBar(BuildContext context, String message) {
  final muiMessenger = mui.ScaffoldMessenger.maybeOf(context);
  if (muiMessenger != null) {
    muiMessenger.showSnackBar(
      mui.SnackBar(
        content: Text(message),
        duration: const Duration(seconds: 2),
      ),
    );
    return;
  }
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
  );
}

/// 切换 [item] 的书架状态并提示结果。
///
/// 书架不可用（Hive 没起来）时只提示、不抛异常，也不假装成功。
Future<void> toggleShelf(BuildContext context, MediaItem item) async {
  if (!ShelfStore.instance.isReady) {
    if (context.mounted) {
      _showShelfSnackBar(context, '本地书架暂不可用，请重试');
    }
    return;
  }
  final added = await ShelfStore.instance.toggle(item);
  if (!context.mounted) return;
  _showShelfSnackBar(context, added ? '已加入书架' : '已移出书架');
}
