/// 二维码图控件：用本机二维码编码器画内容矩阵（不依赖任何二维码包）。
library;

import 'package:flutter/material.dart';

import 'qr_code_encoder.dart';

/// 二维码图：白底黑块，四周留 4 个模块的空白边。
/// 内容超长编不出来时显示 [fallback]（调用方给“显示链接+复制”兜底）。
class QrCodeWidget extends StatelessWidget {
  const QrCodeWidget({
    super.key,
    required this.content,
    required this.size,
    this.fallback,
  });

  final String content;
  final double size;
  final Widget? fallback;

  @override
  Widget build(BuildContext context) {
    QrCodeResult result;
    try {
      result = encodeQrCode(content);
    } catch (_) {
      return fallback ?? const SizedBox.shrink();
    }
    return Container(
      width: size,
      height: size,
      color: Colors.white,
      child: CustomPaint(
        painter: _QrCodePainter(result.modules),
      ),
    );
  }
}

class _QrCodePainter extends CustomPainter {
  _QrCodePainter(this.modules);

  final List<List<bool>> modules;

  @override
  void paint(Canvas canvas, Size size) {
    final count = modules.length;
    const quiet = 4;
    final total = count + quiet * 2;
    final cell = size.width / total;
    final paint = Paint()..color = Colors.black;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (!modules[row][col]) continue;
        canvas.drawRect(
          Rect.fromLTWH(
            (col + quiet) * cell,
            (row + quiet) * cell,
            cell,
            cell,
          ),
          paint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(_QrCodePainter oldDelegate) =>
      oldDelegate.modules != modules;
}
