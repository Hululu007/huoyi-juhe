import 'dart:convert';
import 'dart:io';

enum M3uExportDownloadScope { none, site, category, video }

class M3uExportDownloadCancelled implements Exception {
  const M3uExportDownloadCancelled();
}

class M3uExportDownloadOptions {
  const M3uExportDownloadOptions({
    required this.scope,
    this.categoryId,
    this.videoId,
    required this.downloader,
    required this.directoryResolver,
  });

  final M3uExportDownloadScope scope;
  final String? categoryId;
  final String? videoId;
  final VideoDownloader downloader;
  final Future<Directory> Function() directoryResolver;

  bool appliesTo(String categoryId, String videoId) {
    switch (scope) {
      case M3uExportDownloadScope.none:
        return false;
      case M3uExportDownloadScope.site:
        return true;
      case M3uExportDownloadScope.category:
        return this.categoryId == categoryId;
      case M3uExportDownloadScope.video:
        return this.videoId == videoId;
    }
  }
}

typedef VideoDownloadProgress = void Function(int done, int total);

abstract interface class VideoDownloader {
  Future<String> downloadVideo({
    required String url,
    required Map<String, String> headers,
    required Directory targetDir,
    VideoDownloadProgress? onProgress,
    bool Function()? isCancelled,
  });
}

String sanitizeDownloadStem(String value) {
  final cleaned = value
      .replaceAll(RegExp(r'[\/\\:*?"<>|\x00-\x1F\x7F]'), '_')
      .trim()
      .replaceAll(RegExp(r'^_+|_+$'), '');
  return cleaned.isEmpty ? 'video' : cleaned;
}

String _extensionOf(String uriString, String fallback) {
  final uri = Uri.tryParse(uriString);
  final path = uri?.path ?? uriString;
  final base = path.split('/').last;
  final dot = base.lastIndexOf('.');
  if (dot < 0) return fallback;
  final ext = base.substring(dot + 1);
  if (ext.isEmpty || !RegExp(r'^[A-Za-z0-9]+$').hasMatch(ext)) {
    return fallback;
  }
  return ext.toLowerCase();
}

class HttpVideoDownloader implements VideoDownloader {
  HttpVideoDownloader({HttpClient? client}) : _client = client ?? HttpClient();

  final HttpClient _client;
  static const _requestTimeout = Duration(seconds: 30);

