# iOS 版：构建与已知限制

iOS 端支持搜书、书架和阅读，并通过进程内 `media_kit` 接入视频与音频播放。平台适配仍需要在 Mac 上构建并在 iPhone 上验证；下列限制保留为交付边界。

## 构建环境

| 组件 | 版本 | 备注 |
|---|---|---|
| macOS | 26 | iOS 构建需在本机 Mac 上完成 |
| Xcode | 26.6 | 本地选择 `/Applications/Xcode_26.6.app/Contents/Developer` |
| Flutter | **3.50.0** | 与 `pubspec.lock`、Android / Windows / Linux CI 保持一致 |
| CocoaPods | 1.17.0 | `brew install cocoapods`（系统 Ruby 太旧，别用 gem 装） |
| Rust | 1.99.1 | `rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios` |
| flutter_rust_bridge_codegen | 2.13.0 | 必须与 `rust/Cargo.toml` 里的版本一致 |

## 构建

```bash
flutter pub get --enforce-lockfile
bash scripts/build_rust_ios.sh      # Rust → ios/Frameworks/iphoneos/libfqapi_core.a
(cd ios && pod install)              # 安装 media_kit 的 iOS 播放框架
flutter build ios --release --no-codesign
```

产物在 `build/ios/iphoneos/Runner.app`（未签名）。

模拟器构建不需要签名或 Apple 开发者账号：

```bash
bash scripts/build_rust_ios.sh --simulator
flutter build ios --simulator --debug --no-pub
```

Rust 模拟器库按当前 Mac 架构编译，Xcode 根据 SDK 自动选择，不能将真机 arm64 库用于模拟器。

## 没有 Mac 或 iPhone 时

仓库不再运行 iOS CI；未签名的 iOS 构建和模拟器启动必须在本机 Mac 上完成。没有 Mac 时，
不应把 iOS 构建或启动视为已验证，其他平台的 CI 结果也不能代替。

模拟器启动证据只代表冷启动，不代表搜索、播放、登录、分享或 TTS 交互已经验收；
锁屏后台音频、来电和蓝牙中断仍需真机。生产上游媒体源、实际声音、登录及分享仍需单独验收；
原生媒体快照接口仅编译进 Debug，正式 Release 包不包含。

打包成未签名 IPA：

```bash
rm -rf /tmp/pack && mkdir -p /tmp/pack/Payload
ditto build/ios/iphoneos/Runner.app /tmp/pack/Payload/Runner.app
(cd /tmp/pack && zip -qry fanrenxiuxian_ios_unsigned.ipa Payload)
```

## 签名

`DEVELOPMENT_TEAM` 不入库。首次构建前把它放进本地文件：

```bash
cp ios/Flutter/Signing.xcconfig.example ios/Flutter/Signing.xcconfig
# 把 DEVELOPMENT_TEAM 改成自己的 Team ID；该文件已被 ios/.gitignore 忽略
```

只要改 `Signing.xcconfig` 就够了，别在 Xcode 的 Signing 页里再选一次 Team——那样
Xcode 会把 `DEVELOPMENT_TEAM` 写回 `ios/Runner.xcodeproj/project.pbxproj`，让工程文件变脏。
`CODE_SIGN_STYLE` 仍是 Automatic，Team 由 xcconfig 供值。

装到真机可以走自签（免费 Apple ID 7 天有效，过期后 App 闪退，重新签一次即可）。
下面的命令按你自己的签名脚本替换：

```bash
BUNDLE_ID=com.fanrenxiuxianguanyingchuan IPA=/tmp/pack/fanrenxiuxian_ios_unsigned.ipa ./your-sign-script.sh
```

## iOS 专用改动（为什么需要）

1. **Rust 核心以静态库链接**。iOS 不允许从 App 包内 dlopen 共享库，所以：
   - `scripts/build_rust_ios.sh` 用 `--crate-type staticlib` 编出按 SDK 分目录的 `libfqapi_core.a`（`CARGO_PROFILE_RELEASE_STRIP=debuginfo`，因为 release profile 的 `strip = true` 会裁掉符号）；
   - `ios/Flutter/{Debug,Release}.xcconfig` 共用 `Rust.xcconfig` 的三个必需设置：
     - `-force_load` 把静态库目标文件全部装进来；
     - `DEAD_CODE_STRIPPING = NO`，否则「只在运行时 dlsym」的符号会被 dead_strip 删掉；
     - `-Wl,-export_dynamic`，主可执行文件默认不导出全局符号，dlsym 会找不到 Rust 入口；
   - `lib/services/rust_bootstrap_io.dart` 在 iOS 上改用 `ExternalLibrary.process()`（接缝在 `lib/services/backend_transport.dart` 的 `runtimeInitializer`）。
2. **桌面专用依赖**（`webview_windows` / `smtc_windows` / `window_manager` / `screen_retriever`）不需要条件导入：它们都能在 iOS 上编译，运行时只在 `isWindowsDesktop` 分支调用。
3. **进程内播放适配**：`IosPlatform` 将播放器通道接到 `DesktopPlatform` 的 `media_kit` 播放器，视频页面使用 `VideoController` 表面。加密音视频经 Rust 的本机会话解密；原生入口通过进程导出符号读取。亮屏锁使用 `wakelock_plus`，不会调用 Windows 系统 API。
4. **图标与应用名**：`scripts/generate_ios_app_icon.py` 从 `assets/branding/app_icon_source.png` 生成 1024 无 alpha 图标（复用 Android 生成器的「去纸张外框」逻辑），`CFBundleDisplayName` 设为「什锦铺」。
5. **使用 CocoaPods**：构建前执行 `flutter config --no-enable-swift-package-manager`，与当前 Podfile 和锁文件保持一致。
6. **文件与网页登录**：TXT/EPUB 和 JSON 导入传入 iOS UTI；文件导出通过系统分享面板，取消不算成功。番茄登录使用 `WKWebView`，成功或取消都结束原登录请求。
7. **系统朗读与后台音频**：朗读使用 `AVSpeechSynthesizer`，`SystemTtsBridge` 为每个原生 utterance 保存 ID，转发开始、字符范围和完成事件；取消先清除旧 ID，避免回调串句。听书、视频及朗读通过同一 `AudioSessionBridge` 管理会话，在播放前配置 `playback` 并激活，停止后释放；冷启动不抢占音频。`Info.plist` 声明后台音频。系统语音设置入口显示手动前往设置的说明。媒体卡片、系统控制键与中断恢复的所有权和验收范围见 [IOS_MEDIA_SESSION.md](IOS_MEDIA_SESSION.md)。

## 已知限制

- 视频、音频、系统朗读、文件选择和网页登录的 iOS 适配已接入源码；仍需完成 Mac 签名构建与真机验证，不能以 Windows 宿主检查代替。
- 画中画和悬浮窗尚未接入。锁屏媒体卡片与控制键已接入；后台音频、锁屏、来电恢复、蓝牙路由和播放器相互接管的实际行为需在 iPhone 上验证。
- 分享成功返回的是应用临时文件路径；文件是否已存入「文件」或发送到其他应用由用户选择的分享操作决定。
- 阅读亮度、墨水屏和其他 Android 专有能力继续按平台支持情况降级；LAN 分享与番茄接口兼容性需要单独验证。
- 免费 Apple ID 签名 7 天过期，过期后 App 闪退，重跑一次自签脚本即可。

## 与 Android 构建的关系

当前仓库统一使用 Flutter 3.50.0 / Dart 3.14.0；Android、Windows 和 Linux CI 使用同一工具链。
iOS 构建需在 Mac 本地完成。
