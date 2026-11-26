import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// bytevc2 转码验证页（43 轮验证批）：四项逐项真机探测，判读口径见各项注释。
/// 本页只验证「转码器在当前设备上能不能跑」，不接播放链。
class Bytevc2VerifyPage extends StatefulWidget {
const Bytevc2VerifyPage({super.key});

@override
State<Bytevc2VerifyPage> createState() => _Bytevc2VerifyPageState();
}

enum _CheckState { idle, running, pass, fail}

class _CheckResult {
_CheckResult(this.title);
final String title;
_CheckState state = _CheckState.idle;
String detail = '未运行';
}

class _Bytevc2VerifyPageState extends State<Bytevc2VerifyPage> {
static const _channel = MethodChannel('fanrenxiuxian/bytevc2verify');
static const _sampleAsset = 'assets/bytevc2/test_sample.mp4';

final _checks = <_CheckResult>[
_CheckResult('① 转码器落盘（原生库目录里有真实文件）'),
_CheckResult('② 直接 exec 转码器（跑 -version）'),
_CheckResult('③ linker64 拉起转码器（跑 -version）'),
_CheckResult('④ 最小真转码（样本转 H.264 输出）'),
];
bool _running = false;

Future<void> _runAll() async {
if (_running) return;
setState(() {
_running = true;
for (final c in _checks) {
c.state = _CheckState.idle;
c.detail = '等待中';
}
});
try {
await _runInspect();
await _runVersion(1, 'runDirect');
await _runVersion(2, 'runLinker');
await _runMiniTranscode();
} finally {
if (mounted) setState(() => _running = false);
}
}

void _set(int index, _CheckState state, String detail) {
if (!mounted) return;
setState(() {
_checks[index].state = state;
_checks[index].detail = detail;
});
}

/// ① 落盘：legacy packaging 打开后，安装期应把 libbvc2transcode.so 解包到
/// nativeLibraryDir。文件不存在或大小为 0 即判失败——后面三项无从谈起。
Future<void> _runInspect() async {
_set(0, _CheckState.running, '查询中…');
try {
final r = await _channel.invokeMapMethod<String, dynamic>('inspect');
final dir = r?['nativeLibraryDir']?? '(未知)';
final path = r?['path']?? '(未知)';
final exists = r?['exists'] == true;
final size = (r?['size'] as num?)?.toInt()?? 0;
final canExec = r?['canExecute'] == true;
final detail =
'原生库目录：$dir\n文件：$path\n存在：$exists 大小：$size 字节 可执行：$canExec';
_set(0, exists && size > 0? _CheckState.pass: _CheckState.fail, detail);
} catch (e) {
_set(0, _CheckState.fail, '查询失败：$e');
}
}

/// ②/③ 能跑：退出码 0 且输出含 ffmpeg version 字样才算通；原文摘要照显。
Future<void> _runVersion(int index, String method) async {
_set(index, _CheckState.running, '运行中…');
try {
final r = await _channel.invokeMapMethod<String, dynamic>(method);
final ok = r?['ok'] == true;
final exit = r?['exitCode'];
final output = (r?['output']?? '').toString();
final summary = output.length > 600
? '${output.substring(0, 600)}…'
: output;
_set(
index,
ok? _CheckState.pass: _CheckState.fail,
'退出码：$exit\n输出摘要：\n$summary',
);
} catch (e) {
_set(index, _CheckState.fail, '运行失败：$e');
}
}

/// ④ 真转码：内置样本（64x64、0.5 秒、H.264+AAC）写到临时目录后走插件
/// transcode（与正式链同款参数：libx264 ultrafast + AAC + faststart）。
/// 输出文件存在、大小 > 0 且含 ftyp 文件头才算通。
Future<void> _runMiniTranscode() async {
_set(3, _CheckState.running, '准备样本并转码中…');
Directory? dir;
try {
dir = await Directory.systemTemp.createTemp('bytevc2_verify_');
final data = await rootBundle.load(_sampleAsset);
final input = File('${dir.path}/sample.mp4');
await input.writeAsBytes(
data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
);
final outputPath = '${dir.path}/sample.h264.mp4';
await _channel.invokeMethod<String>('transcode', {
'input': input.path,
'output': outputPath,
'keyHex': '',
'timeoutMs': 120000,
});
final out = File(outputPath);
final exists = await out.exists();
final size = exists? await out.length(): 0;
var hasFtyp = false;
if (exists && size >= 8) {
final head = await out.openRead(0, 12).first;
hasFtyp = String.fromCharCodes(head).contains('ftyp');
}
_set(
3,
exists && size > 0 && hasFtyp
? _CheckState.pass
: _CheckState.fail,
'输入：${input.path}（${await input.length()} 字节）\n'
'输出：$outputPath\n存在：$exists 大小：$size 字节 ftyp 文件头：$hasFtyp',
);
} catch (e) {
_set(3, _CheckState.fail, '转码失败：$e');
} finally {
try {
await dir?.delete(recursive: true);
} catch (_) {}
}
}

String _summaryText() {
final b = StringBuffer()
..writeln('bytevc2 转码验证结果')
..writeln('时间：${DateTime.now()}');
for (final c in _checks) {
final mark = switch (c.state) {
_CheckState.pass => '通过',
_CheckState.fail => '失败',
_CheckState.running => '运行中',
_CheckState.idle => '未运行',
};
b
..writeln('')
..writeln('${c.title} $mark')
..writeln(c.detail);
}
return b.toString();
}

Future<void> _copyAll() async {
await Clipboard.setData(ClipboardData(text: _summaryText()));
if (!mounted) return;
ScaffoldMessenger.of(
context,
).showSnackBar(const SnackBar(content: Text('验证结果已复制')));
}

@override
Widget build(BuildContext context) {
return Scaffold(
appBar: AppBar(title: const Text('bytevc2 转码验证')),
body: ListView(
padding: const EdgeInsets.all(16),
children: [
const Text(
'验证随包转码器（libbvc2transcode.so）在本机能不能真跑：'
'落盘、直接执行、linker64 拉起、最小真转码，四项全过才算这条转码链在本机可用。',
),
const SizedBox(height: 16),
for (final c in _checks)...[
Card(
child: Padding(
padding: const EdgeInsets.all(12),
child: Column(
crossAxisAlignment: CrossAxisAlignment.start,
children: [
Row(
children: [
Icon(
switch (c.state) {
_CheckState.pass => Icons.check_circle,
_CheckState.fail => Icons.cancel,
_CheckState.running => Icons.hourglass_top,
_CheckState.idle => Icons.circle_outlined,
},
color: switch (c.state) {
_CheckState.pass => Colors.green,
_CheckState.fail => Colors.red,
_ => null,
},
),
const SizedBox(width: 8),
Expanded(child: Text(c.title)),
],
),
const SizedBox(height: 8),
SelectableText(
c.detail,
style: Theme.of(context).textTheme.bodySmall,
),
],
),
),
),
const SizedBox(height: 8),
],
const SizedBox(height: 8),
FilledButton(
onPressed: _running? null: _runAll,
child: Text(_running? '验证中…': '开始验证'),
),
const SizedBox(height: 8),
OutlinedButton(
onPressed: _copyAll,
child: const Text('复制全部结果'),
),
],
),
);
}
}
