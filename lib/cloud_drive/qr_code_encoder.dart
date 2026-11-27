/// 纯 Dart 二维码编码器：字节模式、纠错等级 M、版本 1–10。
///
/// 树里没有二维码生成依赖（也不能新增依赖），本实现按 ISO/IEC 18004
/// 标准从头写：数据编码 → Reed-Solomon 纠错 → 交织 → 功能图形 →
/// 掩码评估。参数表（容量、纠错块结构、对齐图位置）取自标准附录，
/// 已用 Python segno 参考实现逐比特比对验证（见 test/qr_vectors.json）。
///
/// 只支持字节模式（网盘扫码登录的二维码内容全是 URL 字符串，够用）。
/// 内容超过 V10 容量（213 字节）时抛 [ArgumentError]，调用方改走
/// “显示链接 + 复制”兜底，不许静默截断。
library;

/// 编码结果：模块矩阵（true=深色）+ 实际版本 + 实际掩码。
class QrCodeResult {
  const QrCodeResult({
    required this.modules,
    required this.version,
    required this.mask,
  });

  /// 行优先矩阵，`modules[row][col]`，不含空白边（调用方自行留白）。
  final List<List<bool>> modules;
  final int version;
  final int mask;

  int get size => modules.length;
}

/// 每版本数据容量（比特），纠错等级 M，ISO/IEC 18004 表 7。
const _dataCapacityBits = <int>[
  0, // 占位，版本从 1 起
  128, 224, 352, 512, 688, 864, 992, 1232, 1456, 1728,
];

/// 纠错块结构：每版本一组 (块数, 每块总码字数, 每块数据码字数)。
/// ISO/IEC 18004 表 9，纠错等级 M。
const _ecBlocks = <List<List<int>>>[
  [], // 占位
  [
    [1, 26, 16],
  ],
  [
    [1, 44, 28],
  ],
  [
    [1, 70, 44],
  ],
  [
    [2, 50, 32],
  ],
  [
    [2, 67, 43],
  ],
  [
    [4, 43, 27],
  ],
  [
    [4, 49, 31],
  ],
  [
    [2, 60, 38],
    [2, 61, 39],
  ],
  [
    [3, 58, 36],
    [2, 59, 37],
  ],
  [
    [4, 69, 43],
    [1, 70, 44],
  ],
];

/// 对齐图中心坐标，ISO/IEC 18004 附录 E 表 E.1（版本 1 无对齐图）。
const _alignmentPositions = <List<int>>[
  [],
  [],
  [6, 18],
  [6, 22],
  [6, 26],
  [6, 30],
  [6, 34],
  [6, 22, 38],
  [6, 24, 42],
  [6, 26, 46],
  [6, 28, 50],
];

/// 编码 [content]（UTF-8 字节）为二维码矩阵。
///
/// [fixedMask] 仅测试用：固定掩码以便与参考实现逐比特比对；
/// 正常调用传 null，走标准四条惩罚规则选最优掩码。
QrCodeResult encodeQrCode(String content, {int? fixedMask}) {
  final bytes = _utf8Bytes(content);
  final version = _selectVersion(bytes.length);
  final countBits = version <= 9 ? 8 : 16;
  final dataCodewords = _buildDataCodewords(bytes, version, countBits);
  final allCodewords = _addErrorCorrection(dataCodewords, version);
  final size = 17 + 4 * version;
  final function = _buildFunctionPatterns(size, version);
  List<List<bool>>? bestModules;
  var bestPenalty = 1 << 30;
  var bestMask = 0;
  final masks = fixedMask != null ? [fixedMask] : const [0, 1, 2, 3, 4, 5, 6, 7];
  for (final mask in masks) {
    final modules = _placeData(allCodewords, size, function);
    _applyMask(modules, function, mask);
    // 掩码评估在格式/版本信息填入之前做（与参考实现一致）：
    // 评估时格式/版本区按掩码后的伪值计分，选定掩码后再覆盖真值。
    final penalty = fixedMask != null ? 0 : _penalty(modules);
    if (penalty < bestPenalty) {
      bestPenalty = penalty;
      bestModules = modules;
      bestMask = mask;
    }
  }
  final modules = bestModules!;
  _placeFormatInfo(modules, size, bestMask);
  if (version >= 7) _placeVersionInfo(modules, size, version);
  return QrCodeResult(
    modules: modules,
    version: version,
    mask: bestMask,
  );
}

