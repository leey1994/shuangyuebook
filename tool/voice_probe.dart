// 在线音色批量试音：dart run tool/voice_probe.dart
// 对 reader_screen 音色表里的 12 个 Edge TTS 音色各合成一小段，
// 校验 MP3 头（ID3/帧同步）与体量；落盘 build/tmp/voice_<id>.mp3 供试听。
import 'dart:io';

import 'package:novel_reader/edge_tts.dart';

const voices = <String, String>{
  '小臻': 'zh-TW-HsiaoChenNeural',
  '小瑜': 'zh-TW-HsiaoYuNeural',
  '晓晓': 'zh-CN-XiaoxiaoNeural',
  '云希': 'zh-CN-YunxiNeural',
  '云健': 'zh-CN-YunjianNeural',
  '云夏': 'zh-CN-YunxiaNeural',
  '晓伊': 'zh-CN-XiaoyiNeural',
  '云扬': 'zh-CN-YunyangNeural',
  '晓北': 'zh-CN-liaoning-XiaobeiNeural',
  '晓妮': 'zh-CN-shaanxi-XiaoniNeural',
  '晓曼': 'zh-HK-HiuMaanNeural',
  '云哲': 'zh-TW-YunJheNeural',
};

Future<void> main() async {
  Directory('build/tmp').createSync(recursive: true);
  const text = '你好，这是音色试听。';
  var failed = false;
  for (final e in voices.entries) {
    final sw = Stopwatch()..start();
    try {
      final bytes = await EdgeTts.synth(text, voice: e.value);
      sw.stop();
      final id3 = bytes.length >= 3 &&
          String.fromCharCodes(bytes.take(3)) == 'ID3';
      final sync = bytes.length >= 2 &&
          bytes[0] == 0xFF &&
          (bytes[1] & 0xE0) == 0xE0;
      final ok = bytes.length > 2000 && (id3 || sync);
      File('build/tmp/voice_${e.value.replaceAll('-', '_')}.mp3')
          .writeAsBytesSync(bytes);
      stdout.writeln(
          '${e.key}(${e.value}): ${bytes.length}B ${sw.elapsedMilliseconds}ms '
          '${ok ? "OK" : "FAIL"}');
      if (!ok) failed = true;
    } catch (e2) {
      sw.stop();
      stdout.writeln('${e.key}(${e.value}): ERR ${sw.elapsedMilliseconds}ms $e2');
      failed = true;
    }
  }
  stdout.writeln(failed ? 'VOICE_PROBE_FAIL' : 'VOICE_PROBE_OK');
  exit(failed ? 1 : 0);
}
