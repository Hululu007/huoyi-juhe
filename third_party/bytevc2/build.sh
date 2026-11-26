#!/usr/bin/env bash
# 构建自带 bytevc2(BVC2 / H.266 类)转码器。设计与边界见同目录 README.md。
#
# 用法:
#   third_party/bytevc2/build.sh host            # 桌面(Windows/Linux/macOS)
#   third_party/bytevc2/build.sh android arm64   # arm64(arm64-v8a,真机)
#   third_party/bytevc2/build.sh android armv7   # armv7(armeabi-v7a)
#   third_party/bytevc2/build.sh android x86_64  # x86_64(仅本地实验用)
#
# 产物:
#   桌面   -> build/bytevc2/out/host/bytevc2-ffmpeg[.exe]
#   Android-> android/app/src/main/jniLibs/<abi>/libbvc2transcode.so
set -euo pipefail

FFMPEG_VERSION="8.1.3"
X264_REPO="https://github.com/mirror/x264.git"
# 与 scripts/build_rust_backend.sh 同一把 NDK:换版本就会换工具链,
# 不允许静默 fallback 到本机其它 NDK。
PINNED_NDK_VERSION="28.2.13676358"
ANDROID_API="${ANDROID_API:-24}"

MODE="${1:-}"
TARGET="${2:-}"

HERE="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$HERE/../.." && pwd)"

# NDK 里的 clang 是原生 Windows 程序,而 configure/make 全程在 MSYS shell 里
# 传路径:只有 /c/... 这种形式在两个方向上都安全。Windows 形式(C:\...)会被
# sh 当转义序列吃掉反斜杠,变成 "C:android-sdk\..." 这种不存在的路径。
to_posix() {
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -u "$1"
  else
    printf '%s' "$1" | sed -E 's|\\|/|g'
  fi
}

if [ "$MODE" = "android" ]; then
  case "$TARGET" in
    arm64)  ABI="arm64-v8a";   CLANG_TRIPLE="aarch64-linux-android";    FF_ARCH="aarch64" ;;
    armv7)  ABI="armeabi-v7a"; CLANG_TRIPLE="armv7a-linux-androideabi"; FF_ARCH="arm" ;;
    x86_64) ABI="x86_64";      CLANG_TRIPLE="x86_64-linux-android";     FF_ARCH="x86_64" ;;
    *) echo "错误:未知 Android 目标 '$TARGET'(可选 arm64 / armv7 / x86_64)。" >&2; exit 2 ;;
  esac
elif [ "$MODE" = "host" ]; then
  :
else
  echo "用法: $0 host | android <arm64|armv7|x86_64>" >&2
  exit 2
fi

# 每个目标一个工作目录:ffmpeg 源码树与 libx264.a 都不能跨 ABI 复用,否则
# 第二个 ABI 会链接到上一个 ABI 编译出来的 x264。
WORK_DIR="${BYTEVC2_WORK_DIR:-$APP_DIR/build/bytevc2/$MODE${TARGET:+-$TARGET}}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

if [ ! -d "ffmpeg-$FFMPEG_VERSION" ]; then
  echo "==> 取 ffmpeg $FFMPEG_VERSION 源码..."
  curl -fsSL -o "ffmpeg-$FFMPEG_VERSION.tar.xz" \
    "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"
  tar -xf "ffmpeg-$FFMPEG_VERSION.tar.xz"
fi

FFMPEG_SRC="$WORK_DIR/ffmpeg-$FFMPEG_VERSION"
cd "$FFMPEG_SRC"
if ! grep -q bvc2 libavcodec/allcodecs.c; then
  echo "==> 打 BVC2 解码补丁..."
  PATCH_FILE="$HERE/0001-add-bvc2-decoder.patch"
  # patch 与 git 都是原生 Windows 程序:给它们 /c/... 形式的路径只会失败
  # (patch 报 "read error: Is a directory",git apply 报 "Invalid
  # argument"),所以传盘符形式。stdin 重定向同理不可依赖。
  if command -v cygpath >/dev/null 2>&1; then
    PATCH_FILE="$(cygpath -m "$PATCH_FILE")"
  fi
  if ! patch -p1 -l -i "$PATCH_FILE" && ! git apply -p1 "$PATCH_FILE"; then
    echo "错误:BVC2 解码补丁打不上($PATCH_FILE)。" >&2
    exit 1
  fi
  # 补丁必须验结果:静默失败过一次——没打上时 `--enable-decoder=bvc2` 并不
  # 报错(configure 不校验证码名),产物要到运行期才露馅。
  if ! grep -q bvc2 libavcodec/allcodecs.c; then
    echo "错误:BVC2 解码补丁未生效($PATCH_FILE)。" >&2
    exit 1
  fi
fi

# libx264 是这里唯一的 H.264 编码器;上游补丁构建也是这么配的。
if [ ! -f "$WORK_DIR/x264/libx264.a" ]; then
  echo "==> 编译 x264..."
  [ -d "$WORK_DIR/x264" ] || git clone --depth 1 "$X264_REPO" "$WORK_DIR/x264"
  ( cd "$WORK_DIR/x264" && rm -f config.mak config.h .depend )
fi

# x264 的 install 走 make,MSYS 形式(/c/...)的前缀最稳:原生 install.exe
# 由 MSYS 自动做路径转换。
X264_PREFIX="$WORK_DIR/x264-prefix"
X264_ARGS=(--enable-static --disable-cli --enable-pic --disable-opencl
  --prefix="$X264_PREFIX")
