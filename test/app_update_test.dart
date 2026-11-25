import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 魔蚁同步批 B8 软件内更新：版本模型、选版、强制窗口、续传
/// 决策、「稍后再说」语义、桥兜底。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AppVersion 解析与比较', () {
    test('从标签/发布名抠版本号，缺构建号按 0', () {
      expect(AppVersion.tryParse('v1.0.1104'), const AppVersion(1, 0, 1104, 0));
      expect(
        AppVersion.tryParse('huoyi-juhe-1.0.1104-arm64'),
        const AppVersion(1, 0, 1104, 0),
      );
      expect(AppVersion.tryParse('1.0.12+37'), const AppVersion(1, 0, 12, 37));
      expect(AppVersion.tryParse('1.0.12-37'), const AppVersion(1, 0, 12, 37));
      expect(AppVersion.tryParse('没有版本号'), isNull);
      expect(AppVersion.tryParse(null), isNull);
    });

    test('逐级比较，toString 不含构建号', () {
      expect(
        const AppVersion(1, 0, 12, 37) > const AppVersion(1, 0, 12, 36),
        isTrue,
      );
      expect(
        const AppVersion(1, 1, 0, 0) > const AppVersion(1, 0, 99, 99),
        isTrue,
      );
      expect(const AppVersion(1, 0, 12, 37).toString(), '1.0.12');
    });
  });

  group('selectAppRelease 选版', () {
    Map<String, dynamic> release(
      String tag, {
      bool draft = false,
      bool prerelease = false,
      String body = '',
      List<Map<String, dynamic>> assets = const [],
    }) => <String, dynamic>{
      'tag_name': tag,
      'name': tag,
      'draft': draft,
      'prerelease': prerelease,
      'body': body,
      'html_url': 'https://example.com/$tag',
      'assets': assets,
    };

    test('跳过草稿/预发布/core- 标签，取版本最大而非第一条', () {
      final picked = selectAppRelease(<dynamic>[
        release('v9.9.9', draft: true),
        release('v8.0.0', prerelease: true),
        release('core-v7.0.0'),
        release('v1.0.1104'),
        release('v1.0.1105'),
        release('v1.0.1103'),
        release('nightly'),
      ]);
      expect(picked?.tag, 'v1.0.1105');
    });

    test('APK 资产优先 arm64，校验和取 digest 的 sha256 后段', () {
      final picked = selectAppRelease(<dynamic>[
        release('v2.0.0', assets: <Map<String, dynamic>>[
          <String, dynamic>{
            'name': 'app-armeabi-v7a.apk',
            'browser_download_url': 'https://example.com/v7a.apk',
            'size': 100,
            'digest': 'sha256:AAAA',
          },
          <String, dynamic>{
            'name': 'app-arm64-v8a.apk',
            'browser_download_url': 'https://example.com/v8a.apk',
            'size': 120,
            'digest': 'sha256:DEADBEEF',
          },
        ]),
      ]);
      expect(picked?.apkName, 'app-arm64-v8a.apk');
      expect(picked?.apkUrl, 'https://example.com/v8a.apk');
      expect(picked?.apkSize, 120);
      expect(picked?.apkSha256, 'deadbeef');
    });

    test('没有合格发布回 null', () {
      expect(selectAppRelease(<dynamic>[]), isNull);
      expect(
        selectAppRelease(<dynamic>[release('core-v1.0.0')]),
        isNull,
      );
    });
  });

  group('强制更新窗口', () {
    AppReleaseInfo info(String notes) => AppReleaseInfo(
      version: const AppVersion(2, 0, 0),
      tag: 'v2.0.0',
      name: 'v2.0.0',
      notes: notes,
      htmlUrl: 'https://example.com',
    );

    test('无窗口不强制；窗口内强制；窗口外不强制', () {
      const current = AppVersion(1, 0, 0);
      final now = DateTime(2026, 11, 26, 12);
      expect(
        isForceUpdate(current: current, latest: info('普通说明'), now: now),
        isFalse,
      );
      expect(
        isForceUpdate(
          current: current,
          latest: info('说明\nFORCE_AFTER: 2026-11-20\nFORCE_UNTIL: 2026-11-30'),
          now: now,
        ),
        isTrue,
      );
      expect(
        isForceUpdate(
          current: current,
          latest: info('FORCE_AFTER: 2026-12-01'),
          now: now,
        ),
        isFalse,
      );
      expect(
        isForceUpdate(
          current: current,
          latest: info('FORCE_UNTIL: 2026-11-25'),
          now: now,
        ),
        isFalse,
      );
    });

    test('最新版不高于当前版永不强制；纯日期 UNTIL 按当天 23:59:59', () {
      final window = parseForceWindow('FORCE_UNTIL: 2026-11-30');
      expect(window.until, DateTime(2026, 11, 30, 23, 59, 59, 999));
      expect(
        isForceUpdate(
          current: const AppVersion(2, 0, 0),
          latest: info('FORCE_AFTER: 2026-01-01'),
          now: DateTime(2026, 11, 26),
        ),
        isFalse,
      );
    });
  });

  group('续传决策 resumeDecision', () {
    test('206+已有字节续写；200 重下；416 删掉报错', () {
      expect(
        resumeDecision(existingBytes: 100, statusCode: 206),
        ResumeAction.append,
      );
      expect(
        resumeDecision(existingBytes: 100, statusCode: 200),
        ResumeAction.restart,
      );
      expect(
        resumeDecision(existingBytes: 0, statusCode: 206),
        ResumeAction.restart,
      );
      expect(
        resumeDecision(existingBytes: 100, statusCode: 416),
        ResumeAction.discardAndFail,
      );
    });
  });

  group('「稍后再说」只跳本版', () {
    test('存版本字符串全等：同版跳过、更高版不跳', () async {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      final checker = AppUpdateChecker();
      await checker.dismiss(const AppVersion(1, 0, 12, 37));
      expect(await checker.isDismissed(const AppVersion(1, 0, 12, 99)), isTrue);
      expect(await checker.isDismissed(const AppVersion(1, 0, 13, 0)), isFalse);
    });
  });

  group('安卓桥兜底', () {
    test('桥缺失时 currentVersion 回 0.0.0、openUrl 回 false', () async {
      final bridge = AppUpdateBridge(
        const MethodChannel('fqapp/appupdate-test-missing'),
      );
      expect(await bridge.currentVersion(), const AppVersion(0, 0, 0, 0));
      expect(await bridge.openUrl('https://example.com'), isFalse);
    });

    test('appInfo 解析：versionName 抠版本、versionCode 作构建号', () async {
      const channel = MethodChannel('fqapp/appupdate-test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            if (call.method == 'appInfo') {
              return <String, dynamic>{
                'versionName': '1.0.1104',
                'versionCode': 20261104,
              };
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );
      final bridge = AppUpdateBridge(channel);
      expect(
        await bridge.currentVersion(),
        const AppVersion(1, 0, 1104, 20261104),
      );
    });
  });
}
