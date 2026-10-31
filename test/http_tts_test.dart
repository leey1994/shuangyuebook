// 自定义 HTTP TTS：请求体/鉴权/错误路径，用本地 HttpServer 驱动。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/http_tts.dart';

void main() {
  test('POST 端点：带 model/input/voice/format，返回 mp3 字节', () async {
    late Map<String, dynamic> body;
    late String? auth;
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((req) async {
      auth = req.headers.value('authorization');
      body = jsonDecode(await utf8.decoder.bind(req).join()) as Map<String, dynamic>;
      req.response.headers.contentType = ContentType('audio', 'mpeg');
      req.response.add(Uint8List(2048)..fillRange(0, 2048, 7));
      await req.response.close();
    });

    final bytes = await HttpTts.synth(
      '你好。',
      endpoint: 'http://127.0.0.1:${server.port}/v1/audio/speech',
      apiKey: 'sk-test',
      voice: 'nova',
      model: 'tts-1',
    );

    expect(bytes.length, 2048);
    expect(body['input'], '你好。');
    expect(body['voice'], 'nova');
    expect(body['model'], 'tts-1');
    expect(body['response_format'], 'mp3');
    expect(auth, 'Bearer sk-test');

    await sub.cancel();
    await server.close(force: true);
  });

  test('非 200 抛错并带状态码', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final sub = server.listen((req) async {
      req.response.statusCode = 401;
      req.response.write('{"error":"bad key"}');
      await req.response.close();
    });

    await expectLater(
      HttpTts.synth('x', endpoint: 'http://127.0.0.1:${server.port}/tts'),
      throwsA(isA<HttpTtsException>()
          .having((e) => e.message, 'message', contains('401'))),
    );

    await sub.cancel();
    await server.close(force: true);
  });

  test('空文本 / 非法端点直接拒绝', () async {
    expect(() => HttpTts.synth('  ', endpoint: 'http://x'),
        throwsA(isA<HttpTtsException>()));
    expect(() => HttpTts.synth('x', endpoint: 'not a url'),
        throwsA(isA<HttpTtsException>()));
  });
}