  Future<List<int>> _getBytes(
    String url,
    Map<String, String> headers,
  ) async {
    final request = await _client
        .getUrl(Uri.parse(url))
        .timeout(_requestTimeout);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    final response = await request.close().timeout(_requestTimeout);
    if (response.statusCode != 200) {
      throw HttpException(
        '下载 HTTP ${response.statusCode}：$url',
        uri: Uri.parse(url),
      );
    }
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
    }
    return bytes;
  }

  Future<String> _getText(String url, Map<String, String> headers) async {
    final bytes = await _getBytes(url, headers);
    return utf8.decode(bytes);
  }

  void _checkCancelled(
    bool Function()? isCancelled,
    Directory targetDir,
  ) {
    if (isCancelled?.call() == true) {
      if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
      throw const M3uExportDownloadCancelled();
    }
  }

  @override
  Future<String> downloadVideo({
    required String url,
    required Map<String, String> headers,
    required Directory targetDir,
    VideoDownloadProgress? onProgress,
    bool Function()? isCancelled,
  }) async {
    await targetDir.create(recursive: true);
    try {
      if (isM3u8Url(url)) {
        return await _downloadPlaylist(
          url,
          headers,
          targetDir,
          onProgress: onProgress,
          isCancelled: isCancelled,
        );
      }
      final ext = _extensionOf(url, 'mp4');
      final file = File('${targetDir.path}/video.$ext');
      final bytes = await _getBytes(url, headers);
      _checkCancelled(isCancelled, targetDir);
      await file.writeAsBytes(bytes);
      onProgress?.call(1, 1);
      return file.path;
    } catch (error) {
      if (error is M3uExportDownloadCancelled) rethrow;
      if (targetDir.existsSync()) targetDir.deleteSync(recursive: true);
      rethrow;
    }
  }

  Future<String> _downloadPlaylist(
    String url,
    Map<String, String> headers,
    Directory targetDir,
    {
    required VideoDownloadProgress? onProgress,
    required bool Function()? isCancelled,
    int depth = 0,
  }) async {
    if (depth > 3) throw StateError('主播单嵌套过深，放弃下载：$url');
    final body = await _getText(url, headers);
    final lines = body.split('\n');
    final variantIndex = lines.indexWhere(
      (line) => line.trim().startsWith('#EXT-X-STREAM-INF'),
    );
    if (variantIndex >= 0) {
      for (var i = variantIndex + 1; i < lines.length; i++) {
        final candidate = lines[i].trim();
        if (candidate.isEmpty || candidate.startsWith('#')) continue;
        final variantUrl = Uri.parse(url).resolve(candidate).toString();
        return _downloadPlaylist(
          variantUrl,
          headers,
          targetDir,
          onProgress: onProgress,
          isCancelled: isCancelled,
          depth: depth + 1,
        );
      }
      throw StateError('主播单没有可跟的清晰度地址：$url');
    }
    final segmentUris = <String>[];
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      segmentUris.add(trimmed);
    }
    var done = 0;
    var keyIndex = 0;
    var mapIndex = 0;
    var segmentIndex = 0;
    final total = segmentUris.length;
    final out = <String>[];
    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.startsWith('#EXT-X-KEY:')) {
        out.add(await _rewriteKeyLine(
          line,
          url,
          headers,
          targetDir,
          keyIndex++,
          isCancelled,
        ));
        continue;
      }
      if (line.startsWith('#EXT-X-MAP:')) {
        out.add(await _rewriteMapLine(
          line,
          url,
          headers,
          targetDir,
          mapIndex++,
          isCancelled,
        ));
        continue;
      }
      if (line.isEmpty || line.startsWith('#')) {
        out.add(rawLine);
        continue;
      }
      _checkCancelled(isCancelled, targetDir);
      final segmentUrl = Uri.parse(url).resolve(line).toString();
      final ext = _extensionOf(line, 'ts');
      final name = 'seg_${segmentIndex.toString().padLeft(5, '0')}.$ext';
      segmentIndex++;
      final bytes = await _getBytes(segmentUrl, headers);
      _checkCancelled(isCancelled, targetDir);
      await File('${targetDir.path}/$name').writeAsBytes(bytes);
      done++;
      onProgress?.call(done, total);
      out.add(name);
    }
    final playlist = File('${targetDir.path}/index.m3u8');
    await playlist.writeAsString(out.join('\n'));
    return playlist.path;
  }

  Future<String> _rewriteKeyLine(
    String line,
    String baseUrl,
    Map<String, String> headers,
    Directory targetDir,
    int keyIndex,
    bool Function()? isCancelled,
  ) async {
    final method = RegExp(
      r'METHOD=([^,]+)',
    ).firstMatch(line)?.group(1)?.trim();
    if (method == 'NONE') return line;
    if (method != 'AES-128') {
      throw UnsupportedError('不支持的加密方式 $method，离线无法播放');
    }
    final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line) ??
        RegExp(r'URI=([^,]+)').firstMatch(line);
    final uriValue = uriMatch?.group(1)?.trim();
    if (uriValue == null || uriValue.isEmpty) return line;
    _checkCancelled(isCancelled, targetDir);
    final keyUrl = Uri.parse(baseUrl).resolve(uriValue).toString();
    final bytes = await _getBytes(keyUrl, headers);
    _checkCancelled(isCancelled, targetDir);
    final name = 'key_$keyIndex.key';
    await File('${targetDir.path}/$name').writeAsBytes(bytes);
    return line.replaceFirst(uriValue, name);
  }

  Future<String> _rewriteMapLine(
    String line,
    String baseUrl,
    Map<String, String> headers,
    Directory targetDir,
    int mapIndex,
    bool Function()? isCancelled,
  ) async {
    final uriMatch = RegExp(r'URI="([^"]+)"').firstMatch(line) ??
        RegExp(r'URI=([^,]+)').firstMatch(line);
    final uriValue = uriMatch?.group(1)?.trim();
    if (uriValue == null || uriValue.isEmpty) return line;
    _checkCancelled(isCancelled, targetDir);
    final mapUrl = Uri.parse(baseUrl).resolve(uriValue).toString();
    final bytes = await _getBytes(mapUrl, headers);
    _checkCancelled(isCancelled, targetDir);
    final ext = _extensionOf(uriValue, 'mp4');
    final name = 'map_$mapIndex.$ext';
    await File('${targetDir.path}/$name').writeAsBytes(bytes);
    return line.replaceFirst(uriValue, name);
  }
}

bool isM3u8Url(String url) {
  final uri = Uri.tryParse(url.trim());
  if (uri == null) return false;
  return uri.path.toLowerCase().endsWith('.m3u8');
}