List<int> _utf8Bytes(String content) {
  // 不引 dart:convert 的编解码器以外的东西：手动 UTF-8 编码，
  // 避免对 content 做任何规范化（二维码内容必须原样）。
  final units = content.codeUnits;
  final out = <int>[];
  var i = 0;
  while (i < units.length) {
    var cp = units[i++];
    if (cp >= 0xD800 && cp <= 0xDBFF && i < units.length) {
      final lo = units[i];
      if (lo >= 0xDC00 && lo <= 0xDFFF) {
        i++;
        cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
      }
    }
    if (cp < 0x80) {
      out.add(cp);
    } else if (cp < 0x800) {
      out.add(0xC0 | (cp >> 6));
      out.add(0x80 | (cp & 0x3F));
    } else if (cp < 0x10000) {
      out.add(0xE0 | (cp >> 12));
      out.add(0x80 | ((cp >> 6) & 0x3F));
      out.add(0x80 | (cp & 0x3F));
    } else {
      out.add(0xF0 | (cp >> 18));
      out.add(0x80 | ((cp >> 12) & 0x3F));
      out.add(0x80 | ((cp >> 6) & 0x3F));
      out.add(0x80 | (cp & 0x3F));
    }
  }
  return out;
}

int _selectVersion(int byteLength) {
  for (var version = 1; version <= 10; version++) {
    final countBits = version <= 9 ? 8 : 16;
    final needed = 4 + countBits + byteLength * 8;
    if (needed <= _dataCapacityBits[version]) return version;
  }
  throw ArgumentError('内容过长（$byteLength 字节），超出二维码 V10 容量（213 字节）');
}

List<int> _buildDataCodewords(List<int> bytes, int version, int countBits) {
  final capacity = _dataCapacityBits[version];
  final bits = <bool>[];
  void put(int value, int length) {
    for (var i = length - 1; i >= 0; i--) {
      bits.add(((value >> i) & 1) == 1);
    }
  }

  put(4, 4); // 字节模式指示符 0100
  put(bytes.length, countBits);
  for (final byte in bytes) {
    put(byte, 8);
  }
  // 终止符：最多 4 个 0，不足则有多少补多少。
  final terminator = capacity - bits.length;
  for (var i = 0; i < terminator && i < 4; i++) {
    bits.add(false);
  }
  // 补齐到码字边界：与参考实现一致，只要还有剩余容量就补满
  // `8 - (长度 % 8)` 个 0（已对齐时也补一整字节 0，解码时忽略，
  // 不影响内容，只影响填充码字的对齐位置）。
  if (bits.length < capacity) {
    final padBits = 8 - (bits.length % 8);
    for (var i = 0; i < padBits; i++) {
      bits.add(false);
    }
  }
  // 填充码字 0xEC / 0x11 交替。
  final codewords = <int>[];
  for (var i = 0; i < bits.length; i += 8) {
    var value = 0;
    for (var j = 0; j < 8; j++) {
      if (bits[i + j]) value |= 1 << (7 - j);
    }
    codewords.add(value);
  }
  final total = capacity ~/ 8;
  var pad = 0xEC;
  while (codewords.length < total) {
    codewords.add(pad);
    pad = pad == 0xEC ? 0x11 : 0xEC;
  }
  return codewords;
}

// --- Reed-Solomon（GF(2^8)，本原多项式 0x11D）-------------------------------

final _gfExp = List<int>.filled(512, 0);
final _gfLog = List<int>.filled(256, 0);
bool _gfReady = false;

void _initGalois() {
  if (_gfReady) return;
  var x = 1;
  for (var i = 0; i < 255; i++) {
    _gfExp[i] = x;
    _gfLog[x] = i;
    x <<= 1;
    if (x & 0x100 != 0) x ^= 0x11D;
  }
  for (var i = 255; i < 512; i++) {
    _gfExp[i] = _gfExp[i - 255];
  }
  _gfReady = true;
}

int _gfMul(int a, int b) {
  if (a == 0 || b == 0) return 0;
  return _gfExp[_gfLog[a] + _gfLog[b]];
}

/// 生成多项式：∏(x − α^i)，i = 0..degree-1（GF 中减法即加法）。
List<int> _generatorPoly(int degree) {
  var poly = <int>[1];
  for (var i = 0; i < degree; i++) {
    final next = List<int>.filled(poly.length + 1, 0);
    for (var j = 0; j < poly.length; j++) {
      next[j] ^= poly[j];
      next[j + 1] ^= _gfMul(poly[j], _gfExp[i]);
    }
    poly = next;
  }
  return poly;
}

