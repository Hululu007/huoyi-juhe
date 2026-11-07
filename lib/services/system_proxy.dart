import 'dart:async';

import '../src/rust/api.dart' as rust;
import 'app_log.dart';
import 'platform_channel.dart';

/// 系统代理自动检测：读手机的系统代理（用户 VPN / 梯子设的代理），
/// 交给 Rust 核心当出口代理用。
///
/// 背景：Rust 核心的 reqwest 在手机上读不到系统代理（只读环境变量，
/// App 进程里没有），直连会被墙拦；核心侧的出口代理初始就是直连
/// （`PROXY_URL` 为 None），Dart 侧不传，核心就永远直连。所以这条线
/// 必须由 Dart 侧接通：启动时调一次 [applyEgressProxy]，网络变化时再
/// 调一次（见 main.dart 里已有的连通性监听）。
///
/// 代理和直连两条路同时支持：
/// - 有代理时把代理地址传给核心，核心走代理出站；
/// - 无代理时显式传空串清掉，核心回直连。不能“读不到就不管”：用户关掉
///   VPN 后核心里可能还留着旧代理，再请求就会走一个已经不存在的代理而
///   失败，所以每次应用都要明确表态。
/// 手动代理设置同理：清空手动代理时也要调一次空串清掉，不要只删本地存储
/// （见 [clearEgressProxy]，供将来的手动代理设置页调用；树里目前还没有
/// 手动代理设置入口，所以这里只留方法、不另起设置页）。
///
/// FRB 绑定：[_setEgressProxy] 调 Rust 侧 `set_egress_proxy`
/// （rust/src/api/mod.rs）生成的顶层包装 `setEgressProxy`
/// （按 `init` → `crateApiInit` 的同款规律生成，包装内调
/// `crateApiSetEgressProxy`）；绑定已生成，传参形式与返回值
/// （成功回 "ok"、空串清代理）已与生成的包装核对一致。
class SystemProxyService {
  static const _channel = AppMethodChannel('fqapp/system-proxy');

  /// 读系统代理的超时：原生侧只是读个系统服务，3 秒足够；超时按无代理
  /// 处理，不拖启动。
  static const _readTimeout = Duration(seconds: 3);

  /// 读系统代理，拼成核心能用的 URL：
  /// - http 代理返回 `http://host:port`；
  /// - socks 类型返回 `socks5://host:port`；
  /// - 无代理、读失败、超时、回包缺 host/port 时返回 null。
  static Future<String?> getProxyUrl() async {
    try {
      final proxy = await _channel
          .invokeMapMethod<String, dynamic>('getProxy')
          .timeout(_readTimeout);
      return proxyUrlFromMap(proxy);
    } catch (error, stack) {
      AppLog.w('proxy', '读取系统代理失败，按无代理处理', error: error, stack: stack);
      return null;
    }
  }

  /// 把原生回的代理 map 拼成核心能用的 URL（纯函数，可单测）：
  /// 缺 host/port 时返回 null；type 是 socks/socks5 时拼 socks5，
  /// 其余（http 等）拼 http。
  static String? proxyUrlFromMap(Map<String, dynamic>? proxy) {
    if (proxy == null) return null;
    final host = (proxy['host'] as String?)?.trim() ?? '';
    final portValue = proxy['port'];
    final port = portValue is num
        ? portValue.toInt()
        : int.tryParse(portValue.toString());
    if (host.isEmpty || port == null || port <= 0) return null;
    final type = (proxy['type'] as String?)?.trim().toLowerCase() ?? 'http';
    if (type == 'socks' || type == 'socks5' || type == 'socks5h') {
      return 'socks5://$host:$port';
    }
    return 'http://$host:$port';
  }

  /// 把当前系统代理应用到核心：每次都明确表态——读到代理就设进去，
  /// 读不到就传空串清掉，让核心回直连（防旧代理滞留）。
  /// 成功（核心回 "ok"）返回 true；失败返回 false，不抛错，不影响启动。
  static Future<bool> applyEgressProxy() async {
    final proxyUrl = await getProxyUrl();
    return _setEgressProxy(proxyUrl ?? '');
  }

  /// 显式清除核心的出口代理（恢复直连）：供手动代理设置页清空时调用，
  /// 不要只删本地存储。成功返回 true；失败返回 false，不抛错。
  static Future<bool> clearEgressProxy() => _setEgressProxy('');

  static Future<bool> _setEgressProxy(String proxyUrl) async {
    try {
      final result = await rust.setEgressProxy(proxyUrl: proxyUrl);
      if (result == 'ok') {
        if (proxyUrl.isEmpty) {
          AppLog.i('proxy', '出口代理已清除，核心恢复直连');
        } else {
          AppLog.i('proxy', '已把系统代理交给核心：$proxyUrl');
        }
        return true;
      }
      AppLog.w('proxy', '核心回了意外的出口代理设置结果：$result');
      return false;
    } catch (error, stack) {
      AppLog.w(
        'proxy',
        '应用出口代理失败，保持当前核心出口不变',
        error: error,
        stack: stack,
      );
      return false;
    }
  }
}
