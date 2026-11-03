import '../models/media_item.dart';

Map<String, dynamic> engineDetailEnvelope({
  required String bookId,
  required String title,
  required String cover,
  String author = '',
  String abstract = '',
  int serialCount = 0,
  String lastChapterTitle = '',
  String source = '',
}) {
  return {
    'data': {
      'book_id': bookId,
      'book_name': title,
      'author': author,
      'abstract': abstract,
      'thumb_url': cover,
      'serial_count': serialCount,
      'last_chapter_title': lastChapterTitle,
      'source': source,
    },
  };
}

Map<String, dynamic> engineDirectoryEnvelope(List<Chapter> chapters) {
  return {
    'data': {
      'data': {
        'chapterListWithVolume': [
          {
            'volume_name': '',
            'chapterList': [
              for (final chapter in chapters)
                {
                  'itemId': chapter.itemId,
                  'title': chapter.title,
                  'volume_name': chapter.volumeName,
                },
            ],
          },
        ],
      },
    },
  };
}
