import '../models/media_item.dart';

/// 所有短剧站点共用原始站点的播放流程：同一个 PlayerPage、同一套选集
/// Chapter、同一个 EpisodeSource，不给任何站另起播放器。
///
/// 原始站走 PlayerPage 默认的取流（ApiClient.content，短剧 stream），
/// 外站只换取流这一处：给 PlayerPage 传一个 contentLoader，返回下面
/// 这套与 EpisodeSource.fromResponse 同形的 map 即可。
/// 直链 mp4/HLS 的 keyHex 留空；带密钥的流才填 keyHex。
class DramaPlayVariant {
  final String name;
  final String url;
  final String keyHex;
  final int height;

  const DramaPlayVariant({
    required this.name,
    required this.url,
    this.keyHex = '',
    this.height = 0,
  });

  Map<String, dynamic> toMap() => {
    'name': name,
    'url': url,
    'key_hex': keyHex,
    'height': height,
  };
}

class DramaPlaySource {
  final String url;
  final String keyHex;
  final List<DramaPlayVariant> variants;

  /// playerContent 回的 dict 头：取流层不直接交给播放器，统一经本地
  /// 媒体代理带上（见 drama_site_play 的 _proxyIfNeeded）。
  final Map<String, String> headers;

  const DramaPlaySource({
    required this.url,
    this.keyHex = '',
    this.variants = const [],
    this.headers = const {},
  });

  Map<String, dynamic> toResponse() => {
    'video_url': url,
    'key_hex': keyHex,
    'variants': [for (final variant in variants) variant.toMap()],
  };
}

/// 外站一集的取流：入参是原始播放流程的 Chapter，出参是上面那套播放源。
/// 详情页、选集、切集、预取、进度与历史一律走原始流程，不在这里重做。
typedef DramaPlayLoader = Future<DramaPlaySource> Function(Chapter episode);

Future<Map<String, dynamic>> dramaContentLoader(
  DramaPlayLoader loader,
  Chapter episode,
) async {
  final source = await loader(episode);
  return source.toResponse();
}