List<int> _rsRemainder(List<int> data, int degree) {
  final gen = _generatorPoly(degree);
  final remainder = List<int>.filled(degree, 0);
  for (final byte in data) {
    final factor = byte ^ remainder[0];
    for (var j = 0; j < degree - 1; j++) {
      remainder[j] = remainder[j + 1];
    }
    remainder[degree - 1] = 0;
    for (var j = 0; j < degree; j++) {
      remainder[j] ^= _gfMul(gen[j + 1], factor);
    }
  }
  return remainder;
}

List<int> _addErrorCorrection(List<int> dataCodewords, int version) {
  _initGalois();
  final blocks = <List<int>>[];
  final ecBlocks = <List<int>>[];
  var offset = 0;
  var ecLength = 0;
  for (final group in _ecBlocks[version]) {
    final count = group[0];
    final total = group[1];
    final dataLen = group[2];
    ecLength = total - dataLen;
    for (var b = 0; b < count; b++) {
      final block = dataCodewords.sublist(offset, offset + dataLen);
      offset += dataLen;
      blocks.add(block);
      ecBlocks.add(_rsRemainder(block, ecLength));
    }
  }
  // 交织：先按列交织数据码字（短块缺失的末位跳过），再交织纠错码字。
  final out = <int>[];
  final maxData = blocks.map((b) => b.length).reduce((a, b) => a > b ? a : b);
  for (var i = 0; i < maxData; i++) {
    for (final block in blocks) {
      if (i < block.length) out.add(block[i]);
    }
  }
  for (var i = 0; i < ecLength; i++) {
    for (final block in ecBlocks) {
      out.add(block[i]);
    }
  }
  return out;
}

// --- 矩阵与功能图形 ---------------------------------------------------------

/// 功能图形矩阵：true=该模块是功能图形（不放数据、不掩码）。
/// 返回 (modules, isFunction) 的记录。
///
/// [reserved] 是格式/版本信息预留位：放数据时跳过，但掩码评估时
/// 按数据区对待（与参考实现一致），选定掩码后再填真值。
({List<List<bool>> modules, List<List<bool>> isFunction, List<List<bool>> reserved})
_buildFunctionPatterns(
  int size,
  int version,
) {
  final modules = List.generate(size, (_) => List<bool>.filled(size, false));
  final isFunction = List.generate(size, (_) => List<bool>.filled(size, false));
  final reserved = List.generate(size, (_) => List<bool>.filled(size, false));
  void setFunction(int row, int col, bool dark) {
    modules[row][col] = dark;
    isFunction[row][col] = true;
  }

  void setReserved(int row, int col) {
    isFunction[row][col] = true;
    reserved[row][col] = true;
  }

  // 定位图（三个角，7×7）+ 分隔符。
  void finder(int topRow, int leftCol) {
    for (var dr = -1; dr <= 7; dr++) {
      for (var dc = -1; dc <= 7; dc++) {
        final r = topRow + dr;
        final c = leftCol + dc;
        if (r < 0 || r >= size || c < 0 || c >= size) continue;
        final dark =
            (dr >= 0 && dr <= 6 && (dc == 0 || dc == 6)) ||
            (dc >= 0 && dc <= 6 && (dr == 0 || dr == 6)) ||
            (dr >= 2 && dr <= 4 && dc >= 2 && dc <= 4);
        setFunction(r, c, dark);
      }
    }
  }

  finder(0, 0);
  finder(0, size - 7);
  finder(size - 7, 0);

  // 时钟图（第 6 行/列，跳过定位图区域）。
  for (var i = 0; i < size; i++) {
    final dark = i % 2 == 0;
    if (!isFunction[6][i]) setFunction(6, i, dark);
    if (!isFunction[i][6]) setFunction(i, 6, dark);
  }

  // 对齐图（5×5）。只跳过与三个定位图重叠的角落组合；中心压在
  // 时钟图上的对齐图照样要画（会覆盖时钟模块），不能跳过。
  final align = _alignmentPositions[version];
  for (var i = 0; i < align.length; i++) {
    for (var j = 0; j < align.length; j++) {
      if ((i == 0 && j == 0) ||
          (i == 0 && j == align.length - 1) ||
          (i == align.length - 1 && j == 0)) {
        continue;
      }
      final r = align[i];
      final c = align[j];
      for (var dr = -2; dr <= 2; dr++) {
        for (var dc = -2; dc <= 2; dc++) {
          final dark = dr == -2 ||
              dr == 2 ||
              dc == -2 ||
              dc == 2 ||
              (dr == 0 && dc == 0);
          setFunction(r + dr, c + dc, dark);
        }
      }
    }
  }

  // 格式信息预留位（真正的值在掩码选定后填）。
  for (var i = 0; i < 6; i++) {
    setReserved(8, i);
    setReserved(i, 8);
  }
  setReserved(8, 7);
  setReserved(8, 8);
  setReserved(7, 8);
  for (var i = 0; i < 8; i++) {
    setReserved(8, size - 1 - i);
    setReserved(size - 1 - i, 8);
  }
  // 深色模块：恒深色，不是格式预留位，掩码评估时不翻转。
  setFunction(size - 8, 8, true);
  reserved[size - 8][8] = false;

  // 版本信息预留位（V≥7）。
  if (version >= 7) {
    for (var i = 0; i < 18; i++) {
      final a = size - 11 + i % 3;
      final b = i ~/ 3;
      setReserved(b, a);
      setReserved(a, b);
    }
  }
  return (modules: modules, isFunction: isFunction, reserved: reserved);
}