# x86 的手写汇编要 nasm;少了它就退回纯 C——汇编器缺席不该让构建失败。
EXTRA_CONFIGURE_ARGS=()
if [ "$MODE" = "android" ]; then BUILD_ARCH="${CLANG_TRIPLE%%-*}"; else BUILD_ARCH="$(uname -m)"; fi
case "$BUILD_ARCH" in
  x86_64|amd64|AMD64|i686|i386)
    if ! command -v nasm >/dev/null 2>&1; then
      X264_ARGS+=(--disable-asm)
      EXTRA_CONFIGURE_ARGS+=(--disable-x86asm)
    fi
    ;;
esac

CONFIGURE_ARGS=(
  --extra-version=bvc2
  --disable-everything --disable-doc --disable-debug --disable-network
  --enable-gpl --enable-version3 --disable-shared --enable-static
  --pkg-config-flags=--static
  --enable-decoder=bvc2,vvc,h264,hevc,aac --enable-parser=h264,aac
  --enable-encoder=aac,libx264 --enable-demuxer=mov --enable-muxer=mp4
  --enable-protocol=file,crypto,pipe --enable-bsf=h264_mp4toannexb,aac_adtstoasc
  --enable-filter=scale,format,aresample,null
  --enable-swscale --enable-swresample --enable-avfilter
  --enable-libx264
)
CONFIGURE_ARGS+=(${EXTRA_CONFIGURE_ARGS[@]+"${EXTRA_CONFIGURE_ARGS[@]}"})

if [ "$MODE" = "android" ]; then
  NDK_ROOT="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
  if [ -z "$NDK_ROOT" ]; then
    SDK_ROOT="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
    [ -n "$SDK_ROOT" ] && NDK_ROOT="$SDK_ROOT/ndk/$PINNED_NDK_VERSION"
  fi
  if [ -n "$NDK_ROOT" ]; then NDK_ROOT="$(to_posix "$NDK_ROOT")"; fi
  if [ -z "$NDK_ROOT" ] || [ ! -d "$NDK_ROOT" ]; then
    echo "错误:找不到 Android NDK $PINNED_NDK_VERSION。请设置 ANDROID_NDK_HOME。" >&2
    exit 1
  fi
  case "$(uname -s)" in
    Darwin) HOST_TAG="darwin-x86_64" ;;
    Linux) HOST_TAG="linux-x86_64" ;;
    MINGW*|MSYS*|CYGWIN*) HOST_TAG="windows-x86_64" ;;
    *) echo "错误:不支持当前 NDK 主机平台。" >&2; exit 1 ;;
  esac
  TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/bin"
  SYSROOT="$NDK_ROOT/toolchains/llvm/prebuilt/$HOST_TAG/sysroot"
  CC="$TOOLCHAIN/${CLANG_TRIPLE}${ANDROID_API}-clang"
  CXX="$TOOLCHAIN/${CLANG_TRIPLE}${ANDROID_API}-clang++"
  # NDK 里无扩展名的 clang 是 sh 包装脚本,configure/make 全程能 exec;
  # Windows 版 NDK 另带一份 .cmd,只有前者缺失时才退回它。
  if [ ! -f "$CC" ]; then CC="$CC.cmd"; CXX="$CXX.cmd"; fi

  ( cd "$WORK_DIR/x264" && CC="$CC" AR="$TOOLCHAIN/llvm-ar" \
      RANLIB="$TOOLCHAIN/llvm-ranlib" ./configure --host="$CLANG_TRIPLE" \
      --cross-prefix= --sysroot="$SYSROOT" \
      "${X264_ARGS[@]}" --extra-cflags="-O2 -fPIC" && touch .depend \
      && make -j"$(nproc 2>/dev/null || echo 4)" && make install )
  CONFIGURE_ARGS+=(
    --target-os=android --arch="$FF_ARCH"
    --enable-cross-compile --cc="$CC" --cxx="$CXX"
    --ar="$TOOLCHAIN/llvm-ar" --ranlib="$TOOLCHAIN/llvm-ranlib"
    --nm="$TOOLCHAIN/llvm-nm" --strip="$TOOLCHAIN/llvm-strip"
    --sysroot="$SYSROOT"
    --extra-cflags="-I$X264_PREFIX/include -O2 -fPIC"
    --extra-ldflags="-L$X264_PREFIX/lib -static-libgcc -Wl,-z,max-page-size=16384"
  )
else
  ( cd "$WORK_DIR/x264" && ./configure "${X264_ARGS[@]}" && make -j"$(nproc)" \
      && make install )
  CONFIGURE_ARGS+=(
    --extra-cflags="-I$X264_PREFIX/include"
    --extra-ldflags="-L$X264_PREFIX/lib"
  )
fi

export PKG_CONFIG_PATH="$X264_PREFIX/lib/pkgconfig"

echo "==> 配置 ffmpeg($MODE${TARGET:+ $TARGET})..."
./configure "${CONFIGURE_ARGS[@]}"
make -j"$(nproc 2>/dev/null || echo 4)"

if [ "$MODE" = "android" ]; then
  # Android 只允许执行 apk 里 lib/ 下的 so,所以转码器必须以 lib*.so 命名
  # 并放进对应 ABI 的 jniLibs;Gradle 自己会打包。
  JNI_DIR="$APP_DIR/android/app/src/main/jniLibs/$ABI"
  mkdir -p "$JNI_DIR"
  cp -f ffmpeg "$JNI_DIR/libbvc2transcode.so"
  echo "==> jniLibs: $JNI_DIR/libbvc2transcode.so"
  ls -l "$JNI_DIR/libbvc2transcode.so"
else
  OUT_DIR="$APP_DIR/build/bytevc2/out/host"
  mkdir -p "$OUT_DIR"
  cp -f ffmpeg "$OUT_DIR/bytevc2-ffmpeg"
  cp -f ffprobe "$OUT_DIR/bytevc2-ffprobe"
  echo "==> 桌面产物: $OUT_DIR"
  ls -l "$OUT_DIR"
fi
