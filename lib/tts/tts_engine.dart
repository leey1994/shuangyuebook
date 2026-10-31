// 朗读引擎抽象：把「合成 + 播放」与「队列状态机」分开。
//
// 三个实现：
//  - [EdgeTtsEngine] 在线音色（Edge TTS）→ 本地 mp3 → audioplayers；
//  - [HttpTtsEngine] 自定义 HTTP TTS（OpenAI 兼容）→ 本地 mp3 → audioplayers；
//  - [SystemTtsEngine] 系统语音（Android TTS / Windows SAPI）→ flutter_tts。
//
// 语义约定（队列依赖）：
//  - `speak()` 返回的 Future 在「这一段读完 / 被 stop / 出错」时完成；
//  - `pause()` 立刻静音（Edge/HTTP 真暂停；系统引擎不支持续播时立即 stop，
//    由队列在恢复时重读本句）；
//  - `stop()` 必须解除挂起的 `speak()`，否则队列会永远等下去。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../edge_tts.dart';
import '../http_tts.dart';

abstract class TtsEngine {
  /// 应用音色 / 语速 / 音调（切换音色或改设置后调用）。
  Future<void> prepare({
    required String voiceId,
    required double rate,
    required double pitch,
  });

  /// 朗读一句：完成时返回。
  Future<void> speak(String text);

  /// 立即静音。`canResumeMidSentence` 为 false 时等价于「停止本句」。
  Future<void> pause();

  /// 从暂停处继续（不支持续播的引擎由队列重读本句）。
  Future<void> resume();

  Future<void> stop();

  /// 播放音量（0~1，定时淡出用）。默认无操作。
  Future<void> setVolume(double v) async {}

  /// 预合成（无缓存的引擎空实现）。
  Future<void> precache(String text) async {}

  /// 是否能从句子中间续播（播放器引擎可以，系统引擎看实现）。
  bool get canResumeMidSentence => true;

  Future<void> dispose();
}

/// 「合成出来存成 mp3，再用 audioplayers 播」的公共部分。
///
/// 边合成边写缓存：同一句第二次播放零网络。缓存 key 含引擎标签与音色，
/// 同一文本在 Edge / HTTP 之间不会串味。
abstract class _PlayerTtsEngine implements TtsEngine {
  _PlayerTtsEngine({required this.cacheDir, required this.cacheTag});

  /// 缓存目录（`<cache>/tts`）。
  final Directory cacheDir;

  /// 引擎标签（写进缓存 key，避免不同端点/音色共用同一文件）。
  final String cacheTag;

  final AudioPlayer _player = AudioPlayer();
  Completer<void>? _active;
  double _rate = 0.5;
  bool _paused = false;
  bool _stopped = false;
  DateTime _lastPrune = DateTime.fromMillisecondsSinceEpoch(0);
  StreamSubscription<void>? _sub;

  /// 缓存上限（字节）：超出后按修改时间淘汰最旧的。
  static const int cacheLimitBytes = 400 * 1024 * 1024;

  /// 子类合成这一句（缓存未命中时调用）。失败直接抛。
  Future<Uint8List> synthText(String text);

  /// 音色/端点，参与缓存 key。
  String get cacheVoice => '';

  void _bind() {
    _sub ??= _player.onPlayerComplete.listen((_) {
      _active?.complete();
      _active = null;
    });
  }

  @override
  bool get canResumeMidSentence => true;

  @override
  Future<void> prepare({
    required String voiceId,
    required double rate,
    required double pitch,
  }) async {
    _rate = rate;
    _bind();
    await _player.setReleaseMode(ReleaseMode.stop);
  }

  @override
  Future<void> speak(String text) async {
    _stopped = false;
    _paused = false;
    final path = await _file(text);
    // 合成期间被 stop：不播
    if (_stopped) throw const _Aborted();
    final c = Completer<void>();
    _active = c;
    await _player.setPlaybackRate((_rate * 2).clamp(0.5, 2.0));
    await _player.play(DeviceFileSource(path));
    if (_paused) {
      try {
        await _player.pause();
      } catch (_) {}
    }
    try {
      await c.future;
    } finally {
      if (identical(_active, c)) _active = null;
    }
  }

  @override
  Future<void> pause() async {
    _paused = true;
    try {
      await _player.pause();
    } catch (_) {}
  }

