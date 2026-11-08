import 'drama_site_content.dart';
import 'local_media_proxy.dart';
import 'source_registry.dart';

/// 把 FongMiTV 形态的 `proxy://do=py&siteKey=xxx&u=...` 接到蜘蛛
/// localProxy：按 siteKey 找客户端再调蜘蛛的 localProxy。
///
/// 为什么不能 Dart 侧直接取：danai 的封面是 AES 加密图，蜘蛛的
/// localProxy 取回后还要拿站内密钥解密，只有蜘蛛自己能解；jar 站同理
/// （各自 proxy 里可能带私有逻辑）。所以 /proxy 的 do/siteKey 形态
/// 只做分发，不猜内容。
///
/// 只在应用启动时调一次（main.dart）。解析不到站、站没实现
/// localProxy、蜘蛛回空时一律回 null，/proxy 回 404，不兜底。
void bindLocalProxyRoutes() {
  LocalMediaProxy.instance.onProxyRequest = (uri) async {
    final siteKey = uri.queryParameters['siteKey'];
    if (siteKey == null || siteKey.isEmpty) return null;
    try {
      final client = await SourceRegistry.instance.clientFor(siteKey);
      if (client is LocalProxyCapable) {
        return await (client as LocalProxyCapable).localProxy(uri);
      }
    } catch (_) {
      // 找站失败按未实现处理：/proxy 回 404。
    }
    return null;
  };
}
