// 句子队列：朗读的「播放器」。
//
// 职责边界：
//  - 本类只管「第几句、放/停/上一句/下一句、跨章、预取」；
//  - 音色合成与音频输出全部交给 [TtsEngine]（可替换、可假实现）；
//  - 断句交给 [splitChapter]。
//
// 关键语义（旧实现缺的就是这些）：
//  - `pause()` 是真暂停：Edge 引擎从句子中间续播，系统引擎停掉本句、
//    恢复时重读本句（[TtsEngine.canResumeMidSentence]）；
//  - 暂停期间读完的句子不推进游标，恢复后不会跳句；
//  - `next/prev/stop` 用代号（`_gen`）作废在途的 `speak()`，不会出现
//    「上一句按了但旧句子读完又把它顶回去」；
//  - 预取窗口只看后 N 句，命中缓存后拖动游标不重复合成。
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'sentence.dart';
import 'text_clean.dart';
import 'tts_engine.dart';

enum TtsState { idle, playing, paused }

/// 一章的朗读输入（由上层 loader 提供，队列不碰章节来源）。
class TtsChapter {
  const TtsChapter({required this.title, required this.paras});

  final String title;
  final List<String> paras;
}

/// 取下一章；返回 null 表示全书读完 / 加载失败。
typedef TtsChapterLoader = Future<TtsChapter?> Function();

class TtsQueue extends ChangeNotifier {
  TtsQueue({
    required this.engine,
    required this.loader,
    this.prefetchWindow = 3,
    this.maxSentenceLen = 120,
    this.onError,
    this.onChapter,
  });

  /// 可整体替换（在线合成失败后切系统引擎）。
  TtsEngine engine;

  /// 可替换：阅读器销毁后由控制器改成「本章读完即停」。
  TtsChapterLoader loader;

  /// 预取后 N 句。
  final int prefetchWindow;

  final int maxSentenceLen;

  /// 单句播放失败（非 stop/seek 导致）时回调；队列随后重试一次。
  void Function(Object error)? onError;

  /// 跨章成功后回调，供 UI 同步章节/正文（高亮用）。
  void Function(TtsChapter chapter)? onChapter;

  List<Sentence> _sentences = const [];
  String _title = '';
  int _cursor = 0;
  int _retried = 0;
  bool _running = false;
  bool _paused = false;
  bool _finished = false;
  int _gen = 0;
  Completer<void>? _resumeGate;
  Future<void>? _loop;
  Sentence? _current;

  TtsState get state {
    if (!_running) return TtsState.idle;
    return _paused ? TtsState.paused : TtsState.playing;
  }

  bool get isRunning => _running;

  bool get isPaused => _paused;

  /// 读完全书/加载失败而自然结束（区别于用户 stop）。
  bool get finished => _finished;

  Sentence? get current => _current;

  /// 当前句所在段落下标（滚动跟随 / 高亮容器）。
  int get currentPara => _current?.para ?? -1;

  String get chapterTitle => _title;

  int get index => _cursor;

  int get total => _sentences.length;

  bool get canPrev => _running && _cursor > 0;
  bool get canNext => _running;

  /// 装载一章（不自动播放）。
  void load(
    List<String> paras, {
    String title = '',
    int para = 0,
    int sentence = 0,
  }) {
    _title = title;
    _sentences = splitChapter(paras, maxLen: maxSentenceLen);
    _cursor = _cursorFor(para, sentence);
    _current = _cursor < _sentences.length ? _sentences[_cursor] : null;
    _finished = false;
    notifyListeners();
  }

  /// 从当前游标开播；`para`/`sentence` 非空时先定位（断点续听）。
  Future<void> play({int? para, int? sentence}) async {
    if (_running) return _loop;
    if (_sentences.isEmpty) return;
    if (para != null) _cursor = _cursorFor(para, sentence ?? 0);
    _current = _cursor < _sentences.length ? _sentences[_cursor] : null;
    _running = true;
    _paused = false;
    _finished = false;
    _retried = 0;
    _gen++;
    notifyListeners();
    final f = _run();
    _loop = f;
    await f;
  }

  /// 音量（定时淡出用）；切句不会重置。
  Future<void> setVolume(double v) => engine.setVolume(v);

  Future<void> pause() async {
    if (!_running || _paused) return;
    _paused = true;
    _resumeGate ??= Completer<void>();
    notifyListeners();
    await engine.pause();
  }

