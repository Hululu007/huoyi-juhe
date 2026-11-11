import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/models/comment_reply.dart';
import 'package:fqapp/models/playlet_comment.dart';
import 'package:fqapp/services/playlet_interaction_posting.dart';
import 'package:fqapp/widgets/player/playlet_comment_panel.dart';
import 'package:fqapp/widgets/player/playlet_reply_panel.dart';

void main() {
  const comment = PlayletComment(
    id: 'c1',
    text: '剧情讨论',
    userName: '小明',
    diggCount: 3,
    replyCount: 2,
  );

  group('comment panel posting', () {
    testWidgets('posting a comment refreshes the list', (tester) async {
      final posted = <String>[];
      var loads = 0;
      final poster = PlayletInteractionPosting(
        postComment: ({required seriesId, required text}) async {
          posted.add('$seriesId:$text');
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayletCommentPanel(
              seriesId: '123',
              poster: poster,
              loader:
                  ({
                    required sort,
                    required count,
                    required cursor,
                    required tag,
                  }) async {
                    loads++;
                    return const PlayletCommentPage(
                      comments: [comment],
                      totalCount: 1,
                    );
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 1);
      await tester.enterText(
        find.byKey(const ValueKey('playlet-composer-field')),
        '好看',
      );
      await tester.tap(find.byKey(const ValueKey('playlet-composer-send')));
      await tester.pumpAndSettle();
      expect(posted, ['123:好看']);
      expect(loads, 2, reason: '发完应重拉列表，让新评论出现');
      expect(find.text('剧情讨论'), findsOneWidget);
    });

    testWidgets('a failed send shows the error in the composer', (
      tester,
    ) async {
      final poster = PlayletInteractionPosting(
        isSignedIn: () => false,
        postComment: ({required seriesId, required text}) async {
          throw Exception('network down');
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayletCommentPanel(
              seriesId: '123',
              poster: poster,
              loader:
                  ({
                    required sort,
                    required count,
                    required cursor,
                    required tag,
                  }) async => const PlayletCommentPage(
                    comments: [comment],
                    totalCount: 1,
                  ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // 未登录先有提示行。
      expect(
        find.byKey(const ValueKey('playlet-composer-login-hint')),
        findsOneWidget,
      );
      await tester.enterText(
        find.byKey(const ValueKey('playlet-composer-field')),
        '好看',
      );
      await tester.tap(find.byKey(const ValueKey('playlet-composer-send')));
      await tester.pumpAndSettle();
      // 失败文案落在输入条上，不静默失败。
      expect(find.text('发评论失败，请稍后重试'), findsOneWidget);
    });
  });

  group('reply panel posting', () {
    testWidgets('posting a reply reloads the reply list', (tester) async {
      final posted = <String>[];
      var loads = 0;
      final poster = PlayletInteractionPosting(
        postReply: ({
          required commentId,
          required seriesId,
          required text,
          String replyToReplyId = '',
          String replyToUserId = '',
        }) async {
          posted.add('$commentId:$text');
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayletReplyPanel(
              seriesId: '123',
              comment: comment,
              onBack: () {},
              poster: poster,
              loader:
                  ({
                    required commentId,
                    required count,
                    required cursor,
                    String refReplyId = '',
                  }) async {
                    loads++;
                    return const CommentReplyPage(
                      replies: [CommentReply(id: 'r1', text: '第一条回复')],
                      totalCount: 1,
                    );
                  },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(loads, 1);
      await tester.enterText(
        find.byKey(const ValueKey('playlet-composer-field')),
        '同意',
      );
      await tester.tap(find.byKey(const ValueKey('playlet-composer-send')));
      await tester.pumpAndSettle();
      expect(posted, ['c1:同意']);
      expect(loads, 2, reason: '发完回复应重拉楼层列表');
    });
  });
}
