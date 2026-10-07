// Edge TTS 双音色真实合成自检（M1 门槛）：dart run tool/edge_smoke.dart
// 断言两个台湾腔音色各合成出非平凡 MP3（首字节 ID3 或帧同步，>5000B），
// 落盘 build/tmp/edge_<voice>.mp3 供人工试听。
import 'dart:io';

import 'package:novel_reader/edge_tts.dart';

Future<void> main() async {
  Directory('build/tmp').createSync(recursive: true);
  const text = '夜色渐深，窗外的月光洒在书页上，他轻轻翻过一页，继续读了下去。';
  var failed = false;
  for (final voice in [EdgeTts.voiceHsiaoChen, EdgeTts.voiceHsiaoYu]) {
    final sw = Stopwatch()..start();
    try {
      final bytes = await EdgeTts.synth(text, voice: voice);
      sw.stop();
      final head = String.fromCharCodes(
          bytes.take(3).map((b) => b >= 0x20 && b < 0x7F ? b : 0x2E));
      final id3 = head == 'ID3';
      final sync = bytes.length >= 2 &&
          bytes[0] == 0xFF &&
          (bytes[1] & 0xE0) == 0xE0;
      final ok = bytes.length > 5000 && (id3 || sync);
      final f = File(
          'build/tmp/edge_${voice.replaceAll('-', '_')}.mp3')
        ..writeAsBytesSync(bytes);
      stdout.writeln(
          '$voice: ${bytes.length}B ${sw.elapsedMilliseconds}ms '
          'head=$head id3=$id3 sync=$sync -> ${f.path} ${ok ? "OK" : "FAIL"}');
      if (!ok) failed = true;
    } catch (e) {
      sw.stop();
      stdout.writeln('$voice: ERR ${sw.elapsedMilliseconds}ms $e');
      failed = true;
    }
  }
  stdout.writeln(failed ? 'EDGE_SMOKE_FAIL' : 'EDGE_SMOKE_OK');
  exit(failed ? 1 : 0);
}
