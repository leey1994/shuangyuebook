import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter_tts/flutter_tts.dart';

import 'edge_tts.dart';

/// 崩溃定位自检：`novel_reader.exe --tts-smoke`
/// 日志直写文件（同步 append，原生崩溃不丢），最后一行 = 崩点。
Future<void> ttsSmoke() async {
  final log = File('${Directory.systemTemp.path}/tts_smoke_log.txt');
  try {
    if (log.existsSync()) log.deleteSync();
  } catch (_) {}
  void log1(String s) {
    try {
      log.writeAsStringSync('${DateTime.now().toIso8601String()} $s\n',
          mode: FileMode.append);
    } catch (_) {}
  }

  log1('START version=${Platform.localHostname}');
  FlutterTts tts;
  try {
    tts = FlutterTts();
    log1('FlutterTts() OK');
  } catch (e) {
    log1('FlutterTts() ERR $e');
    return;
  }

  Future<void> step(String name, Future<dynamic> Function() f) async {
    log1('$name BEGIN');
    try {
      await f();
      log1('$name OK');
    } catch (e) {
      log1('$name ERR $e');
    }
  }

  await step('rate', () => tts.setSpeechRate(0.5));
  await step('volume', () => tts.setVolume(1.0));
  await step('pitch', () => tts.setPitch(1.0));
  await step('lang', () => tts.setLanguage('zh-CN'));
  await step('voices', () async {
    final v = await tts.getVoices;
    log1('voices raw=$v');
    if (v is List) {
      // 优先验证 OneCore 音色（Kangkang），其次任意中文音色
      Map<String, String>? kangkang, zhAny;
      for (final x in v) {
        if (x is! Map) continue;
        final name = x['name']?.toString() ?? '';
        final s = x.values.join(' ').toLowerCase();
        if (name.toLowerCase().contains('kangkang')) {
          kangkang = Map<String, String>.from(
              x.map((k, val) => MapEntry(k.toString(), val.toString())));
        } else if (s.contains('zh') || s.contains('chinese')) {
          zhAny ??= Map<String, String>.from(
              x.map((k, val) => MapEntry(k.toString(), val.toString())));
        }
      }
      final pick = kangkang ?? zhAny;
      if (pick != null) {
        await tts.setVoice(pick);
        log1('picked=$pick');
      }
    }
  });
  tts.setCompletionHandler(() => log1('EVENT complete'));
  tts.setCancelHandler(() => log1('EVENT cancel'));
  tts.setErrorHandler((e) => log1('EVENT error $e'));
  await step('speak', () => tts.speak('今天天气不错，我们出去散散步吧。'));
  await Future<void>.delayed(const Duration(seconds: 4));
  log1('after-4s-wait');
  await step('stop', () => tts.stop());
  await Future<void>.delayed(const Duration(seconds: 1));

  // ---- 在线音色（Edge TTS）：合成 → 缓存文件 → 播放 ----
  final mp3 = '${Directory.systemTemp.path}/edge_smoke.mp3';
  await step('edge-synth', () async {
    final bytes =
        await EdgeTts.synth('今天天气不错，我们出去散散步吧。');
    log1('edge mp3 ${bytes.length}B');
    File(mp3).writeAsBytesSync(bytes);
  });
  final ap = AudioPlayer();
  await step('edge-play', () async {
    ap.onPlayerComplete.listen((_) => log1('edge EVENT complete'));
    await ap.play(DeviceFileSource(mp3));
    log1('edge play started');
  });
  await Future<void>.delayed(const Duration(seconds: 3));
  log1('edge after-3s-wait');
  await step('edge-stop', () => ap.stop());
  await step('edge-dispose', () => ap.dispose());

  log1('DONE');
  exit(0);
}