  @override
  Future<void> resume() async {
    _paused = false;
    try {
      await _player.resume();
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    _stopped = true;
    _paused = false;
    final c = _active;
    _active = null;
    if (c != null && !c.isCompleted) c.complete();
    try {
      await _player.stop();
    } catch (_) {}
  }

  @override
  Future<void> setVolume(double v) async {
    try {
      await _player.setVolume(v.clamp(0.0, 1.0));
    } catch (_) {}
  }

  @override
  Future<void> precache(String text) async {
    try {
      await _file(text);
    } catch (_) {
      // 预取失败不影响主链路（播放时会再试一次并走回退）
    }
  }

  /// 取（或合成）本地 mp3；缓存命中零网络。
  Future<String> _file(String text) async {
    final key = sha1
        .convert(utf8.encode('$cacheTag|$cacheVoice|$text'))
        .toString()
        .substring(0, 24);
    final f = File('${cacheDir.path}/$key.mp3');
    if (await f.exists() && await f.length() > 500) return f.path;
    final bytes = await synthText(text);
    await f.writeAsBytes(bytes, flush: true);
    unawaited(_pruneIfNeeded());
    return f.path;
  }

  static const Set<String> _keepDirs = {'tts'};

  /// 缓存淘汰：最多每 60 秒扫一次，按修改时间删最旧的 20%。
  Future<void> _pruneIfNeeded() async {
    final now = DateTime.now();
    if (now.difference(_lastPrune).inSeconds < 60) return;
    _lastPrune = now;
    try {
      final files = <File>[];
      var total = 0;
      await for (final e in cacheDir.list()) {
        if (e is Directory && _keepDirs.contains(e.uri.pathSegments.last)) {
          continue;
        }
        if (e is File && e.path.endsWith('.mp3')) {
          final len = await e.length();
          total += len;
          files.add(e);
        }
      }
      if (total <= cacheLimitBytes) return;
      files.sort((a, b) => a.statSync().modified.compareTo(b.statSync().modified));
      final target = (total - cacheLimitBytes * 0.8).round();
      var freed = 0;
      for (final f in files) {
        if (freed >= target) break;
        try {
          final len = await f.length();
          await f.delete();
          freed += len;
        } catch (_) {}
      }
      debugPrint('[tts] 缓存清理：释放 ${(freed / 1048576).toStringAsFixed(1)}MB');
    } catch (_) {}
  }

  @override
  Future<void> dispose() async {
    await _sub?.cancel();
    try {
      await _player.dispose();
    } catch (_) {}
  }
}

/// 在线音色：Edge TTS 合成 mp3 → 本地缓存 → audioplayers 播放。
class EdgeTtsEngine extends _PlayerTtsEngine {
  EdgeTtsEngine({required super.cacheDir}) : super(cacheTag: 'edge');

  String _voice = 'zh-CN-XiaoxiaoNeural';
  double _pitch = 1.0;

  @override
  String get cacheVoice => _voice;

  @override
  Future<void> prepare({
    required String voiceId,
    required double rate,
    required double pitch,
  }) async {
    _voice = voiceId.isEmpty ? _voice : voiceId;
    _pitch = pitch;
    await super.prepare(voiceId: voiceId, rate: rate, pitch: pitch);
  }

  @override
  Future<Uint8List> synthText(String text) => EdgeTts.synth(
        text,
        voice: _voice,
        pitch: _pitchString(_pitch),
        // 语速在播放层生效（缓存可跨语速复用）
        rate: '+0%',
      );

  static String _pitchString(double pitch) {
    // pitch 0.5~2.0 → -50% ~ +100%，步进 10%
    final pct = ((pitch - 1.0) * 100).round();
    final clamped = pct.clamp(-50, 100);
    return '${clamped >= 0 ? '+' : ''}$clamped%';
  }
}

/// 自定义 HTTP TTS（OpenAI 兼容）：POST 端点 → mp3 字节 → 本地缓存。
class HttpTtsEngine extends _PlayerTtsEngine {
  HttpTtsEngine({
    required super.cacheDir,
    required this.endpoint,
    this.apiKey = '',
    this.voice = 'alloy',
    this.model = 'tts-1',
  }) : super(cacheTag: 'http');

  final String endpoint;
  final String apiKey;
  final String voice;
  final String model;

  @override
  String get cacheVoice => '$endpoint|$voice|$model';

  @override
  Future<Uint8List> synthText(String text) => HttpTts.synth(
        text,
        endpoint: endpoint,
        apiKey: apiKey,
        voice: voice,
        model: model,
      );
}

/// 系统语音：flutter_tts（Android TTS / Windows SAPI）。
class SystemTtsEngine implements TtsEngine {
  /// [tts] 可复用阅读器已有的实例（音色由那边选好后直接生效）。
  SystemTtsEngine([FlutterTts? tts]) : _tts = tts ?? FlutterTts();

  final FlutterTts _tts;
  Completer<void>? _active;
  bool _paused = false;
  bool _installed = false;

  void _install() {
    if (_installed) return;
    _installed = true;
    _tts.setCompletionHandler(_done);
    _tts.setCancelHandler(_done);
    _tts.setErrorHandler((_) => _done());
  }

  void _done() {
    final c = _active;
    _active = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// 系统引擎停掉后无法从句子中间续播，恢复时由队列重读本句。
  @override
  bool get canResumeMidSentence => false;

  @override
  Future<void> prepare({
    required String voiceId,
    required double rate,
    required double pitch,
  }) async {
    _install();
    try {
      await _tts.setSpeechRate(rate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(pitch);
      await _tts.setLanguage('zh-CN');
    } catch (_) {}
  }

  @override
  Future<void> speak(String text) async {
    _install();
    _paused = false;
    final c = Completer<void>();
    _active = c;
    try {
      await _tts.speak(text);
    } catch (e) {
      _done();
      rethrow;
    }
    await c.future;
  }

  @override
  Future<void> pause() async {
    _paused = true;
    try {
      await _tts.pause();
    } catch (_) {
      // Windows SAPI 等不支持 pause：直接停，恢复时重读本句
    }
    _done();
  }

  @override
  Future<void> resume() async {
    _paused = false; // 队列据此重读当前句
  }

  @override
  Future<void> stop() async {
    _paused = false;
    _done();
    try {
      await _tts.stop();
    } catch (_) {}
  }

  bool get isPaused => _paused;

  @override
  Future<void> setVolume(double v) async {
    try {
      await _tts.setVolume(v.clamp(0.0, 1.0));
    } catch (_) {}
  }

  /// 系统引擎没有合成缓存，预取是空操作。
  @override
  Future<void> precache(String text) async {}

  @override
  Future<void> dispose() async {
    try {
      await _tts.stop();
    } catch (_) {}
  }
}

class _Aborted implements Exception {
  const _Aborted();
}
