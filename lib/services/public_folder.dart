import 'package:flutter/services.dart';

/// 手机根目录公开文件夹的原生通道。
///
/// Android 11+ 上根目录任意文件夹的写权限属于全部文件访问
/// （MANAGE_EXTERNAL_STORAGE）：应用只能打开系统设置页请用户
/// 亲手开一次，不能静默拿到。文件夹本身的创建由 Dart 侧
/// Directory.create 自动做，不用用户手动建。
class PublicFolder {
  PublicFolder._();

  static const _channel = MethodChannel('fqapp/public_folder');

  /// 主外置存储根目录（原生 Environment.getExternalStorageDirectory）；
  /// 通道不可用时回落标准路径。
  static Future<String> publicRoot() async {
    try {
      final root = await _channel.invokeMethod<String>('publicRoot');
      if (root != null && root.isNotEmpty) return root;
    } catch (_) {}
    return '/storage/emulated/0';
  }

  static Future<bool> hasAllFilesAccess() async {
    try {
      return await _channel.invokeMethod<bool>('hasAllFilesAccess') ?? false;
    } catch (_) {
      return false;
    }
  }

  /// 打开系统设置页，请用户为本应用开启全部文件访问权限。
  static Future<void> requestAllFilesAccess() async {
    try {
      await _channel.invokeMethod<void>('requestAllFilesAccess');
    } catch (_) {}
  }
}
