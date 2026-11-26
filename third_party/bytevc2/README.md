# bytevc2(BVC2 / H.266 类)转码器

短剧/漫剧有一条只给 `bytevc2` 的档位链路。`bytevc2` 是字节自有的
H.266/VVC 类编码,**容器外壳是私有的**(四字码 `bvc2` + 配置盒 `bv2C`,
盒内 NAL 按 4 字节长度前缀打包)。AOSP 不内置 VVC 解码器,media3 到
1.10.0 才认 MP4 里的 VVC 轨道,常见 mpv/ffmpeg 构建也不认这个外壳,所以
Rust 侧的编码门过去把这一档直接丢掉(`CRIT-004`);一集**所有**档都是
`bytevc2` 时,用户看到的就是 issue #466 的「该集暂不支持播放」。

本目录放两件事:

- `0001-add-bvc2-decoder.patch` —— 给 ffmpeg 加 `bvc2` 解码器的补丁
  (来源 [`wxyzh/ffmpeg-bvc2`](https://github.com/wxyzh/ffmpeg-bvc2),
  从 librempeg 移植;做三件事:isom 里把 `bvc2` 四字码映射到
  `AV_CODEC_ID_BVC2`、按 4 字节长度前缀切 NAL,然后整体复用 VVC 解码器)。
- `build.sh` —— 交叉编译脚本,按平台产出自带转码器。

## 为什么不能"改个标签"

`bytevc2` 不是换个四字码就能播的 H.266。实测(ffmpeg 8.1.3 + 本补丁,
用 ffmpeg 8.1.2 编出来的标准 VVC 再造的变体):

| 轨道四字码 + 配置盒 | 原版 ffmpeg | 打补丁后 |
| --- | --- | --- |
| `vvc1` + `vvcC` | 能解 | 能解 |
| `bvc2` + `vvcC` | 不认 | `Invalid NAL unit size` |
| `vvc1` + `bv2C` | 不认 | 不认 |
| `bvc2` + `bv2C` | 不认 | **能解** |

也就是说:外壳与码流必须成对出现,缺一不可。所以要真能播,只有"内置一个
认这套外壳的解码器"这一条路。

## 构建

依赖:`curl`、`tar`、`make`、`pkg-config`(或 `pkgconf`)、C 工具链。
Android 目标另需与 `scripts/build_rust_backend.sh` 同一把 NDK
(`PINNED_NDK_VERSION`),`ANDROID_NDK_HOME` 指向它即可。

```sh
third_party/bytevc2/build.sh host             # 桌面
third_party/bytevc2/build.sh android arm64    # 真机:arm64-v8a
third_party/bytevc2/build.sh android armv7    # 32 位:armeabi-v7a
third_party/bytevc2/build.sh android x86_64   # 模拟器
```

产物:

| 目标 | 位置 |
| --- | --- |
| 桌面 | `build/bytevc2/out/host/bytevc2-ffmpeg`(Windows 带 `.exe`) |
| Android | `android/app/src/main/jniLibs/<abi>/libbvc2transcode.so` |

Android 那条命名是硬要求:应用只能执行自己 `lib/` 下的 `lib*.so`,普通
可执行文件放在 assets 或私有目录都起不来。`jniLibs/*/*.so` 不入库
(`.gitignore`),由本脚本或 CI 重建,和 `libfqapi_core.so` 一个路子。

CI 在编完 Rust core 之后、打 APK 之前对两个 ABI 各跑一次
(`.github/workflows/android-apk.yml` 里的 `Build the bundled bytevc2
transcoder`),产物还会 `test -s` + 搜一遍 `bvc2` 字符串再放行;解压后的
源码树缓存到 `build/bytevc2`,key 跟着 `build.sh` 与补丁文件的哈希走,
所以补丁改了不会复用旧树(旧树会让脚本以为"已经打过补丁"而跳过)。这一步
漏了或失败,包里就没有转码器,客户端只会退回"该集暂不支持播放"。

**光放进 jniLibs 还不够**:AGP 默认把 `jniLibs` 里的 `.so` 直接留在 APK
里(安装时不落盘),那样根本没有可执行的文件。所以 `android/app/build.gradle.kts`
里开了 `packaging { jniLibs { useLegacyPackaging = true } }`,让安装期把原生
库解包到 `applicationInfo.nativeLibraryDir`——转码器从那里 exec
(`Bytevc2TranscodePlugin.kt`)。x86_64 那一档只写进 `jniLibs/x86_64/`;本仓库
的 APK 只打 `arm64-v8a` 与 `armeabi-v7a`,所以它是给本地模拟器/实验用的。

## 用法

`bytevc2` 流是 CENC 加密的,而这里的构建**不带 TLS**(见下),所以输入必须
是已经落到本地磁盘的加密文件:

```sh
bytevc2-ffmpeg -decryption_key <key_hex> -i encrypted.mp4 \
  -map 0:v:0 -map 0:a:0? \
  -c:v libx264 -preset ultrafast -crf 25 -pix_fmt yuv420p \
  -c:a aac -movflags +faststart -y plain_h264.mp4
```

`-decryption_key` 让 ffmpeg 边读边解 CENC;输出是明文 H.264/AAC mp4,
播放侧按"明文离线文件"处理(`keyHex` 为空)即可,与
`lib/services/drama_download_store.dart` 已有的 plain 流路径一致。
不带 key 的明文输入直接去掉 `-decryption_key`。

## 已知边界

- **不带 TLS**:Android 上 ffmpeg 没有可用的 TLS 后端(NDK 只有
  BoringSSL,ffmpeg 不支持),`https` 直拉远端地址不行。要么先落盘再转,
  要么让本地后端做 http 代理。协议只开了 `file,crypto,pipe`。
- **软件编码**:x264 ultrafast。540p 级别一集约几秒;转码期间要给进度和
  取消,别让用户对着黑屏等。
- **许可**:ffmpeg 与本补丁是 GPL,libx264 是 GPL;本仓库是 GPL-3.0,兼容。
