import 'drama_playback.dart';
import 'drama_site_content.dart';
import 'drama_sites.dart';
import 'local_media_proxy.dart';
import 'site_health.dart';

/// 站点健康记录客户端（魔蚁同步批 A3）：包在 [SourceRegistry.clientFor]
/// 的出口上，对详情 / 搜索 / 播放（取流）三类调用记最终成败一次，
/// 其余方法（分类 / 目录）原样透传不打点。魔蚁的打点在核桥包装层，
/// 修仙版没有单一核桥，clientFor 是全树唯一的客户端出口，等价落点
/// 就在这里——所有页面拿到的都是这一层，不必逐页接线。
///
/// 透明性：
/// - 返回值与异常都原样透传（记完失败照样 rethrow），打点本身吞错，
///   健康学习坏掉不影响取数与播放；
/// - [LocalProxyCapable] 语义原样保留：内层实现了就转发，没实现时
///   抛与 drama_site_play 同文案的 StateError（原行为是在建会话时
///   抛，这里在首次代理请求时抛，同为诚实失败、不会静默回空）。
class SiteHealthTrackingClient extends DramaSiteContentClient
    implements LocalProxyCapable {
  SiteHealthTrackingClient({required this.siteId, required this.inner});

  final String siteId;
  final DramaSiteContentClient inner;

  @override
  Future<List<DramaSiteCategory>> categories() => inner.categories();

  @override
  Future<DramaSiteCatalogPage> catalog(String categoryId, int page) =>
      inner.catalog(categoryId, page);

  @override
  Future<DramaSiteDetail> detail(String seriesId) async {
    final watch = Stopwatch()..start();
    try {
      final result = await inner.detail(seriesId);
      SiteHealthStore.instance.recordDetail(
        siteId,
        ok: true,
        elapsedMs: watch.elapsedMilliseconds,
      );
      return result;
    } catch (_) {
      SiteHealthStore.instance.recordDetail(siteId, ok: false);
      rethrow;
    }
  }

  @override
  Future<List<DramaSiteItem>> search(String query) async {
    final watch = Stopwatch()..start();
    try {
      final result = await inner.search(query);
      SiteHealthStore.instance.recordSearch(
        siteId,
        ok: true,
        items: result.length,
        elapsedMs: watch.elapsedMilliseconds,
      );
      return result;
    } catch (_) {
      SiteHealthStore.instance.recordSearch(siteId, ok: false);
      rethrow;
    }
  }

  @override
  Future<DramaPlaySource> playSource(DramaSiteEpisode episode) async {
    try {
      final result = await inner.playSource(episode);
      SiteHealthStore.instance.recordPlay(siteId, ok: true);
      return result;
    } catch (_) {
      SiteHealthStore.instance.recordPlay(siteId, ok: false);
      rethrow;
    }
  }

  @override
  Future<LocalProxyResponse?> localProxy(Uri uri) async {
    final capable = inner;
    if (capable is LocalProxyCapable) {
      return (capable as LocalProxyCapable).localProxy(uri);
    }
    throw StateError('该站未实现本地代理，无法转接壳代理地址');
  }
}

/// 拆包：需要按具体客户端类型调扩展 API 的消费方（如 XBPQ 的
/// catalogFiltered / filterGroups）先经这里拿到内层真客户端。
/// 其余消费方一律用包装层即可，不必拆。
DramaSiteContentClient unwrapSiteClient(DramaSiteContentClient client) =>
    client is SiteHealthTrackingClient ? client.inner : client;
