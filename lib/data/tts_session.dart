// 全局听书会话（后台播放的核心）。
//
// 为什么在阅读器之外：以前朗读循环住在 ReaderScreen 的 State 里，
// `while (_speaking && mounted)` —— 退出阅读器循环就死了，听书只能陪阅读器活着。
// 现在引擎、进度、跨章推进全部挂在这个单例上，阅读器只是它的一个「视图」：
//   - 进入阅读器 attach（监听本会话，同步高亮 / 面板 / 跟随滚动）；
//   - 退出阅读器 detach（会话继续读，跨章用 AppStore.chapterText 后台加载）；
//   - 主界面底部的悬浮播放条也读这里。
//
// 朗读粒度：段落 → 逐句（splitSentences）。整段一口气读有两个毛病：
// 引擎对长文本容易截断/挂死，而且中途暂停/跳句粒度太粗。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../edge_tts.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../platform/tts_notify.dart';
import '../sources/source.dart';
import '../store.dart';
import '../tts_voices.dart';

/// 把段落切成句子：。！？!?…；与换行处断句，紧跟的引号并回本句；
/// 超长句（引擎长文本容易卡）再按逗号二段切。
List<String> splitSentences(String para) {
  final out = <String>[];
  final buf = StringBuffer();

  void flush() {
    final t = buf.toString().trim();
    buf.clear();
    if (t.isNotEmpty) out.add(t);
  }

  for (var i = 0; i < para.length; i++) {
    final ch = para[i];
    buf.write(ch);
    if (ch == '。' || ch == '！' || ch == '？' || ch == '!' || ch == '?' ||
        ch == '…' || ch == '；' || ch == ';' || ch == '\n') {
      // 句末引号/括号跟随本句，不要孤立成段
      while (i + 1 < para.length &&
          '"\'’”』」》）)】'.contains(para[i + 1])) {
        i++;
        buf.write(para[i]);
      }
      flush();
    }
  }
  flush();

  // 超长句兜底：按逗号、顿号分摊
  const maxLen = 200;
  final out2 = <String>[];
  for (final s in out) {
    if (s.length <= maxLen) {
      out2.add(s);
      continue;
    }
    var cur = '';
    for (final seg in s.split(RegExp('[，,、]'))) {
      if (cur.length + seg.length + 1 > maxLen && cur.isNotEmpty) {
        out2.add(cur);
        cur = seg;
      } else {
        cur = cur.isEmpty ? seg : '$cur，$seg';
      }
    }
    if (cur.isNotEmpty) out2.add(cur);
  }
  return out2;
}

/// 全局朗读会话（单例）。
class TtsSession extends ChangeNotifier {
  TtsSession._();
  static final TtsSession I = TtsSession._();

  // ---- 会话状态（UI 只读） ----
  Book? _book;
  BookDetail? _detail;
  NovelSource? _source;
  int _chapterIndex = 0;
  List<String> _paras = const [];
  int _pIdx = 0; // 当前段
  int _sIdx = 0; // 段内句
  int _pCur = -1; // 正在朗读的段（高亮/进度显示用）
  bool _active = false;
  bool _paused = false;
  DateTime? _since;

  // ---- 引擎 ----
  final FlutterTts _tts = FlutterTts();
  AudioPlayer? _player; // 惰性创建：系统音色用不到播放器（测试环境也无插件）

  /// 播放完成信号依赖平台回调：系统 TTS 的 handler 在 [_applyVoice] 里注册
  /// （惰性，测试环境没有插件通道也不会炸）；在线播放器在此处挂接。
  AudioPlayer get _edgePlayer {
    var p = _player;
    if (p == null) {
      p = _player = AudioPlayer();
      p.onPlayerComplete.listen((_) => _finishUtter());
    }
    return p;
  }
  Completer<void>? _utter;
  bool _loopOn = false;
  bool _edgeBroken = false;
  List<Map<String, String>> _voices = const [];

  // ---- 定时停止 ----
  Timer? _sleepTimer;
  int _sleepMin = 0;
  DateTime? _sleepAt;