List<List<bool>> _placeData(
  List<int> codewords,
  int size,
  ({
    List<List<bool>> modules,
    List<List<bool>> isFunction,
    List<List<bool>> reserved,
  }) function,
) {
  final modules = [
    for (final row in function.modules) [...row],
  ];
  final isFunction = function.isFunction;
  var bitIndex = 0;
  final totalBits = codewords.length * 8;
  for (var right = size - 1; right >= 1; right -= 2) {
    if (right == 6) right = 5;
    final upward = ((right + 1) & 2) == 0;
    for (var vert = 0; vert < size; vert++) {
      for (var j = 0; j < 2; j++) {
        final col = right - j;
        final row = upward ? size - 1 - vert : vert;
        if (isFunction[row][col]) continue;
        if (bitIndex >= totalBits) continue;
        final bit = (codewords[bitIndex >> 3] >> (7 - (bitIndex & 7))) & 1;
        modules[row][col] = bit == 1;
        bitIndex++;
      }
    }
  }
  return modules;
}

bool _maskBit(int mask, int row, int col) {
  switch (mask) {
    case 0:
      return (row + col) % 2 == 0;
    case 1:
      return row % 2 == 0;
    case 2:
      return col % 3 == 0;
    case 3:
      return (row + col) % 3 == 0;
    case 4:
      return (row ~/ 2 + col ~/ 3) % 2 == 0;
    case 5:
      return (row * col) % 2 + (row * col) % 3 == 0;
    case 6:
      return ((row * col) % 2 + (row * col) % 3) % 2 == 0;
    case 7:
      return ((row + col) % 2 + (row * col) % 3) % 2 == 0;
    default:
      throw ArgumentError('掩码必须是 0–7');
  }
}

void _applyMask(
  List<List<bool>> modules,
  ({
    List<List<bool>> modules,
    List<List<bool>> isFunction,
    List<List<bool>> reserved,
  }) function,
  int mask,
) {
  final size = modules.length;
  for (var row = 0; row < size; row++) {
    for (var col = 0; col < size; col++) {
      // 格式/版本预留位在评估阶段按数据区掩码，选定后再覆盖真值。
      if (function.isFunction[row][col] && !function.reserved[row][col]) {
        continue;
      }
      if (_maskBit(mask, row, col)) modules[row][col] = !modules[row][col];
    }
  }
}

void _placeFormatInfo(List<List<bool>> modules, int size, int mask) {
  // 格式信息：5 位数据（纠错等级 M=00 + 掩码）→ BCH(15,5) → 异或掩码 0x5412。
  const ecBits = 0; // M
  final data = (ecBits << 3) | mask;
  var rem = data;
  for (var i = 0; i < 10; i++) {
    rem = (rem << 1) ^ ((rem >> 9) * 0x537);
  }
  final bits = ((data << 10) | rem) ^ 0x5412;
  bool bit(int i) => ((bits >> i) & 1) == 1;

  for (var i = 0; i <= 5; i++) {
    modules[i][8] = bit(i);
  }
  modules[7][8] = bit(6);
  modules[8][8] = bit(7);
  modules[8][7] = bit(8);
  for (var i = 9; i < 15; i++) {
    modules[8][14 - i] = bit(i);
  }
  for (var i = 0; i < 8; i++) {
    modules[8][size - 1 - i] = bit(i);
  }
  for (var i = 8; i < 15; i++) {
    modules[size - 15 + i][8] = bit(i);
  }
}

