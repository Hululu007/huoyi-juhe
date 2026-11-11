import 'package:flutter_test/flutter_test.dart';

import 'package:fqapp/services/api_client.dart';
import 'package:fqapp/services/playlet_interaction_posting.dart';

void main() {
  group('PlayletInteractionPosting', () {
    test('empty comment is rejected locally without a request', () async {
      var called = false;
      final posting = PlayletInteractionPosting(
        postComment: ({required seriesId, required text}) async {
          called = true;
        },
      );
      final result = await posting.postComment(seriesId: '123', text: '   ');
      expect(result.isOk, isFalse);
      expect(result.message, '评论内容不能为空');
      expect(called, isFalse);
    });

    test('comment success returns ok', () async {
      final calls = <String>[];
      final posting = PlayletInteractionPosting(
        postComment: ({required seriesId, required text}) async {
          calls.add('$seriesId:$text');
        },
      );
      final result = await posting.postComment(
        seriesId: '123',
        text: '  好看  ',
      );
      expect(result.isOk, isTrue);
      expect(calls, ['123:好看']);
    });

    test('401 maps to needsLogin with an explicit prompt', () async {
      final posting = PlayletInteractionPosting(
        postComment: ({required seriesId, required text}) async {
          throw const ApiException('未登录', statusCode: 401);
        },
      );
      final result = await posting.postComment(seriesId: '123', text: '好看');
      expect(result.status, InteractionPostStatus.needsLogin);
      expect(result.message, contains('登录'));
    });

    test('a login word in the server message maps to needsLogin', () async {
      final posting = PlayletInteractionPosting(
        postReply: ({
          required commentId,
          required seriesId,
          required text,
          String replyToReplyId = '',
          String replyToUserId = '',
        }) async {
          throw const ApiException('请先登录后再回复', statusCode: 200);
        },
      );
      final result = await posting.postReply(
        commentId: 'c1',
        seriesId: '123',
        text: '同意',
      );
      expect(result.status, InteractionPostStatus.needsLogin);
    });

    test('other server failures surface the server message', () async {
      final posting = PlayletInteractionPosting(
        postComment: ({required seriesId, required text}) async {
          throw const ApiException('内容含有敏感词', statusCode: 200);
        },
      );
      final result = await posting.postComment(seriesId: '123', text: 'x');
      expect(result.status, InteractionPostStatus.failed);
      expect(result.message, '内容含有敏感词');
    });

    test('danmaku longer than 50 chars is rejected locally', () async {
      var called = false;
      final posting = PlayletInteractionPosting(
        postDanmaku: ({
          required vid,
          required seriesId,
          required text,
          required offsetMs,
        }) async {
          called = true;
        },
      );
      final result = await posting.postDanmaku(
        vid: '1001',
        seriesId: '123',
        text: 'x' * 51,
        offsetMs: 1000,
      );
      expect(result.isOk, isFalse);
      expect(result.message, contains('50'));
      expect(called, isFalse);
    });

    test('danmaku posts with the current playback offset', () async {
      final calls = <Map<String, Object>>[];
      final posting = PlayletInteractionPosting(
        postDanmaku: ({
          required vid,
          required seriesId,
          required text,
          required offsetMs,
        }) async {
          calls.add({
            'vid': vid,
            'seriesId': seriesId,
            'text': text,
            'offsetMs': offsetMs,
          });
        },
      );
      final result = await posting.postDanmaku(
        vid: '1001',
        seriesId: '123',
        text: '前方高能',
        offsetMs: 12345,
      );
      expect(result.isOk, isTrue);
      expect(calls, [
        {
          'vid': '1001',
          'seriesId': '123',
          'text': '前方高能',
          'offsetMs': 12345,
        },
      ]);
    });

    test('login hint is empty when signed in, explicit when not', () {
      expect(
        PlayletInteractionPosting(isSignedIn: () => true).loginHint,
        isEmpty,
      );
      expect(
        PlayletInteractionPosting(isSignedIn: () => false).loginHint,
        contains('未登录'),
      );
    });
  });
}
