import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/pages/video_page.dart';
import 'package:fqapp/services/source_registry.dart';

SourceEntry _entry({
  required String id,
  required String name,
  required SourceKind kind,
  Map<String, Object?> extra = const {},
  bool enabled = true,
}) {
  return SourceEntry(
    id: id,
    name: name,
    kind: kind,
    address: '$id.addr',
    detail: '',
    extra: extra,
    enabled: enabled,
  );
}

void main() {
  test('影视区空白规则：预置内置站不列，只列用户自己导入的站', () {
    final entries = [
      _entry(
        id: 'jar:zakatv:demo',
        name: '预置 jar 站',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'contentType': 'video'},
      ),
      _entry(
        id: 'import_user_jar',
        name: '用户导入的 jar 站',
        kind: SourceKind.jarImport,
      ),
      _entry(
        id: 'import_user_py',
        name: '用户导入的 py 站',
        kind: SourceKind.pyImport,
      ),
      _entry(
        id: 'import_user_maccms',
        name: '用户添加的采集站',
        kind: SourceKind.customMaccms,
        extra: {'contentType': 'mixed'},
      ),
      _entry(
        id: 'import_user_legado_no_explore',
        name: '无发现页的书源站',
        kind: SourceKind.legadoImport,
      ),
      _entry(
        id: 'import_user_legado_explore',
        name: '有发现页的书源站',
        kind: SourceKind.legadoImport,
        extra: {'hasExplore': true},
      ),
      _entry(
        id: 'import_disabled',
        name: '已禁用的用户站',
        kind: SourceKind.pyImport,
        enabled: false,
      ),
      _entry(
        id: 'builtin_drama',
        name: '内置短剧站',
        kind: SourceKind.builtinDrama,
      ),
    ];
    final sites = videoPagePlayableSites(entries);
    expect(
      sites.map((site) => site.id),
      [
        'import_user_jar',
        'import_user_py',
        'import_user_maccms',
        'import_user_legado_explore',
      ],
    );
  });

  test('影视区空白规则：成人站直接列出，不再设门', () {
    final entries = [
      _entry(
        id: 'import_adult',
        name: '🔞成人站',
        kind: SourceKind.pyImport,
      ),
    ];
    expect(videoPagePlayableSites(entries).length, 1);
  });

  test('影视区空白规则：全是内置站时结果为空', () {
    final entries = [
      _entry(
        id: 'jar:zakatv:demo',
        name: '预置 jar 站',
        kind: SourceKind.jarImport,
        extra: {'builtin': true},
      ),
    ];
    expect(videoPagePlayableSites(entries), isEmpty);
  });

  test('TG影视库钉在影视区切换器最前面', () {
    // 切换器里 100 多个站，TG影视库钉最后翻不到底；钉第一位，
    // 打开切换器一眼就能看到。默认选中仍是保存过的选择。
    expect(videoZoneSites().first.id, 'tgdrama');
    expect(videoZoneSites().first.name, 'TG影视库');
  });
}
