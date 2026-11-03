import 'dart:convert';

enum PlayUrlKind { video, novel, pics, audio }

class NovelPayload {
  const NovelPayload({required this.title, required this.content});

  final String title;
  final String content;
}

PlayUrlKind classifyPlayUrl(String url) {
  final trimmed = url.trim();
  if (trimmed.startsWith('novel://')) return PlayUrlKind.novel;
  if (trimmed.startsWith('pics://')) return PlayUrlKind.pics;
  if (isAudioUrl(trimmed)) return PlayUrlKind.audio;
  return PlayUrlKind.video;
}

bool isAudioUrl(String url) {
  final path = url.split('?').first.split('#').first.toLowerCase();
  const extensions = ['.mp3', '.m4a', '.aac', '.flac', '.ogg', '.opus', '.wav'];
  return extensions.any(path.endsWith);
}

NovelPayload parseNovelPayload(String url) {
  final raw = url.trim().substring('novel://'.length);
  final decoded = jsonDecode(raw);
  if (decoded is! Map<String, dynamic>) {
    throw StateError('小说内容不是合法的 JSON 对象');
  }
  return NovelPayload(
    title: '${decoded['title'] ?? ''}',
    content: '${decoded['content'] ?? ''}',
  );
}

List<String> parsePicsUrls(String url) {
  final raw = url.trim().substring('pics://'.length);
  return raw.split('&&').map((part) => part.trim()).where((part) => part.isNotEmpty).toList();
}
