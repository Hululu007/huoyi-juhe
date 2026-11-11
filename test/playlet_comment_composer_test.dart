import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/widgets/player/playlet_comment_composer.dart';

void main() {
  Future<void> pumpComposer(
    WidgetTester tester, {
    required Future<String?> Function(String text) onSend,
    void Function(String text)? onSent,
    String loginHint = '',
    int maxLength = 0,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: PlayletCommentComposer(
            hintText: '写下你的评论…',
            maxLength: maxLength,
            loginHint: loginHint,
            onSend: onSend,
            onSent: onSent,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('sends trimmed text and clears the field', (tester) async {
    final sent = <String>[];
    final confirmed = <String>[];
    await pumpComposer(
      tester,
      onSend: (text) async {
        sent.add(text);
        return null;
      },
      onSent: confirmed.add,
    );
    await tester.enterText(
      find.byKey(const ValueKey('playlet-composer-field')),
      '  好看  ',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-composer-send')));
    await tester.pumpAndSettle();
    expect(sent, ['好看']);
    expect(confirmed, ['好看']);
    expect(
      find.text('好看'),
      findsNothing,
      reason: '发送成功后输入框应清空',
    );
  });

  testWidgets('empty text is blocked locally and never sends', (tester) async {
    var called = false;
    await pumpComposer(
      tester,
      onSend: (text) async {
        called = true;
        return null;
      },
    );
    await tester.tap(find.byKey(const ValueKey('playlet-composer-send')));
    await tester.pumpAndSettle();
    expect(called, isFalse);
    expect(find.text('内容不能为空'), findsOneWidget);
  });

  testWidgets('a failed send shows the error and keeps the text', (
    tester,
  ) async {
    await pumpComposer(
      tester,
      onSend: (text) async => '请先登录红果账号后再发评论',
    );
    await tester.enterText(
      find.byKey(const ValueKey('playlet-composer-field')),
      '好看',
    );
    await tester.tap(find.byKey(const ValueKey('playlet-composer-send')));
    await tester.pumpAndSettle();
    expect(find.text('请先登录红果账号后再发评论'), findsOneWidget);
    expect(find.text('好看'), findsOneWidget);
  });

  testWidgets('login hint shows when not signed in', (tester) async {
    await pumpComposer(
      tester,
      loginHint: '未登录红果账号，发送失败时会提示登录',
      onSend: (text) async => null,
    );
    expect(find.text('未登录红果账号，发送失败时会提示登录'), findsOneWidget);
  });
}
