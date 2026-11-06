import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_site_content.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('核心阅读站：31 个，成人 18 个，类型全覆盖', (tester) async {
    expect(coreReadingSiteIds.length, 31);
    expect(coreAdultReadingSiteIds.length, 18);
    expect(coreAdultReadingSiteIds.difference(coreReadingSiteIds), isEmpty);
    for (final id in coreReadingSiteIds) {
      expect(coreReadingKinds[id], isNotNull, reason: id);
      expect(
        coreReadingKinds[id],
        isIn(['novel', 'comic', 'audio']),
        reason: id,
      );
    }
    expect(
      coreReadingSiteIds.where((id) => coreReadingKinds[id] == 'novel').length,
      14,
    );
    expect(
      coreReadingSiteIds.where((id) => coreReadingKinds[id] == 'comic').length,
      11,
    );
    expect(
      coreReadingSiteIds.where((id) => coreReadingKinds[id] == 'audio').length,
      6,
    );
    expect(
      coreAdultReadingSiteIds
          .where((id) => coreReadingKinds[id] == 'novel')
          .length,
      12,
    );
    expect(
      coreAdultReadingSiteIds
          .where((id) => coreReadingKinds[id] == 'comic')
          .length,
      4,
    );
    expect(
      coreAdultReadingSiteIds
          .where((id) => coreReadingKinds[id] == 'audio')
          .length,
      2,
    );
  });

  testWidgets('核心阅读客户端工厂：31 站有客户端，未知站回空', (tester) async {
    for (final id in coreReadingSiteIds) {
      expect(readingSiteContentClient(id), isNotNull, reason: id);
    }
    expect(readingSiteContentClient('not-a-site'), isNull);
    expect(readingSiteContentClient('yaguo'), isNull);
  });
}
