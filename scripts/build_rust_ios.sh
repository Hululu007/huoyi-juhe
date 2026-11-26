#!/usr/bin/env bash
# 编译 Rust 核心（fqapi_core）的 iOS 静态库并放进 ios/Frameworks/。
#
# 为什么是静态库：iOS 不允许从 App 包内 dlopen 自带的 .so/.dylib 那样随意加载，
# 官方的做法是把 Rust 编成 staticlib 后整体链进主二进制（见 ios/Flutter/*.xcconfig
# 里的 -force_load），运行时由 flutter_rust_bridge 的
# ExternalLibrary.process() 从进程自身符号里查找入口（见 lib/services/rust_bootstrap_io.dart）。
#
# 用法：
#   bash scripts/build_rust_ios.sh              # 只编真机 arm64（出 IPA 用）
#   bash scripts/build_rust_ios.sh --simulator  # 额外编当前 Mac 架构的模拟器库
#
# 与 scripts/build_rust_backend.sh 同一套约定：pin 版本、缺依赖就硬错，不静默降级。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$(dirname "$SCRIPT_DIR")"
MANIFEST="$APP_DIR/rust/Cargo.toml"
OUT_DIR="$APP_DIR/ios/Frameworks"
SIMULATOR=0

case "${1:-}" in
  "") ;;
  --simulator) SIMULATOR=1 ;;
  -h|--help) echo "Usage: $0 [--simulator]"; exit 0 ;;
  *) echo "错误：未知参数：$1" >&2; exit 2 ;;
esac

if ! command -v cargo >/dev/null 2>&1; then
  echo "错误：未找到 cargo，请先安装 Rust 工具链。" >&2
  exit 1
fi
if ! command -v xcrun >/dev/null 2>&1; then
  echo "错误：未找到 xcrun，请先安装完整 Xcode 并 xcode-select 指向它。" >&2
  exit 1
fi
if [ ! -f "$MANIFEST" ]; then
  echo "错误：找不到 Rust 清单 $MANIFEST" >&2
  exit 1
fi

# release profile 里 `strip = true` 会把符号表一起裁掉，静态库链接会因此找不到导出符号。
# iOS 产物统一用 debuginfo 级别：只去调试信息，保留符号。
export CARGO_PROFILE_RELEASE_STRIP=debuginfo

build_target() {
  local target="$1"
  echo "==> cargo rustc --target $target (staticlib)"
  ( cd "$APP_DIR" && cargo rustc --locked --release \
      --manifest-path "$MANIFEST" \
      --target "$target" \
      --crate-type staticlib )
  local lib="$APP_DIR/rust/target/$target/release/libfqapi_core.a"
  if [ ! -s "$lib" ]; then
    echo "错误：未产出 $lib" >&2
    exit 1
  fi
  echo "    $(ls -lh "$lib" | awk '{print $5}')  $lib"
}

build_target aarch64-apple-ios
mkdir -p "$OUT_DIR/iphoneos"
cp -f "$APP_DIR/rust/target/aarch64-apple-ios/release/libfqapi_core.a" \
      "$OUT_DIR/iphoneos/libfqapi_core.a"
echo "==> 已放置：$OUT_DIR/iphoneos/libfqapi_core.a"
lipo -info "$OUT_DIR/iphoneos/libfqapi_core.a"

if [ "$SIMULATOR" -eq 1 ]; then
  case "$(uname -m)" in
    arm64) simulator_target=aarch64-apple-ios-sim ;;
    x86_64) simulator_target=x86_64-apple-ios ;;
    *) echo "错误：不支持的 Mac 架构。" >&2; exit 1 ;;
  esac
  build_target "$simulator_target"
  mkdir -p "$OUT_DIR/iphonesimulator"
  cp -f "$APP_DIR/rust/target/$simulator_target/release/libfqapi_core.a" \
        "$OUT_DIR/iphonesimulator/libfqapi_core.a"
  echo "==> 已放置：$OUT_DIR/iphonesimulator/libfqapi_core.a"
  lipo -info "$OUT_DIR/iphonesimulator/libfqapi_core.a"
fi
