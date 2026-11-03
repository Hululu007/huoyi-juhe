import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/models/book_detail.dart';
import 'package:fqapp/models/media_item.dart';
import 'package:fqapp/services/reading_envelope.dart';

void main() {
  test('我方信封能被原始版解析器原样读回', () {
    final detail = BookDetail.fromPayload(
      engineDetailEnvelope(
        bookId: 'engine:site-1:book-9',
        title: '测试书',
        cover: 'https://x.com/c.jpg',
        author: '作者',
        serialCount: 12,
        lastChapterTitle: '第12章',
        source: 'engine:site-1',
      ),
    );
    expect(detail.bookId, 'engine:site-1:book-9');
    expect(detail.title, '测试书');
    expect(detail.cover, 'https://x.com/c.jpg');
    expect(detail.serialCount, 12);
    expect(detail.lastChapterTitle, '第12章');

    final chapters = [
      Chapter(itemId: 'flag\u0001ep1', title: '第一章', volumeName: ''),
      Chapter(itemId: 'flag\u0001ep2', title: '第二章', volumeName: ''),
    ];
    final directory = parseDirectory(engineDirectoryEnvelope(chapters));
    expect(directory.length, 1);
    expect(directory.first.length, 2);
    expect(directory.first[0].itemId, 'flag\u0001ep1');
    expect(directory.first[1].title, '第二章');
  });
}
