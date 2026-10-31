// 自定义 HTTP TTS（OpenAI 兼容 `/v1/audio/speech` / 自建 `/api/tts`）。
//
// 请求：POST <endpoint>
//   Authorization: Bearer <key>（key 为空则不带）
//   Content-Type: application/json
//   {"model":"tts-1","input":"…","voice":"alloy","response_format":"mp3"}
// 响应：audio/mpeg 原始字节。
//
// 纯 dart:io，无 Flutter 依赖，可被单测用本地 HttpServer 驱动。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

class HttpTtsException implements Exception {
  const HttpTtsException(this.message);

  final String message;

  @override
  String toString() => 'HttpTtsException: $message';
}

class HttpTts {
  HttpTts._();

  static Future<Uint8List> synth(
    String text, {
    required String endpoint,
    String apiKey = '',
    String voice = 'alloy',
    String model = 'tts-1',
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final clean = text.trim();
    if (clean.isEmpty) throw const HttpTtsException('文本为空');
    final uri = Uri.tryParse(endpoint);
    if (uri == null || !uri.hasScheme) {
      throw const HttpTtsException('端点地址无效');
    }
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.postUrl(uri).timeout(const Duration(seconds: 12));
      req.headers.contentType = ContentType.json;
      req.headers.set('Accept', 'audio/mpeg, audio/*');
      if (apiKey.isNotEmpty) {
        req.headers.set('Authorization', 'Bearer $apiKey');
      }
      req.add(utf8.encode(jsonEncode({
        'model': model,
        'input': clean,
        'voice': voice,
        'response_format': 'mp3',
      })));
      final resp = await req.close().timeout(timeout);
      final buf = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        buf.add(chunk);
      }
      final bytes = buf.takeBytes();
      if (resp.statusCode != 200) {
        final body = _short(utf8.decode(bytes, allowMalformed: true));
        throw HttpTtsException('HTTP ${resp.statusCode} $body');
      }
      if (bytes.length < 512) throw const HttpTtsException('合成结果为空');
      return bytes;
    } on HttpTtsException {
      rethrow;
    } on TimeoutException {
      throw const HttpTtsException('合成超时');
    } catch (e) {
      throw HttpTtsException('$e');
    } finally {
      client.close(force: true);
    }
  }

  static String _short(String s) => s.length > 200 ? '${s.substring(0, 200)}…' : s;
}