  Future<void> resume() async {
    if (!_running || !_paused) return;
    _paused = false;
    final g = _resumeGate;
    _resumeGate = null;
    notifyListeners();
    await engine.resume(); // 不支持句内续播的引擎由循环重读本句
    g?.complete();
  }

  Future<void> toggle() => _paused ? resume() : pause();

  /// 下一句（越过本章末尾时自动进下一章）。
  void nextSentence() => _seekTo(_cursor + 1);

  /// 上一句。
  void prevSentence() => _seekTo(_cursor <= 0 ? 0 : _cursor - 1);

  /// 跳到某段第一句（目录/进度条拖动用）。
  void jumpToPara(int para) {
    final i = _cursorFor(para, 0);
    if (i != _cursor) _seekTo(i);
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _paused = false;
    _finished = false;
    _gen++;
    final g = _resumeGate;
    _resumeGate = null;
    g?.complete();
    notifyListeners();
    await engine.stop();
    await _loop; // 循环会自己退出；等它清完状态再返回
  }

  void _seekTo(int i) {
    if (!_running) return;
    _cursor = i;
    _retried = 0;
    _gen++;
    _current = i < _sentences.length ? _sentences[i] : _current;
    notifyListeners();
    unawaited(engine.stop()); // 解除在途 speak()，循环下一轮读新句
  }

  int _cursorFor(int para, int sentence) {
    if (_sentences.isEmpty) return 0;
    if (para <= 0 && sentence <= 0) return 0;
    var seen = 0;
    for (var i = 0; i < _sentences.length; i++) {
      final s = _sentences[i];
      if (s.para < para) continue;
      if (s.para > para) return i;
      if (seen == sentence) return i;
      seen++;
    }
    return _sentences.length;
  }

  Future<void> _run() async {
    try {
      while (_running) {
        if (_paused) {
          final g = _resumeGate ??= Completer<void>();
          await g.future;
          if (!_running) break;
          continue;
        }
        if (_cursor >= _sentences.length) {
          if (!await _loadNext()) {
            _finished = true;
            break;
          }
          continue;
        }
        final s = _sentences[_cursor];
        final spoken = cleanForSpeech(s.text);
        if (!hasSpeakableText(spoken)) {
          // 纯符号/只剩网址的句子不读，但不影响偏移与断点
          _cursor++;
          continue;
        }

        _current = s;
        notifyListeners();
        _prefetchFrom(_cursor + 1);

        final gen = ++_gen; // 本轮有效代号；seek/stop 会再 +1
        final seconds = (s.text.length * 0.4 + 20).toInt();
        try {
          await engine
              .speak(spoken)
              .timeout(Duration(seconds: seconds), onTimeout: engine.stop);
        } catch (e) {
          if (!_running || gen != _gen) continue;
          if (_retried == 0) {
            _retried = 1;
            onError?.call(e);
            continue; // 重试本句一次
          }
          _retried = 0;
          onError?.call(e);
          _cursor++; // 还是失败：跳过，避免死循环
          continue;
        }

        if (!_running || gen != _gen) continue;
        if (_paused) continue; // 暂停期间读完：不推进，恢复后重读本句
        _cursor++;
        _retried = 0;
      }
    } finally {
      _running = false;
      _paused = false;
      _resumeGate = null;
      _gen++;
      _loop = null;
      notifyListeners();
    }
  }

  Future<bool> _loadNext() async {
    TtsChapter? c;
    try {
      c = await loader();
    } catch (_) {
      c = null;
    }
    if (!_running || c == null) return false;
    _title = c.title;
    _sentences = splitChapter(c.paras, maxLen: maxSentenceLen);
    _cursor = 0;
    _retried = 0;
    onChapter?.call(c);
    notifyListeners();
    return _sentences.isNotEmpty;
  }

  void _prefetchFrom(int start) {
    if (prefetchWindow <= 0) return;
    final end = (start + prefetchWindow).clamp(0, _sentences.length);
    for (var i = start; i < end; i++) {
      final t = cleanForSpeech(_sentences[i].text);
      if (!hasSpeakableText(t)) continue;
      unawaited(engine.precache(t).catchError((_) {}));
    }
  }

  @override
  void dispose() {
    _running = false;
    _gen++;
    final g = _resumeGate;
    _resumeGate = null;
    g?.complete();
    unawaited(engine.stop());
    super.dispose();
  }
}
