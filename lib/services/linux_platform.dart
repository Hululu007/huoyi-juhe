// 本地最小等效，不是上游原文。
//
// 上游 lib/services/linux_platform.dart 的 LinuxPlatform.install 需要
// DesktopPlatform.pickBook()/disposeMedia() 与 DesktopSystemSession，
// 本树本地改过的 desktop_platform.dart 里都没有，整取编不过；
// 而本树是安卓单平台，Linux 安装路径永远不会走到，唯一被用到的符号
// 只有 isLinuxDesktop（阅读设置面板两处）。只保留它。
// 日后若要接 Linux 桌面端，须先把上游 desktop_platform.dart 的
// DesktopSystemSession、pickBook、disposeMedia 一并搬过来，再整取本文件。
import 'package:flutter/foundation.dart';

bool get isLinuxDesktop =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;