  /// 测试注入：替换真实朗读（立即完成）。
  @visibleForTesting
  Future<void> Function(String line)? debugSpeak;

  // ---------------- 只读状态 ----------------

  bool get active => _active;
  bool get paused => _paused;
  Book? get book => _book;
  int get chapterIndex => _chapterIndex;
  int get paraIndex => _pCur;
  int get paraCount => _paras.length;
  DateTime? get since => _since;
  List<Map<String, String>> get voices => _voices;
  int get sleepMinutes => _sleepMin;
  String get sleepLeft {
    final at = _sleepAt;
    if (at == null) return '';
    final left = at.difference(DateTime.now());
    if (left <= Duration.zero) return '0:00';
    return '${left.inMinutes}:${(left.inSeconds % 60).toString().padLeft(2, '0')}';
  }

  String get chapterTitle {
    final d = _detail;
    final i = _chapterIndex;
    if (d == null || i < 0 || i >= d.chapters.length) return '';
    return d.chapters[i].title;
  }

  /// 通知 / 悬浮条正文：正在读的那一句。
  String get currentLine {
    if (!_active) return '';
    if (_pCur < 0 || _pCur >= _paras.length) return '准备中…';
    final sents = splitSentences(_paras[_pCur]);
    final i = _sIdx.clamp(0, sents.isEmpty ? 0 : sents.length - 1);
    return sents.isEmpty ? '' : sents[i];
  }

  /// [b] 是否正在被朗读（阅读器据此决定面板/高亮是否生效）。
  bool isReading(Book b) => _active && _book?.url == b.url;

  // ---------------- 启动 / 停止 ----------------

  /// 开一场朗读。阅读器把已加载的章节文本直接递进来（免重复解析）。
  Future<void> start({
    required Book book,
    required BookDetail detail,
    required NovelSource source,
    required List<String> paras,
    required int chapterIndex,
    int startPara = 0,
  }) async {
    await stop(); // 换书 / 重开：先清旧会话
    _book = book;
    _detail = detail;
    _source = source;
    _chapterIndex = chapterIndex;
    _paras = List.of(paras);
    _pIdx = paras.isEmpty ? 0 : startPara.clamp(0, paras.length - 1);
    _sIdx = 0;
    _pCur = -1;
    _active = true;
    _paused = false;
    _since = DateTime.now();
    _edgeBroken = false; // 新一场播放：给在线合成重试机会
    await _applyVoice();
    TtsNotify.onAction = _onNotifyAction;
    unawaited(TtsNotify.requestPermission());
    _syncNotify();
    PetStore.I.emit(PetAction.ttsPlay);
    notifyListeners();
    unawaited(_loop());
  }

  /// 停止朗读并撤下通知。
  Future<void> stop() async {
    final was = _active;
    _active = false;
    _paused = false;
    _since = null;
    _pCur = -1;
    _finishUtter(); // 解除循环阻塞
    try {
      await _tts.stop();
    } catch (_) {}
    try {
      await _player?.stop();
    } catch (_) {}
    unawaited(TtsNotify.hide());
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepAt = null;
    if (was) PetStore.I.emit(PetAction.ttsStop);
    notifyListeners();
  }

  void togglePause() {
    if (!_active) return;
    _paused = !_paused;
    _syncNotify();
    notifyListeners();
  }

  /// 上一段：段游标退一格（段内句清零），循环读新段。
  void prevPara() {
    if (!_active) return;
    _sIdx = 0;
    _pIdx = _pCur <= 0 ? 0 : _pCur - 1;
    _pCur = -1;
    _finishUtter();
    notifyListeners();
  }

  /// 下一段：段游标进一格；越过段尾时循环自动进下一章。
  void nextPara() {
    if (!_active) return;
    _pIdx = _pCur + 1;
    _sIdx = 0;
    _pCur = -1;
    _finishUtter();
    notifyListeners();
  }

  /// 上一章 / 下一章（通知栏按钮）。
  Future<void> prevChapter() => _goto(_chapterIndex - 1);
  Future<void> nextChapter() => _goto(_chapterIndex + 1);

