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
  test('午夜 jar 内置判定：只认 jar 内置视频站，音频站除外', () {
    expect(
      isMidnightJarBuiltin(
        _entry(
          id: 'jar:zakatv:demo',
          name: '🔞演示站',
          kind: SourceKind.jarImport,
          extra: {'builtin': true, 'contentType': 'video'},
        ),
      ),
      isTrue,
    );
    expect(
      isMidnightJarBuiltin(
        _entry(
          id: 'jar:zakatv:mixed',
          name: '🔞综合站',
          kind: SourceKind.jarImport,
          extra: {'builtin': true, 'contentType': 'mixed'},
        ),
      ),
      isTrue,
    );
    expect(
      isMidnightJarBuiltin(
        _entry(
          id: 'jar:youtube:youtube',
          name: 'YouTube',
          kind: SourceKind.jarImport,
          extra: {'builtin': true, 'youtubeConfig': true},
        ),
      ),
      isTrue,
    );
    expect(
      isMidnightJarBuiltin(
        _entry(
          id: 'import_user_jar',
          name: '用户导入的 jar 站',
          kind: SourceKind.jarImport,
        ),
      ),
      isFalse,
    );
    expect(
      isMidnightJarBuiltin(
        _entry(
          id: 'jar:zakatv:tingshu',
          name: '听书',
          kind: SourceKind.jarImport,
          extra: {'builtin': true, 'contentType': 'audio'},
        ),
      ),
      isFalse,
    );
    expect(
      isMidnightJarBuiltin(
        _entry(
          id: 'hongguo',
          name: '红果',
          kind: SourceKind.builtinDrama,
        ),
      ),
      isFalse,
    );
  });

  test('午夜页视频站列表：只列启用的 jar 内置视频站', () {
    final entries = [
      _entry(
        id: 'jar:zakatv:demo',
        name: '🔞演示站',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'contentType': 'video'},
      ),
      _entry(
        id: 'jar:zakatv:disabled',
        name: '🔞已禁用站',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'contentType': 'video'},
        enabled: false,
      ),
      _entry(
        id: 'jar:zakatv:tingshu',
        name: '听书',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'contentType': 'audio'},
      ),
      _entry(
        id: 'jar:youtube:youtube',
        name: 'YouTube',
        kind: SourceKind.jarImport,
        extra: {'builtin': true, 'youtubeConfig': true},
      ),
      _entry(
        id: 'import_user_py',
        name: '用户导入的 py 站',
        kind: SourceKind.pyImport,
      ),
    ];
    expect(
      midnightJarVideoSites(entries).map((site) => site.id),
      ['jar:zakatv:demo', 'jar:youtube:youtube'],
    );
  });
}
