import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/home_provider.dart';
import 'package:fqapp/services/drama_site_content.dart';
import 'package:fqapp/services/source_registry.dart';

SourceEntry _entry(
  String id, {
  String? name,
  String? contentType,
  bool enabled = true,
  SourceKind kind = SourceKind.legadoImport,
}) {
  final extra = <String, dynamic>{};
  if (contentType != null) extra['contentType'] = contentType;
  return SourceEntry(
    id: id,
    name: name ?? id,
    kind: kind,
    enabled: enabled,
    extra: extra,
  );
}

void main() {
  test('成人小说与漫画源入选，别的都不进', () {
    final entries = [
      _entry('n1', name: '🔞成人小说源', contentType: 'novel'),
      _entry('c1', name: '🔞成人漫画源', contentType: 'comic'),
      _entry('plain-novel', name: '普通小说源', contentType: 'novel'),
      _entry('adult-video', name: '🔞成人视频源', contentType: 'video'),
      _entry('adult-mixed', name: '🔞成人综合源', contentType: 'mixed'),
      _entry('adult-audio', name: '🔞成人听书源', contentType: 'audio'),
      _entry(
        'adult-novel-off',
        name: '🔞已关成人小说源',
        contentType: 'novel',
        enabled: false,
      ),
    ];
    final picked = adultRecommendSources(entries);
    expect(
      picked.map((entry) => entry.id),
      ['n1', 'c1'],
    );
  });

  test('聚合页按 tab 取源：听书 tab 只取听书源，缺省仍不取听书', () {
    final entries = [
      _entry('n1', name: '🔞成人小说源', contentType: 'novel'),
      _entry('a1', name: '🔞成人听书源', contentType: 'audio'),
      _entry('plain-audio', name: '普通听书源', contentType: 'audio'),
    ];
    expect(
      adultRecommendSources(entries, types: {ContentType.audio})
          .map((entry) => entry.id),
      ['a1'],
    );
    expect(
      adultRecommendSources(entries).map((entry) => entry.id),
      ['n1'],
    );
  });

  test('导入方式不影响入选：py 成人漫画源也入选', () {
    final picked = adultRecommendSources([
      _entry(
        'py-comic',
        name: '🔞py 成人漫画',
        contentType: 'comic',
        kind: SourceKind.pyImport,
      ),
    ]);
    expect(picked.map((entry) => entry.id), ['py-comic']);
  });

  test('推荐卡映射：漫画 kind 为 manga、小说为 book，source 带 engine 前缀', () {
    const item = DramaSiteItem(id: 'b1', title: '成人漫', cover: 'c', remark: '全一册');
    final comic = adultRecommendItem(
      item,
      _entry('c1', name: '🔞成人漫画源', contentType: 'comic'),
    );
    expect(comic.kind, 'manga');
    expect(comic.source, 'engine:c1');
    expect(comic.seriesId, 'b1');
    expect(comic.title, '成人漫');
    expect(comic.ep, '全一册');
    final novel = adultRecommendItem(
      item,
      _entry('n1', name: '🔞成人小说源', contentType: 'novel'),
    );
    expect(novel.kind, 'book');
    expect(novel.source, 'engine:n1');
    final audio = adultRecommendItem(
      item,
      _entry('a1', name: '🔞成人听书源', contentType: 'audio'),
    );
    expect(audio.kind, 'audio');
    expect(audio.source, 'engine:a1');
  });
}
