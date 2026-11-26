# ios/Frameworks

这个目录放 iOS 端链接用的 Rust 静态库，产物**不入库**（`ios/.gitignore` 忽略
`Frameworks/iphoneos/` 和 `Frameworks/iphonesimulator/`），由脚本从 `rust/` 源码重建。

`ios/Flutter/{Debug,Release}.xcconfig` 引用 `Rust.xcconfig`，按 SDK 选择：

```
FQAPI_CORE_LIBRARY[sdk=iphoneos*] = $(SRCROOT)/Frameworks/iphoneos/libfqapi_core.a
FQAPI_CORE_LIBRARY[sdk=iphonesimulator*] = $(SRCROOT)/Frameworks/iphonesimulator/libfqapi_core.a
```

所以第一次 clone 下来直接 `flutter build ios` 会失败在链接阶段，报找不到
`libfqapi_core.a`（或 Rust 符号未定义）。先跑一次：

```bash
bash scripts/build_rust_ios.sh              # 真机 arm64
bash scripts/build_rust_ios.sh --simulator  # 真机 + 当前 Mac 架构的模拟器
```

Apple Silicon 模拟器使用 `aarch64-apple-ios-sim`，Intel 使用 `x86_64-apple-ios`。
真机与模拟器库分目录存放，Xcode 自动选择，不需要手改链接路径。

改了 `rust/` 下的代码之后要重新跑一次脚本，否则 App 里跑的还是旧的静态库。
