/// Source routing layer (architecture separation, step A1).
///
/// Every content request the app makes converges on `ApiClient._get`, which
/// asks this router where the request should go before dispatching it. The
/// router classifies the request path into a [SourceGroup] and resolves the
/// group to a [SourceBackend] through an injectable [SourceRouterConfig].
///
/// A1 ships with every group on the local in-process core, so routing never
/// changes behavior today. The remote executor does not exist yet: selecting
/// [SourceBackend.remote] for a group makes [SourceRouter.requireLocal] throw
/// a [StateError] instead of silently falling back, so a configuration that
/// arrives before the executor lands fails loudly rather than pretending.
///
/// Two groups are pinned to local in code, not in configuration: [SourceGroup.account]
/// carries the user's real account cookie (read-only Fanqie import) and must
/// never transit a relay server, and [SourceGroup.system] is process-local
/// plumbing (health probe, `/src` file service). Configuration cannot reroute
/// either one - see [SourceRouter.backendFor].
library;

/// Where one request group is served from.
enum SourceBackend { local, remote }

/// Request groups, aligned with the endpoint groups of the core's route
/// table (`rust/src/endpoints/router.rs`) and the API contract inventory.
enum SourceGroup {
  /// Chapter bodies: `/chapters/{id}`, `/chapters/batch`, `/chapters/full`,
  /// `/chapters/{id}/novel|toutiao`.
  novelContent,

  /// Book/chapter ancillary data: `/books/...`, `/novels/...`, `/items/...`,
  /// `/authors/...`, chapter/book reviews and comment threads.
  novelMeta,

  /// Audiobooks: `/audio/...`, plus the speech timeline endpoints that live
  /// under `/chapters/{id}/timeline|timepoints`.
  audio,

  /// Comics: `/manga/...`.
  manga,

  /// Short dramas: `/videos/...`, `/series/...`, and the playlet comment
  /// writes under `/comments/{id}/digg|reply`.
  drama,

  /// Search and feeds: `/search/...`, `/recommend/...`, `/category`,
  /// `/rank/...`.
  discovery,

  /// The independent Shuqi source: `/shuqi/...` (whole group, body included -
  /// it shares nothing with the Fanqie device pool).
  shuqi,

  /// Real-account endpoints: `/account/...`. Pinned local, see [SourceRouter].
  account,

  /// Process-local plumbing: `/health`, `/src/...`. Pinned local.
  system,

  /// Anything the classifier does not recognize. Defaults to local; a path
  /// landing here after a core route change is a signal to extend the
  /// classifier, not a routing decision.
  unclassified,
}

/// Injectable routing configuration: one backend per group, plus the remote
/// base URL the (future) remote executor will talk to.
///
/// The default is [SourceRouterConfig.allLocal]. Nothing in A1 reads remote
/// configuration from the network or from disk; callers (tests, later steps)
/// construct a config and hand it to [SourceRouter].
class SourceRouterConfig {
  const SourceRouterConfig({this._backends = const {}, this.remoteBaseUrl});

  /// Every group on the local core - the shipping default for A1.
  const SourceRouterConfig.allLocal()
    : _backends = const {},
      remoteBaseUrl = null;

  final Map<SourceGroup, SourceBackend> _backends;

  /// Base URL of the remote source service. Placeholder in A1: stored so the
  /// configuration shape is stable, never dereferenced.
  final String? remoteBaseUrl;

  /// The configured backend for [group], before the router's pinned-local
  /// overrides. Unlisted groups default to [SourceBackend.local].
  SourceBackend configuredBackendFor(SourceGroup group) =>
      _backends[group] ?? SourceBackend.local;
}

/// Classifies request paths and resolves them to a backend.
class SourceRouter {
  SourceRouter({this._config = const SourceRouterConfig.allLocal()});

  final SourceRouterConfig _config;

  SourceRouterConfig get config => _config;

  /// Groups that configuration may never move off the local core.
  static const Set<SourceGroup> pinnedLocal = {
    SourceGroup.account,
    SourceGroup.system,
  };

  /// Resolves the backend for [url]: the configured backend for its group,
  /// except [pinnedLocal] groups, which always resolve to local.
  SourceBackend backendFor(Uri url) {
    final group = classify(url);
    if (pinnedLocal.contains(group)) return SourceBackend.local;
    return _config.configuredBackendFor(group);
  }

  /// A1 dispatch guard used at the `ApiClient` funnel: returns normally when
  /// [url] routes to the local core (always, under the default config) and
  /// throws a [StateError] when configuration selected the remote backend,
  /// whose executor is not implemented yet.
  void requireLocal(Uri url) {
    if (backendFor(url) == SourceBackend.remote) {
      throw StateError(
        'SourceRouter: ${classify(url).name} is configured for the remote '
        'backend, which is not implemented yet (A1)',
      );
    }
  }

  /// Classifies [url] by its path. Query and host are irrelevant: the same
  /// path shape means the same group on either backend.
  static SourceGroup classify(Uri url) {
    var path = url.path;
    if (path.length > 1 && path.endsWith('/')) {
      path = path.substring(0, path.length - 1);
    }
    if (path == '/health' ||
        path.startsWith('/src/') ||
        path.startsWith('/_session/')) {
      return SourceGroup.system;
    }
    const prefix = '/api/v1/';
    if (!path.startsWith(prefix)) return SourceGroup.unclassified;
    final parts = path
        .substring(prefix.length)
        .split('/')
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return SourceGroup.unclassified;
    switch (parts[0]) {
      case 'account':
        return SourceGroup.account;
      case 'shuqi':
        return SourceGroup.shuqi;
      case 'search':
      case 'recommend':
      case 'category':
      case 'rank':
        return SourceGroup.discovery;
      case 'audio':
        return SourceGroup.audio;
      case 'manga':
        return SourceGroup.manga;
      case 'videos':
      case 'series':
        return SourceGroup.drama;
      case 'chapters':
        return _classifyChapters(parts);
      case 'books':
        // The tone list under a book is audiobook data; everything else
        // under /books is novel metadata.
        return parts.length >= 3 && parts[2] == 'tones'
            ? SourceGroup.audio
            : SourceGroup.novelMeta;
      case 'comments':
        // /comments/{id}/digg and /comments/{id}/reply are playlet writes;
        // the remaining comment threads belong to novels.
        return parts.length >= 3 && (parts[2] == 'digg' || parts[2] == 'reply')
            ? SourceGroup.drama
            : SourceGroup.novelMeta;
      case 'novels':
      case 'items':
      case 'authors':
      case 'articles':
      case 'forum-id':
        return SourceGroup.novelMeta;
      default:
        return SourceGroup.unclassified;
    }
  }

  /// `/chapters/...` mixes three groups: chapter bodies (novel content), the
  /// speech timeline endpoints (audio) and chapter reviews (novel metadata).
  static SourceGroup _classifyChapters(List<String> parts) {
    // parts[0] == 'chapters'; shapes: [chapters, batch|full],
    // [chapters, {id}], [chapters, {id}, novel|toutiao|timeline|timepoints|
    // reviews], [chapters, {id}, paragraphs, {n}, reviews|short-reviews].
    if (parts.length >= 3) {
      final leaf = parts[2];
      if (leaf == 'timeline' || leaf == 'timepoints') {
        return SourceGroup.audio;
      }
      if (leaf == 'reviews' || leaf == 'paragraphs') {
        return SourceGroup.novelMeta;
      }
    }
    return SourceGroup.novelContent;
  }
}
