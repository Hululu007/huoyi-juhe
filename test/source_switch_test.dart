import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/drama_site_play.dart';
import 'package:fqapp/services/source_registry.dart';

SourceEntry entry(
  String id,
  SourceKind kind, {
  bool enabled = true,
  Map<String, dynamic> extra = const {},
}) {
  return SourceEntry(
    id: id,
    name: id,
    kind: kind,
    address: '',
    enabled: enabled,
    extra: extra,
  );
}

void main() {
  test('换源候选：只含启用的导入站与远程配置子站', () {
    final candidates = engineSwitchCandidates([
      entry('py1', SourceKind.pyImport),
      entry('jar1', SourceKind.jarImport),
      entry('js1', SourceKind.jsImport),
      entry('mac1', SourceKind.customMaccms),
      entry(
        'mac2',
        SourceKind.customMaccms,
        extra: {'remoteConfigId': 'cfg1'},
      ),
      entry('py-off', SourceKind.pyImport, enabled: false),
      entry('cfg1', SourceKind.remoteJson),
    ]);
    expect(
      candidates.map((e) => e.id),
      ['py1', 'jar1', 'js1', 'mac2'],
    );
  });
}
