import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/source_registry.dart';

void main() {
  test('远程 JSON 站点名解析：sites 列表与直接列表都认', () {
    expect(
      parseRemoteJsonSiteNames({
        'sites': [
          {'name': '甲站', 'api': 'https://example.test/a'},
          {'name': '乙站'},
          {'api': 'https://example.test/c'},
        ],
      }),
      ['甲站', '乙站'],
    );
    expect(
      parseRemoteJsonSiteNames([
        {'name': '丙站'},
      ]),
      ['丙站'],
    );
    expect(parseRemoteJsonSiteNames({'other': 1}), isEmpty);
  });

  test('自定义站源记录往返：类型与开关不变，内置类型不进自定义', () {
    const entry = SourceEntry(
      id: 'custom_123',
      name: '测试站',
      kind: SourceKind.customMaccms,
      address: 'https://example.test',
    );
    final restored = SourceEntry.fromJson(entry.toJson());
    expect(restored?.id, 'custom_123');
    expect(restored?.kind, SourceKind.customMaccms);
    expect(restored?.enabled, true);
    expect(
      SourceEntry.fromJson({
        'id': 'x',
        'name': '内置',
        'kind': 'builtinDrama',
      }),
      isNull,
    );
    expect(
      SourceRegistry.customIdForUrl('https://example.test'),
      SourceRegistry.customIdForUrl('https://example.test'),
    );
  });
}
