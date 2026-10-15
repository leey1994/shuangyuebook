// Edge TTS 自检：合成一句并写出 mp3，验证协议/网络/签名/情感风格。
// 用法：dart run tool/edge_smoke.dart [文本] [音色] [plain]
//   plain = 传空风格强制平铺（用来和默认情感风格对比）。
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:shuangyue/edge_tts.dart';

Future<void> main(List<String> args) async {
  final text = args.isNotEmpty ? args.first : '你好，这是爽阅在线语音合成自检。';
  final voice = args.length > 1 ? args[1] : EdgeTts.voiceHsiaoChen;
  final plain = args.length > 2 && args[2] == 'plain';
  final t0 = DateTime.now();
  try {
    final bytes =
        await EdgeTts.synth(text, voice: voice, expressive: !plain);
    final f = File('build/edge_smoke${plain ? '_plain' : ''}.mp3')
      ..createSync(recursive: true);
    f.writeAsBytesSync(bytes);
    print('OK voice=$voice style=${plain ? '(plain)' : '(default)'} '
        'bytes=${bytes.length} in ${DateTime.now().difference(t0).inMilliseconds}ms '
        '-> ${f.path}');
  } catch (e) {
    print('FAIL voice=$voice after '
        '${DateTime.now().difference(t0).inMilliseconds}ms: $e');
    exitCode = 1;
  }
}
