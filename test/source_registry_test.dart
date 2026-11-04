import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/local_db_site_content.dart';
import 'package:fqapp/services/source_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  group('导入站删除', () {
    test('删导入站：登记与导入副本清掉，下载原文件保留', () async {
      final temp = await Directory.systemTemp.createTemp('juhe_remove_');
      final copyOneClick = File('${temp.path}/copy_oneclick.py');
      final copyPlain = File('${temp.path}/copy_plain.py');
      final downloadFile = File('${temp.path}/example.py');
      await copyOneClick.writeAsString('one click copy');
      await copyPlain.writeAsString('plain copy');
      await downloadFile.writeAsString('download original');
      final seeded = [
        SourceEntry(
          id: 'import_oneclick',
          name: '一键站',
          kind: SourceKind.pyImport,
          address: 'example.py',
          extra: {
            'path': copyOneClick.path,
            'oneClick': true,
            'downloadPath': downloadFile.path,
            'contentType': 'mixed',
          },
        ),
        SourceEntry(
          id: 'import_plain',
          name: '手动站',
          kind: SourceKind.pyImport,
          address: 'plain.py',
          extra: {
            'path': copyPlain.path,
            'contentType': 'mixed',
          },
        ),
      ];
      SharedPreferences.setMockInitialValues({
        'juhe_custom_sources':
            jsonEncode([for (final entry in seeded) entry.toJson()]),
      });
      try {
        final registry = SourceRegistry.instance;
        await registry.removeCustom('import_oneclick');
        expect(registry.customById('import_oneclick'), isNull);
        expect(await copyOneClick.exists(), isFalse);
        expect(await downloadFile.exists(), isTrue);
        await registry.removeCustom('import_plain');
        expect(registry.customById('import_plain'), isNull);
        expect(await copyPlain.exists(), isFalse);
        expect(await downloadFile.exists(), isTrue);
      } finally {
        if (await temp.exists()) {
          await temp.delete(recursive: true);
        }
      }
    });
  });

  test('本地库入口按归一键解析：内置站走已核实主机，镜像不合并', () async {
    final hongguo =
        await SourceRegistry.instance.clientFor('localdb:hongguo');
    expect(hongguo, isA<LocalDbContentClient>());
    expect(
      (hongguo as LocalDbContentClient).dbSiteId,
      'host:hongguoduanju.com',
    );
    final mirror =
        await SourceRegistry.instance.clientFor('localdb:hgtvmirror');
    expect(
      (mirror as LocalDbContentClient).dbSiteId,
      'id:hgtvmirror',
    );
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
