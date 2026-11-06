import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_content.dart';

void main() {
  test('牛果：首位分类是全部（不带 class 才能拿到内容）', () async {
    final categories = await NiuguoContentClient().categories();
    expect(categories.first.id, '');
    expect(categories.first.name, '全部');
    expect(
      categories.map((c) => c.name).toList(),
      ['全部', '短剧', '电影', '电视剧', '动漫', '综艺'],
    );
  });
}