  Future<void> _goto(int i) async {
    if (!_active) return;
    final ok = await _loadChapter(i);
    if (!ok) {
      _syncNotify('没有更多章节');
      notifyListeners();
      return;
    }
    _finishUtter(); // 当前句立即让位，循环从新章开头读
    notifyListeners();
  }

  void setSleepTimer(int minutes) {
    _sleepTimer?.cancel();
    _sleepTimer = null;
    _sleepMin = minutes;
    if (minutes <= 0) {
      _sleepAt = null;
      notifyListeners();
      return;
    }
    _sleepAt = DateTime.now().add(Duration(minutes: minutes));
    _sleepTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!_active || _sleepAt == null) {
        t.cancel();
        return;
      }
      final left = _sleepAt!.difference(DateTime.now());
      if (left <= Duration.zero) {
        t.cancel();
        _sleepMin = 0;
        _sleepAt = null;
        unawaited(stop());
        return;
      }
      notifyListeners(); // 听书页的倒计时刷新
    });
    notifyListeners();
  }

  // ---------------- 循环 ----------------

  Future<void> _loop() async {
    if (_loopOn) return;
    _loopOn = true;
    try {
      while (_active) {
        if (_paused) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        if (_pIdx >= _paras.length) {
          if (!await _loadChapter(_chapterIndex + 1)) {
            await stop(); // 全书读完
            break;
          }
          notifyListeners();
          continue;
        }
        final para = _paras[_pIdx];
        // 插图段落没有可读文字，跳过（否则语音引擎会念控制字符）
        if (para.trim().isEmpty || epubImagePathOf(para) != null) {
          _pIdx++;
          _sIdx = 0;
          continue;
        }
        final sents = splitSentences(para);
        if (_sIdx >= sents.length) {
          _pIdx++;
          _sIdx = 0;
          continue;
        }
        final line = sents[_sIdx];
        _pCur = _pIdx;
        notifyListeners(); // 高亮 / 面板 / 跟随滚动
        _syncNotify();
        final c = Completer<void>();
        _utter = c;
        try {
          await _speak(line);
        } catch (_) {
          _finishUtter();
          await stop();
          break;
        }
        // 句子已开播：并行预热下一句在线合成（静默失败）
        unawaited(_preheat());
        // 完成/取消/出错都会 complete；超时兜底防引擎挂死
        final sec = (line.length * 0.4 + 20).toInt();
        await c.future.timeout(Duration(seconds: sec), onTimeout: () {});
        if (!_active) break;
        if (_paused) continue; // 暂停期间读完：恢复时重读本句
        _sIdx++;
      }
    } finally {
      _loopOn = false;
    }
  }

  /// 后台跨章：直接走离线缓存管线（不经任何 UI）。
  Future<bool> _loadChapter(int i) async {
    final d = _detail;
    final src = _source;
    if (d == null || src == null || i < 0 || i >= d.chapters.length) {
      return false;
    }
    try {
      final text = await AppStore.I
          .chapterText(src, d, d.chapters[i], background: true)
          .timeout(const Duration(seconds: 45));
      if (text.isEmpty) return false;
      _chapterIndex = i;
      _paras = text;
      _pIdx = 0;
      _sIdx = 0;
      _pCur = -1;
      return true;
    } catch (_) {
      return false;
    }
  }

  // ---------------- 朗读引擎 ----------------

  void _finishUtter() {
    final c = _utter;
    if (c != null && !c.isCompleted) c.complete();
  }

  /// 音色 / 语速 / 音调变了 → 重新应用（阅读器音色面板在切换后调用）。
  Future<void> applyVoice() => _applyVoice();

  /// 应用音色 / 语速 / 音调（系统 TTS 侧；在线音色走合成器参数）。
  Future<void> _applyVoice() async {
    try {
      // 朗读完成信号（系统 TTS 路径）：没有它每句都要等超时兜底才推进
      _tts.setCompletionHandler(_finishUtter);
      _tts.setCancelHandler(_finishUtter);
      _tts.setErrorHandler((_) => _finishUtter());
      await _tts.setSpeechRate(_prefs.ttsRate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(_prefs.ttsPitch);
    } catch (_) {}
    try {
      await _tts.setLanguage('zh-CN'); // 先语言后音色，音色覆盖语言选择
    } catch (_) {}
    try {
      if (_voices.isEmpty) await _loadVoices();
      final saved = _prefs.ttsVoice;
      // 在线音色：系统 TTS 先垫好回退音色（zh-TW 优先），
      // 合成失败时本会话直接用系统语音续读
      if (kEdgeVoices.containsKey(saved)) {
        final tw = _pickZhTwVoice();
        if (tw != null) await _tts.setVoice(tw);
        return;
      }
      for (final v in _voices) {
        final s = v.values.join(' ').toLowerCase();
        if (s.contains('zh') || s.contains('chinese')) {
          await _tts.setVoice(v);
          break;
        }
      }
    } catch (_) {}
  }

  Future<void> _loadVoices() async {
    try {
      final v = await _tts.getVoices;
      final list = <Map<String, String>>[];
      if (v is List) {
        for (final x in v) {
          if (x is! Map) continue;
          list.add(Map<String, String>.from(
              x.map((k, val) => MapEntry(k.toString(), val.toString()))));
        }
      }
      _voices = list;
    } catch (_) {}
  }

  /// 小智（温柔）：优先 Yaoyao（女）> Huihui（女）> 任意中文音色。
  Map<String, String>? _pickGentleVoice() {
    Map<String, String>? soft, zhAny;
    for (final v in _voices) {
      final n = (v['name'] ?? '').toLowerCase();
      final s = v.values.join(' ').toLowerCase();
      final isZh = s.contains('zh') || s.contains('chinese');
      if (n.contains('yaoyao')) return v;
      if (n.contains('huihui')) soft ??= v;
      if (isZh) zhAny ??= v;
    }
    return soft ?? zhAny;
  }

  Map<String, String>? _findTwVoice() {
    Map<String, String>? tw;
    for (final v in _voices) {
      final n = (v['name'] ?? '').toLowerCase();
      final locale = (v['locale'] ?? '').toLowerCase();
      final s = v.values.join(' ').toLowerCase();
      final isTw = locale.startsWith('zh-tw') ||
          s.contains('cmn-hant') ||
          s.contains('zh-tw') ||
          n.contains('taiwan') ||
          n.contains('hanhan');
      if (!isTw) continue;
      final male = n.contains('male') && !n.contains('female');
      final cur = (tw?['name'] ?? '').toLowerCase();
      final curMale = cur.contains('male') && !cur.contains('female');
      if (tw == null || (curMale && !male)) tw = v;
    }
    return tw;
  }

  Map<String, String>? _pickZhTwVoice() => _findTwVoice() ?? _pickGentleVoice();

  bool get _edgeVoiceOn => kEdgeVoices.containsKey(_prefs.ttsVoice);

  String _edgeVoiceId() =>
      kEdgeVoices[_prefs.ttsVoice]?.$2 ?? kEdgeVoices[kVoiceDefaultKey]!.$2;

  /// 正在进行的合成（句子地址 → 任务）：预取与播放复用同一次合成，不重打。
  final Map<String, Future<String>> _synthInflight = {};
  int _edgeFails = 0; // 连续失败计数：连续 3 次才回退系统语音（避免偶发抖动就变声）

  /// 句子 → 本地缓存 mp3 路径（<缓存>/tts/<sha1(voice|text)>.mp3，命中直接复用）。
  Future<String> _edgeSynthFile(String text) {
    final key = sha1
        .convert(utf8.encode('${_edgeVoiceId()}|$text'))
        .toString()
        .substring(0, 24);
    final hit = _synthInflight[key];
    if (hit != null) return hit;
    final fut = _doSynth(text, key);
    _synthInflight[key] = fut;
    return fut;
  }

  Future<String> _doSynth(String text, String key) async {
    try {
      final dir = await AppStore.I.ttsAudioDir();
      if (dir == null) throw const EdgeTtsException('缓存目录不可用');
      final f = File('${dir.path}/$key.mp3');
      if (await f.exists() && await f.length() > 500) return f.path;
      final bytes = await EdgeTts.synth(text, voice: _edgeVoiceId());
      await f.writeAsBytes(bytes, flush: true);
      _edgeFails = 0;
      return f.path;
    } catch (_) {
      _synthInflight.remove(key); // 失败的任务不留在表里，下次重试
      rethrow;
    }
  }

  /// 预取当前位置之后的句子（跨段、并发 3 一批）：
  /// 逐句合成一次要几秒，不预取的话句与句之间就得干等。
  Future<void> _preheat() async {
    if (_edgeBroken || !_active || _paused || !_edgeVoiceOn) return;
    final targets = <String>[];
    var p = _pCur >= 0 ? _pCur : _pIdx;
    var s = _sIdx + 1;
    while (p < _paras.length && targets.length < 8) {
      final para = _paras[p];
      if (para.trim().isEmpty || epubImagePathOf(para) != null) {
        p++;
        s = 0;
        continue;
      }
      final sents = splitSentences(para);
      for (; s < sents.length && targets.length < 8; s++) {
        final t = sents[s];
        if (t.trim().isEmpty || epubImagePathOf(t) != null) continue;
        targets.add(t);
      }
      p++;
      s = 0;
    }
    for (var i = 0; i < targets.length; i += 3) {
      final batch = [
        for (final t in targets.skip(i).take(3))
          _edgeSynthFile(t).catchError((_) => '')
      ];
      await Future.wait(batch);
      if (!_active || _paused) return;
    }
  }

  /// 朗读一句：在线音色走 Edge 合成+播放；失败（一场一次回退）转系统 TTS。
  Future<void> _speak(String text) async {
    final hook = debugSpeak;
    if (hook != null) {
      await hook(text);
      _finishUtter(); // 假引擎没有平台回调，测试注入直接视为读完
      return;
    }
    if (_edgeVoiceOn && !_edgeBroken) {
      // 单句合成失败重试一次；连续 3 句都失败才回退系统语音 ——
      // 否则网络抖一下，整场就从小臻变成系统腔
      for (var attempt = 0; attempt < 2; attempt++) {
        try {
          final path = await _edgeSynthFile(text);
          if (!_active) return; // 等待合成期间已停止 → 不播
          // 语速在播放层生效（ttsRate 0.5 → 1.0 倍速）
          await _edgePlayer.setPlaybackRate((_prefs.ttsRate * 2).clamp(0.5, 2.0));
          await _edgePlayer.play(DeviceFileSource(path));
          return;
        } catch (_) {}
      }
      _edgeFails++;
      if (_edgeFails >= 3) {
        _edgeBroken = true;
        _syncNotify('在线合成不可用，已切换系统语音');
        // 系统回退音色已在 _applyVoice 垫好，直接续读
      }
    }
    // Android 引擎挂死时 speak future 可能永不返回 → 限时防循环卡死
    await _tts
        .speak(text)
        .timeout(Duration(seconds: (text.length * 0.4 + 20).toInt()));
  }

  // ---------------- 通知 ----------------

  void _onNotifyAction(String action) {
    switch (action) {
      case 'prev':
        unawaited(prevChapter());
      case 'next':
        unawaited(nextChapter());
      case 'toggle':
        togglePause();
      case 'stop':
        unawaited(stop());
    }
  }

  void _syncNotify([String? override]) {
    if (!TtsNotify.supported || !_active) return;
    final b = _book;
    final text = override ?? currentLine;
    unawaited(TtsNotify.show(
      title: '${b?.title ?? ''} · 第 ${_chapterIndex + 1} 章',
      text: text.length > 42 ? '${text.substring(0, 42)}…' : text,
      playing: !_paused,
    ));
  }

  ReaderPrefs get _prefs => AppStore.I.prefs;
}