void _placeVersionInfo(List<List<bool>> modules, int size, int version) {
  // 版本信息：6 位版本号 → BCH(18,6)，生成多项式 0x1F25。
  var rem = version;
  for (var i = 0; i < 12; i++) {
    rem = (rem << 1) ^ ((rem >> 11) * 0x1F25);
  }
  final bits = (version << 12) | rem;
  for (var i = 0; i < 18; i++) {
    final dark = ((bits >> i) & 1) == 1;
    final a = size - 11 + i % 3;
    final b = i ~/ 3;
    modules[b][a] = dark;
    modules[a][b] = dark;
  }
}

// --- 掩码惩罚规则 -----------------------------------------------------------

int _penalty(List<List<bool>> modules) {
  final size = modules.length;
  var penalty = 0;
  // 规则 1：同色连续 5 个以上，每行/列：3 + (长度 - 5)。
  for (var i = 0; i < size; i++) {
    penalty += _runPenalty([for (var j = 0; j < size; j++) modules[i][j]]);
    penalty += _runPenalty([for (var j = 0; j < size; j++) modules[j][i]]);
  }
  // 规则 2：2×2 同色块，每块 3 分。
  for (var r = 0; r < size - 1; r++) {
    for (var c = 0; c < size - 1; c++) {
      final v = modules[r][c];
      if (v == modules[r][c + 1] &&
          v == modules[r + 1][c] &&
          v == modules[r + 1][c + 1]) {
        penalty += 3;
      }
    }
  }
  // 规则 3：1:1:3:1:1 模式（1011101），位于边缘、或前后 4 格内
  // 全浅色时计 40 分；不命中的从 idx+4 处继续找（允许部分重叠）。
  for (var i = 0; i < size; i++) {
    penalty += _n3Occurrences([for (var j = 0; j < size; j++) modules[i][j]]);
    penalty += _n3Occurrences([for (var j = 0; j < size; j++) modules[j][i]]);
  }
  // 规则 4：深色占比偏离 50%，每偏 5% 计 10 分（整数运算，不用浮点）。
  var dark = 0;
  for (final row in modules) {
    for (final v in row) {
      if (v) dark++;
    }
  }
  final total = size * size;
  final deviation = (dark * 100 - 50 * total).abs();
  penalty += 10 * (deviation ~/ (5 * total));
  return penalty;
}

/// 规则 3 在一条线上（行或列）的命中次数。
int _n3Occurrences(List<bool> line) {
  const pattern = [true, false, true, true, true, false, true];
  final size = line.length;
  var count = 0;
  var start = 0;
  while (true) {
    final idx = _findPattern(line, pattern, start);
    if (idx < 0) break;
    final offset = idx + 7;
    final beforeLight = _allLight(line, idx - 4 < 0 ? 0 : idx - 4, idx);
    final afterLight = _allLight(line, offset, offset + 4 > size ? size : offset + 4);
    if (idx == 0 || idx == size - 7 || beforeLight || afterLight) {
      count += 40;
      start = offset;
    } else {
      start = idx + 4;
    }
  }
  return count;
}

int _findPattern(List<bool> line, List<bool> pattern, int start) {
  for (var i = start; i <= line.length - pattern.length; i++) {
    var match = true;
    for (var k = 0; k < pattern.length; k++) {
      if (line[i + k] != pattern[k]) {
        match = false;
        break;
      }
    }
    if (match) return i;
  }
  return -1;
}

/// [line] 在 [from]（含）到 [to]（不含）之间是否全浅色；空区间算全浅色。
bool _allLight(List<bool> line, int from, int to) {
  for (var i = from; i < to; i++) {
    if (line[i]) return false;
  }
  return true;
}

int _runPenalty(List<bool> line) {
  var penalty = 0;
  var run = 1;
  for (var i = 1; i < line.length; i++) {
    if (line[i] == line[i - 1]) {
      run++;
    } else {
      if (run >= 5) penalty += 3 + (run - 5);
      run = 1;
    }
  }
  if (run >= 5) penalty += 3 + (run - 5);
  return penalty;
}

