import 'package:flutter_test/flutter_test.dart';
import 'package:fqapp/services/platform_channel.dart';
import 'package:fqapp/services/system_proxy.dart';

void main() {
  tearDown(() {
    PlatformChannels.invoke = null;
  });

  test('proxyUrlFromMap builds http and socks5 URLs', () {
    expect(
      SystemProxyService.proxyUrlFromMap({
        'host': '127.0.0.1',
        'port': 7890,
        'type': 'http',
      }),
      'http://127.0.0.1:7890',
    );
    expect(
      SystemProxyService.proxyUrlFromMap({
        'host': '127.0.0.1',
        'port': 7890,
        'type': 'socks',
      }),
      'socks5://127.0.0.1:7890',
    );
    expect(
      SystemProxyService.proxyUrlFromMap({
        'host': '127.0.0.1',
        'port': 7890,
        'type': 'socks5',
      }),
      'socks5://127.0.0.1:7890',
    );
  });

  test('proxyUrlFromMap returns null without a usable host or port', () {
    expect(SystemProxyService.proxyUrlFromMap(null), isNull);
    expect(SystemProxyService.proxyUrlFromMap({}), isNull);
    expect(
      SystemProxyService.proxyUrlFromMap({'host': '', 'port': 7890}),
      isNull,
    );
    expect(
      SystemProxyService.proxyUrlFromMap({'host': '127.0.0.1', 'port': 0}),
      isNull,
    );
    expect(
      SystemProxyService.proxyUrlFromMap({
        'host': '127.0.0.1',
        'port': 'not-a-port',
      }),
      isNull,
    );
  });

  test('getProxyUrl returns the system proxy URL from the channel', () async {
    PlatformChannels.invoke = (channel, method, args) async {
      expect(channel, 'fqapp/system-proxy');
      expect(method, 'getProxy');
      return <String, dynamic>{
        'host': '127.0.0.1',
        'port': 7890,
        'type': 'http',
      };
    };
    expect(await SystemProxyService.getProxyUrl(), 'http://127.0.0.1:7890');
  });

  test('getProxyUrl returns null when there is no system proxy', () async {
    PlatformChannels.invoke = (_, _, _) async => null;
    expect(await SystemProxyService.getProxyUrl(), isNull);
  });

  test('getProxyUrl returns null when the channel throws', () async {
    PlatformChannels.invoke = (_, _, _) async =>
        throw StateError('通道不可用');
    expect(await SystemProxyService.getProxyUrl(), isNull);
  });

  test('applyEgressProxy and clearEgressProxy never throw without the core',
      () async {
    // FRB 绑定未生成 / 核心未起时也要安全返回 false，不把启动拖垮。
    // 绑定生成后由总协调补验真机：有代理时返回 true 且核心走代理，
    // 无代理时返回 true 且核心回直连。
    PlatformChannels.invoke = (_, _, _) async => <String, dynamic>{
      'host': '127.0.0.1',
      'port': 7890,
      'type': 'http',
    };
    expect(await SystemProxyService.applyEgressProxy(), isFalse);
    expect(await SystemProxyService.clearEgressProxy(), isFalse);
  });
}
