// 演员头像归并纯函数测试（2026-11-24 头像取错修复，由魔蚁版移植）。
//
// 背景：新合并的女优库里同名有多行，波多野結衣、森沢かな各有一行
// avatar 只有裸域名 https://v.hersav.me/（无路径、加载不到），另一行
// 才是完整头像；汇总表按行序取第一个非空 avatar，裸域名行在前就赢
// 了，列表上这些人只剩首字圆圈。修法：归并只接受“像能加载”的地址。
//
// sqflite 在 flutter test 里打不开真库（见
// actress_video_library_db_test.dart 头注释——修仙版树里无此文件，
// 同理：无 sqflite_common_ffi，pub.dev 不可达），这里只测归并决策
// 本身；回退 SQL 的端到端重放见工作目录 verify_fallback_sql.py
// （sqlite3 跑 Dart 里的 SQL 原文）。
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/actress_models.dart';

const _bare = 'https://v.hersav.me/';
const _bareNoSlash = 'https://v.hersav.me';
const _fullHersav =
    'https://v.hersav.me/actress/avatar/a47b84f1def9a228b67122d7568362ff_hd.jpg';
const _fullJdb = 'https://c0.jdbstatic.com/avatars/e2/E2Z3M.jpg';

void main() {
  group('isLoadableAvatarUrl', () {
    test('空地址不能加载', () {
      expect(isLoadableAvatarUrl(''), isFalse);
      expect(isLoadableAvatarUrl('   '), isFalse);
    });

    test('裸域名不能加载（带斜杠与不带斜杠）', () {
      expect(isLoadableAvatarUrl(_bare), isFalse);
      expect(isLoadableAvatarUrl(_bareNoSlash), isFalse);
      expect(isLoadableAvatarUrl('https://v.hersav.me/?x=1'), isFalse);
    });

    test('带路径的完整地址能加载', () {
      expect(isLoadableAvatarUrl(_fullHersav), isTrue);
      expect(isLoadableAvatarUrl(_fullJdb), isTrue);
      expect(isLoadableAvatarUrl('https://example.com/a.jpg'), isTrue);
      expect(
        isLoadableAvatarUrl('https://example.com/a.jpg?x=1'),
        isTrue,
      );
    });

    test('非 http(s)、相对地址、垃圾串不能加载', () {
      expect(isLoadableAvatarUrl('ftp://example.com/a.jpg'), isFalse);
      expect(isLoadableAvatarUrl('/relative/path.jpg'), isFalse);
      expect(isLoadableAvatarUrl('not_a_url'), isFalse);
      expect(isLoadableAvatarUrl('https://'), isFalse);
    });

    test('首尾空白不影响判断', () {
      expect(isLoadableAvatarUrl('  $_fullJdb  '), isTrue);
      expect(isLoadableAvatarUrl('  $_bare  '), isFalse);
    });
  });

  group('preferLoadableAvatar', () {
    test('现有为空、新候选有效时取新候选', () {
      expect(preferLoadableAvatar('', _fullHersav), _fullHersav);
    });

    test('现有是裸域名、新候选有效时取新候选', () {
      expect(preferLoadableAvatar(_bare, _fullHersav), _fullHersav);
      expect(preferLoadableAvatar(_bareNoSlash, _fullJdb), _fullJdb);
    });

    test('现有已有效时保留现有（先到先得）', () {
      expect(preferLoadableAvatar(_fullHersav, _bare), _fullHersav);
      expect(preferLoadableAvatar(_fullHersav, _fullJdb), _fullHersav);
    });

    test('两个都无效时保留现有', () {
      expect(preferLoadableAvatar(_bare, ''), _bare);
      expect(preferLoadableAvatar('', _bare), '');
      expect(preferLoadableAvatar('', ''), '');
    });
  });

  group('汇总归并循环（与 _ensureVideoRollup 同一套走法）', () {
    // 与汇总表里完全相同的累加：acc 从空开始，按行序逐行归并。
    String mergeRows(List<String> avatarsInRowidOrder) {
      var acc = '';
      for (final avatar in avatarsInRowidOrder) {
        acc = preferLoadableAvatar(acc, avatar);
      }
      return acc;
    }

    test('裸域名行在前、完整头像行在后：取完整头像', () {
      expect(mergeRows([_bare, _fullHersav]), _fullHersav);
    });

    test('完整头像行在前、裸域名行在后：保留完整头像', () {
      expect(mergeRows([_fullHersav, _bare]), _fullHersav);
    });

    test('空行 + 完整行：取完整头像', () {
      expect(mergeRows(['', _fullJdb]), _fullJdb);
    });

    test('只有裸域名行：留空（列表画圆圈就是对的）', () {
      expect(mergeRows([_bare]), '');
      expect(mergeRows([_bare, _bareNoSlash]), '');
    });

    test('跨站：裸域名行 + 另一站完整头像行', () {
      expect(mergeRows([_bare, _fullJdb]), _fullJdb);
    });
  });
}
