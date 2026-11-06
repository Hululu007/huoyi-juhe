import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fqapp/services/drama_site_content.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('核心阅读站：27 个，成人 18 个，类型全覆盖', (tester) async {
    expect(coreReadingSiteIds.length, 27);
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
      8,
    );
    expect(
      coreReadingSiteIds.where((id) => coreReadingKinds[id] == 'audio').length,
      5,
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

  testWidgets('核心阅读客户端工厂：27 站有客户端，未知站回空', (tester) async {
    for (final id in coreReadingSiteIds) {
      expect(readingSiteContentClient(id), isNotNull, reason: id);
    }
    expect(readingSiteContentClient('not-a-site'), isNull);
    expect(readingSiteContentClient('yaguo'), isNull);
  });
}
