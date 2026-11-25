import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 预览槽最小验证（第 3 包第 1 项）：修仙版内嵌播放器 NativePlayer
/// 的画面走 Flutter TextureRegistry 注册的单一 textureId
/// （Kotlin 侧 TextureRegistry.SurfaceProducer / SurfaceTextureEntry，
/// 注册一次、按 id 引用）。这里验 Flutter 层：两个 Texture 组件
/// 共用同一个 textureId 同时挂载，不抛异常、状态一致（同 id、
/// 两处都在树上）。真机上 ExoPlayer 单 Surface 双面出画与否
/// 本机无法定论，回报里标注待手机验。
void main() {
  testWidgets('两个 Texture 组件共用同一 textureId 可同时挂载', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                width: 320,
                height: 180,
                child: Texture(textureId: 42),
              ),
              SizedBox(
                width: 96,
                height: 80,
                child: Texture(textureId: 42),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    final textures = tester.widgetList<Texture>(find.byType(Texture)).toList();
    expect(textures, hasLength(2));
    expect(textures.every((t) => t.textureId == 42), isTrue);
    expect(tester.takeException(), isNull);
    // 尺寸变化重建后仍可共存（预览槽随播放区状态重建的等价场景）。
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Row(
            children: [
              SizedBox(
                width: 160,
                height: 90,
                child: Texture(textureId: 42),
              ),
              SizedBox(
                width: 80,
                height: 80,
                child: Texture(textureId: 42),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(Texture), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });
}
