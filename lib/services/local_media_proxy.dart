import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:http/http.dart' as http;

class _ProxySession {
  _ProxySession(this.headers);

  final Map<String, String> headers;
}

class LocalMediaProxy {
  LocalMediaProxy._();

  static final LocalMediaProxy instance = LocalMediaProxy._();

  HttpServer? _server;
  Future<void>? _starting;
  final _sessions = <String, _ProxySession>{};
  final _order = <String>[];
  http.Client _client = http.Client();

  void debugResetForTest() {
    _client.close();
    _client = http.Client();
    _sessions.clear();
    _order.clear();
  }

  Future<void> _ensureStarted() async {
    if (_server != null) return;
    if (_starting != null) return _starting!;
    _starting = () async {
      _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      _server!.listen(_handle);
    }();
    await _starting;
  }

  Future<String> register({
    required String targetUrl,
    required Map<String, String> headers,
  }) async {
    await _ensureStarted();
    final token = _randomToken();
    _sessions[token] = _ProxySession(Map<String, String>.from(headers));
    _order.add(token);
    while (_order.length > 200) {
      _sessions.remove(_order.removeAt(0));
    }
    return _proxyUrl(token, targetUrl);
  }

  String _proxyUrl(String token, String targetUrl) {
    final encoded = base64Url.encode(utf8.encode(targetUrl)).replaceAll('=', '');
    return 'http://127.0.0.1:${_server!.port}/r/$token/$encoded';
  }

  String _rewritePlaylist(String text, String token, String baseUrl) {
    final lines = text.split('\n');
    final out = <String>[];
    final keyUri = RegExp(r'URI="([^"]+)"');
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        out.add(line);
        continue;
      }
      if (trimmed.startsWith('#')) {
        if (trimmed.startsWith('#EXT-X-KEY') ||
            trimmed.startsWith('#EXT-X-MAP')) {
          out.add(
            line.replaceAllMapped(keyUri, (match) {
              final resolved = _resolveUrl(baseUrl, match.group(1)!);
              return 'URI="${_proxyUrl(token, resolved)}"';
            }),
          );
        } else {
          out.add(line);
        }
        continue;
      }
      out.add(_proxyUrl(token, _resolveUrl(baseUrl, trimmed)));
    }
    return out.join('\n');
  }

  String _resolveUrl(String baseUrl, String ref) {
    if (ref.isEmpty) return baseUrl;
    final base = Uri.tryParse(baseUrl);
    final rel = Uri.tryParse(ref);
    if (base == null || rel == null) return ref;
    return base.resolveUri(rel).toString();
  }

  Future<void> _handle(HttpRequest request) async {
    try {
      final segments = request.uri.pathSegments;
      if (segments.length < 2 || segments[0] != 'r') {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('not found');
        await request.response.close();
        return;
      }
      final token = segments[1];
      final session = _sessions[token];
      if (session == null) {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('session expired');
        await request.response.close();
        return;
      }
      var target = '';
      if (segments.length > 2) {
        final encoded = segments.sublist(2).join('/');
        final padded = encoded + ('=' * ((4 - encoded.length % 4) % 4));
        target = utf8.decode(base64Url.decode(padded));
      } else {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('missing target');
        await request.response.close();
        return;
      }
      final headers = Map<String, String>.from(session.headers);
      final rangeHeader = request.headers.value(HttpHeaders.rangeHeader);
      if (rangeHeader != null) headers[HttpHeaders.rangeHeader] = rangeHeader;
      final upstream = await _client
          .get(Uri.parse(target), headers: headers)
          .timeout(const Duration(seconds: 30));
      final isPlaylist =
          (upstream.headers['content-type'] ?? '').contains('mpegurl') ||
              target.split('?').first.toLowerCase().endsWith('.m3u8');
      final response = request.response;
      response.statusCode = upstream.statusCode;
      final contentRange = upstream.headers['content-range'];
      if (contentRange != null) {
        response.headers.set(HttpHeaders.contentRangeHeader, contentRange);
      }
      final acceptRanges = upstream.headers['accept-ranges'];
      if (acceptRanges != null) {
        response.headers.set(HttpHeaders.acceptRangesHeader, acceptRanges);
      }
      if (isPlaylist && upstream.statusCode == 200) {
        final rewritten = _rewritePlaylist(
          utf8.decode(upstream.bodyBytes, allowMalformed: true),
          token,
          target,
        );
        final bytes = utf8.encode(rewritten);
        response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl', charset: 'utf-8');
        response.headers.contentLength = bytes.length;
        response.add(bytes);
      } else {
        final contentType = upstream.headers['content-type'];
        if (contentType != null) {
          response.headers.set(HttpHeaders.contentTypeHeader, contentType);
        }
        response.headers.contentLength = upstream.bodyBytes.length;
        response.add(upstream.bodyBytes);
      }
      await response.close();
    } catch (_) {
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('proxy error');
        await request.response.close();
      } catch (_) {}
    }
  }

  String _randomToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
