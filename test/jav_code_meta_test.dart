// DRAFT — target: test/jav_code_meta_test.dart (copy into the smart-match
// worktree after the user gives the go-ahead; see REPORT.md).
//
// 三站番号元数据加载器 + 详情页智能匹配区测试。
// 单元测试用 fromLines（不读资源）；资源实测用内置 jav_code_meta.txt.gz。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/actress/code_meta_section.dart';
import 'package:fqapp/actress/jav_code_meta.dart';
import 'package:fqapp/actress/whos_json_index.dart';

void main() {
  group('JavCodeMeta 解析（紧凑行格式）', () {
    // 字段：番号||标题||别名（／）||年份||导演||厂商||女优（;）||男优（;）
    // （字面量由生成脚本拼出并验过 8 字段对齐，勿手改分隔符个数。）
    const lines = [
      'ABP-188||ABP-188 美しいお嬢様の卑猥なる飼育 あやみ旬果||A Lovely Young Lady’s Lusty Pet／一个美丽的年轻女子 Ayami Shunka 的淫秽繁殖||2014||サマンサ☆田畑||プレステージ||あやみ旬果||',
      'JUR-929||一位拥有H罩杯的妻子||DB标题别名||||||||||マッスル澤野;貞松大輔',
      'EBWH-035-UNCENSORED-LEAK||EBWH-035安静温柔的住宅区妻子||||2023||||||素人||',
      'MUSUME-110324-01||MUSUME-110324_01忙碌的女儿||||||||||素人||',
      '042816-01||042816-01 制服時代||||2016||||||素人||',
      'CNTH-302||走馬探花到世界各地约炮3P||||||||||||',
    ];

    test('番号查：精确、小写、codeKey、下划线写法', () {
      final map = JavCodeMeta.fromLines(lines);
      expect(map.codeCount, 6);
      final abp = map.metaForCode('ABP-188')!;
      expect(abp.director, 'サマンサ☆田畑');
      expect(abp.maker, 'プレステージ');
      expect(abp.year, 2014);
      expect(abp.female, ['あやみ旬果']);
      expect(abp.male, isEmpty);
      // 小写 vod_id 形态
      expect(map.metaForCode('abp-188')?.code, 'ABP-188');
      // codeKey 形态（去横杠、去前导零，与 App 内 codeKey 同一套口径）
      expect(map.metaForCode('ABP188')?.code, 'ABP-188');
      expect(map.metaForCode('abp188')?.code, 'ABP-188');
      // 库里下划线写法（caribbeancompr-120916_003 式）走 codeKey
      expect(map.metaForCode('MUSUME-110324_01')?.code, 'MUSUME-110324-01');
      // 查不到返回 null
      expect(map.metaForCode('XXXX-000'), isNull);
    });

    test('后缀保留：泄露版与原正片不是同一部片', () {
      final map = JavCodeMeta.fromLines(lines);
      final leak = map.metaForCode('EBWH-035-UNCENSORED-LEAK');
      expect(leak, isNotNull);
      expect(leak!.year, 2023);
      // 带后缀的番号查不到时，绝不回落到无后缀的（这里无 EBWH-035 行）
      expect(map.metaForCode('EBWH-035'), isNull);
    });

    test('素人剔除：通用标注不是真人', () {
      final map = JavCodeMeta.fromLines(lines);
      expect(map.metaForCode('MUSUME-110324-01')!.female, isEmpty);
      expect(map.metaForCode('042816-01')!.female, isEmpty);
      expect(map.metaForCode('EBWH-035-UNCENSORED-LEAK')!.female, isEmpty);
      // 但行本身还在（标题、年份都在）
      expect(map.metaForCode('042816-01')!.title, contains('制服時代'));
      expect(map.metaForCode('042816-01')!.year, 2016);
    });

    test('标题兜底：标题与别名都能命中，查不到返回 null', () {
      final map = JavCodeMeta.fromLines(lines);
      expect(map.metaForTitle('ABP-188 美しいお嬢様の卑猥なる飼育 あやみ旬果')?.code, 'ABP-188');
      // 别名（库标题写法）也能命中
      expect(map.metaForTitle('一个美丽的年轻女子 Ayami Shunka 的淫秽繁殖')?.code, 'ABP-188');
      // 空白与大小写不敏感
      expect(
        map.metaForTitle('  abp-188 美しいお嬢様の卑猥なる飼育 あやみ旬果  ')?.code,
        'ABP-188',
      );
      expect(map.metaForTitle('不存在的标题'), isNull);
      expect(map.metaForTitle(''), isNull);
    });

    test('resolveCode：id 直取保留后缀，URL 不误认', () {
      expect(
        JavCodeMeta.resolveCode(id: 'json:chaoliu:rki-6042', title: ''),
        'RKI-6042',
      );
      expect(
        JavCodeMeta.resolveCode(
          id: 'json:chaoliu:EBWH-035-UNCENSORED-LEAK',
          title: '',
        ),
        'EBWH-035-UNCENSORED-LEAK',
      );
      expect(
        JavCodeMeta.resolveCode(id: 'code_RKI-6042', title: ''),
        'RKI-6042',
      );
      expect(
        JavCodeMeta.resolveCode(id: 'jpcode:JUR-929', title: ''),
        'JUR-929',
      );
      expect(
        JavCodeMeta.resolveCode(id: 'json:whos:abc-123', title: ''),
        'ABC-123',
      );
      // 日期码（无字母）也能直取
      expect(
        JavCodeMeta.resolveCode(id: 'json:chaoliu:042816-01', title: ''),
        '042816-01',
      );
      // 裸番号
      expect(
        JavCodeMeta.resolveCode(id: '788-AOI-01', title: ''),
        '788-AOI-01',
      );
      expect(
        JavCodeMeta.resolveCode(id: 'FC2-PPV-1234567', title: ''),
        'FC2-PPV-1234567',
      );
      // URL / 纯数字 / 纯字母不认作番号
      expect(
        JavCodeMeta.resolveCode(
          id: 'https://example.com/video/123',
          title: 'some title',
        ),
        '',
      );
      expect(JavCodeMeta.resolveCode(id: '12345', title: ''), '');
      expect(JavCodeMeta.resolveCode(id: 'SSIS', title: ''), '');
    });

    test('match：先番号、再标题兜底', () {
      final map = JavCodeMeta.fromLines(lines);
      // 番号优先
      final byCode = map.match(id: 'json:chaoliu:jur-929', title: '别的标题');
      expect(byCode?.code, 'JUR-929');
      expect(byCode?.male, ['マッスル澤野', '貞松大輔']);
      // id 里没番号时走标题兜底
      final byTitle = map.match(
        id: 'some-spider-id-12345',
        title: '一个美丽的年轻女子 Ayami Shunka 的淫秽繁殖',
      );
      expect(byTitle?.code, 'ABP-188');
      // 都查不到返回 null
      expect(map.match(id: 'some-spider-id-12345', title: '不存在的标题'), isNull);
    });

    test('仅番号的行：hasUseful 为假，但行本身存在', () {
      final map = JavCodeMeta.fromLines(lines);
      final row = map.metaForCode('CNTH-302')!;
      expect(row.hasUseful, isFalse);
      expect(row.title, isNotEmpty);
    });

    test('match + who\'s 索引：演员合并（json 在前、420 在后去重），导演只取 420', () {
      final map = JavCodeMeta.fromLines(lines);
      final whos = WhosJsonIndex.fromLines(
        catalogLines: const [
          'ABP-188||json 标题||https://v.hersav.me/images/av/a.jpg||https://v.hersav.me/a/a.m3u8',
          'ROE-566||json 标题二||https://v.hersav.me/images/av/b.jpg||https://v.hersav.me/b/b.m3u8',
        ],
        mapLines: const [
          // ABP-188：json 给星冬香，420 码给あやみ旬果——合并后两个都在，json 在前。
          'ABP-188||星冬香',
          // ROE-566：420 码里没有，json 单独给演员。
          'ROE-566||星冬香',
        ],
      );
      // ABP-188：演员合并，导演仍是 420 码的，fromWhos 为真。
      final abp = map.match(
        id: 'json:chaoliu:abp-188',
        title: '别的标题',
        whosIndex: whos,
      );
      expect(abp, isNotNull);
      expect(abp!.female, ['星冬香', 'あやみ旬果']);
      expect(abp.director, isNotEmpty);
      expect(abp.fromWhos, isTrue);
      // ROE-566：420 码里没有，json 单独给演员，导演为空，标题取 json 的。
      final roe = map.match(
        id: 'json:whos:roe-566',
        title: '别的标题',
        whosIndex: whos,
      );
      expect(roe, isNotNull);
      expect(roe!.female, ['星冬香']);
      expect(roe.director, isEmpty);
      expect(roe.title, 'json 标题二');
      expect(roe.fromWhos, isTrue);
      // 都查不到返回 null（json 里没有、420 码里也没有）。
      expect(
        map.match(
          id: 'json:chaoliu:not-exist-001',
          title: '不存在的标题',
          whosIndex: whos,
        ),
        isNull,
      );
      // 不传 whosIndex 时行为不变（只查 420 码）。
      final noWhos = map.match(id: 'json:whos:roe-566', title: '别的标题');
      expect(noWhos, isNull);
    });

    test('头像字段：第 9、10 字段与名字一一对应，缺位为空', () {
      const avatarLines = [
        // 女优 1 名有头像；男优 2 名，第一名有头像、第二名没有
        'ABP-188||标题||别名||2014||导演||厂商||あやみ旬果||男优A;男优B||https://example.com/a.jpg||https://example.com/b.jpg;',
        // 老 8 字段行：头像全空（男优在第 8 字段，之后无头像字段）
        'JUR-929||标题||||||||||||マッスル澤野;貞松大輔',
      ];
      final map = JavCodeMeta.fromLines(avatarLines);
      final abp = map.metaForCode('ABP-188')!;
      expect(abp.femaleAvatars, ['https://example.com/a.jpg']);
      expect(abp.maleAvatars, ['https://example.com/b.jpg', '']);
      expect(abp.castWithAvatars, [
        (name: 'あやみ旬果', avatarUrl: 'https://example.com/a.jpg'),
        (name: '男优A', avatarUrl: 'https://example.com/b.jpg'),
        (name: '男优B', avatarUrl: ''),
      ]);
      final jur = map.metaForCode('JUR-929')!;
      expect(jur.femaleAvatars, isEmpty);
      expect(jur.maleAvatars, ['', '']);
      expect(
        jur.castWithAvatars.map((c) => c.avatarUrl),
        ['', ''],
      );
    });
  });

  group('内置资源实测（首批 420 码）', () {
    test('总数钉在 420，富行与男优行字段齐全', () async {
      final map = await JavCodeMeta.instance;
      expect(map.codeCount, 420);
      // 富行：ABP-188（导演/厂商/年份/女优全齐）
      final abp = map.metaForCode('ABP-188')!;
      expect(abp.director, 'サマンサ☆田畑');
      expect(abp.maker, 'プレステージ');
      expect(abp.year, 2014);
      expect(abp.female, ['あやみ旬果']);
      // 男优行：JUR-929（两名男优，无导演/厂商/年份）
      final jur = map.metaForCode('JUR-929')!;
      expect(jur.male, ['マッスル澤野', '貞松大輔']);
      expect(jur.female, isEmpty);
      expect(jur.director, isEmpty);
      expect(jur.maker, isEmpty);
      expect(jur.year, isNull);
      // 男优行：CAWB-056（无标题，只有男优）
      final cawb = map.metaForCode('CAWB-056')!;
      expect(cawb.title, isEmpty);
      expect(cawb.male, ['マッスル澤野']);
    });

    test('下划线写法与日期码走 codeKey 命中', () async {
      final map = await JavCodeMeta.instance;
      // 库里 vod_id 是下划线写法 musume-110324_01
      final musume = map.metaForCode('musume-110324_01');
      expect(musume?.code, 'MUSUME-110324-01');
      expect(musume?.female, isEmpty); // 素人已剔除
      // 日期码
      expect(map.metaForCode('042816-01')?.title, contains('制服時代'));
    });

    test('后缀不回落：EBWH-035 查不到泄露版', () async {
      final map = await JavCodeMeta.instance;
      expect(map.metaForCode('EBWH-035-UNCENSORED-LEAK')?.year, 2023);
      expect(map.metaForCode('EBWH-035'), isNull);
    });

    test('标题兜底：库标题（中文译名）在别名里', () async {
      final map = await JavCodeMeta.instance;
      // ABP-188 的库标题是中文译名，存在 title_alts 里
      final hit = map.metaForTitle('一个美丽的年轻女子 Ayami Shunka 的淫秽繁殖');
      expect(hit?.code, 'ABP-188');
    });

    test('真头像：ABP-188 女优带 whos 头像地址，JUR-929 男优带 JavDB 真头像', () async {
      final map = await JavCodeMeta.instance;
      final abp = map.metaForCode('ABP-188')!;
      expect(abp.femaleAvatars, [
        'https://v.hersav.me/actress/avatar/a47b84f1def9a228b67122d7568362ff_hd.jpg',
      ]);
      expect(abp.castWithAvatars, [
        (
          name: 'あやみ旬果',
          avatarUrl:
              'https://v.hersav.me/actress/avatar/a47b84f1def9a228b67122d7568362ff_hd.jpg',
        ),
      ]);
      // 男优行 JUR-929：新版三站数据里男优带 JavDB 真头像（males.json：
      // マッスル澤野 E2Z3M、貞松大輔 K4m3Q），组件直接显示真照片。
      final jur = map.metaForCode('JUR-929')!;
      expect(jur.maleAvatars, [
        'https://c0.jdbstatic.com/avatars/e2/E2Z3M.jpg',
        'https://c0.jdbstatic.com/avatars/k4/K4m3Q.jpg',
      ]);
      expect(
        jur.castWithAvatars.map((c) => c.avatarUrl),
        [
          'https://c0.jdbstatic.com/avatars/e2/E2Z3M.jpg',
          'https://c0.jdbstatic.com/avatars/k4/K4m3Q.jpg',
        ],
      );
    });
  });

  group('CodeMetaSection 组件', () {
    testWidgets('命中时只显示演员与导演', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeMetaSection(
              dramaId: 'json:chaoliu:abp-188',
              title: 'ABP-188 美しいお嬢様の卑猥なる飼育 あやみ旬果',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('演员与导演'), findsOneWidget);
      expect(find.text('あやみ旬果'), findsOneWidget);
      // 2026-11-24 用户令：演员行只显示名字，主演/配角去掉。
      expect(find.text('主演'), findsNothing);
      expect(find.text('配角'), findsNothing);
      expect(find.textContaining('导演：サマンサ☆田畑'), findsOneWidget);
      // 番号只作匹配键、不显示；厂商、年份不显示
      expect(find.textContaining('番号：'), findsNothing);
      expect(find.textContaining('出品方：'), findsNothing);
      expect(find.textContaining('年份：'), findsNothing);
      // 没有关注按钮
      expect(find.textContaining('关注'), findsNothing);
    });

    testWidgets('只有番号、无导演无演员时什么都不画', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeMetaSection(
              dramaId: 'json:chaoliu:cnth-302',
              title: '走馬探花到世界各地约炮3P',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('演员与导演'), findsNothing);
    });

    testWidgets('查不到时什么都不画', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: CodeMetaSection(
              dramaId: 'some-spider-id-12345',
              title: '一部不存在的片名',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('演员与导演'), findsNothing);
    });
  });
}
