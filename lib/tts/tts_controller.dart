// 全局听书会话：接管「离开阅读器还在播」的那部分。
//
// 队列本身仍由阅读器创建（它负责断点、章节来源、高亮），本类只做三件事：
//  - 持有会话元信息（书名/章节/段基址）给迷你条与通知栏；
//  - 阅读器销毁时 `detach()`：换掉跨章 loader（本章读完即停），队列继续播；
//  - 迷你条的停止/暂停/上一句/下一句直接转发给队列。
//
// 为什么不让控制器自己 new 队列：队列的 loader 依赖阅读器的分页/滚动两套
// 状态，搬过去等于把阅读器再抄一遍。做一个「可脱手的持有者」更小也更稳。
import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../platform/tts_notify.dart';
import 'tts_engine.dart';
import 'tts_queue.dart';

class TtsController extends ChangeNotifier {
  TtsController._();

  static final TtsController I = TtsController._();

  TtsQueue? _queue;
  Book? _book;
  String _chapterTitle = '';
  int _chapterIndex = 0;
  int _paraBase = 0;
  bool _attached = false;
  bool _inReader = false; // 阅读器是否在前台（路由在场，不一定在播）
  List<TtsEngine> _engines = const [];

  TtsQueue? get queue => _queue;

  Book? get book => _book;

  String get bookTitle => _book?.title ?? '';

  String get chapterTitle => _chapterTitle;

  int get chapterIndex => _chapterIndex;

  /// 当前句所在的 reader 全局段号（高亮 / 通知）。
  int get paraBase => _paraBase;

  /// 阅读器是否还在前台持有本次会话。
  bool get attached => _attached;

  /// 阅读器路由是否在场：迷你条据此避让（即使会话还没被 adopt）。
  bool get inReader => _inReader;

  void setReaderVisible(bool v) {
    if (_inReader == v) return;
    _inReader = v;
    // 进入阅读器时在 initState 里调用，通知会触发祖先 setState（build 期间）；
    // 只在外出时通知，进入时由 adopt / 下一句的通知自然刷新。
    if (!v) notifyListeners();
  }

  bool get active => _queue?.isRunning ?? false;

  bool get paused => _queue?.isPaused ?? false;

  TtsState get state => _queue?.state ?? TtsState.idle;

  String get snippet => _queue?.current?.text ?? '';

  /// 阅读器开播时登记会话。
  void adopt(
    TtsQueue queue, {
    required Book book,
    required int chapterIndex,
    required String chapterTitle,
    required int paraBase,
    List<TtsEngine>? engines,
  }) {
    if (!identical(_queue, queue)) {
      _queue?.removeListener(_relay);
      _queue = queue..addListener(_relay);
    }
    _book = book;
    _chapterIndex = chapterIndex;
    _chapterTitle = chapterTitle;
    _paraBase = paraBase;
    if (engines != null && engines.isNotEmpty) _engines = engines;
    _attached = true;
    notifyListeners();
  }

  /// 跨章/换章后同步元信息。
  void update({
    int? chapterIndex,
    String? chapterTitle,
    int? paraBase,
  }) {
    _chapterIndex = chapterIndex ?? _chapterIndex;
    _chapterTitle = chapterTitle ?? _chapterTitle;
    _paraBase = paraBase ?? _paraBase;
    notifyListeners();
  }

  /// 阅读器销毁：保留播放，但本章读完就停（旧 loader 指向已销毁的 State）。
  void detach() {
    final q = _queue;
    if (q == null) return;
    _attached = false;
    q.loader = () async => null;
    notifyListeners();
  }

  /// 阅读器销毁前调用：把会话从控制器摘掉（队列由调用方 dispose）。
  void release(TtsQueue queue) {
    if (!identical(_queue, queue)) return;
    _queue?.removeListener(_relay);
    _queue = null;
    _attached = false;
    notifyListeners();
  }

  /// 通知栏 / 音频焦点 / 迷你条共用的动作入口。
  void handleAction(String action) {
    switch (action) {
      case 'prev':
        prev();
      case 'next':
        next();
      case 'toggle':
        unawaited(toggle());
      case 'pause':
        unawaited(pause());
      case 'stop':
        unawaited(stop());
    }
  }

  Future<void> pause() async => _queue?.pause();

  Future<void> resume() async => _queue?.resume();

  Future<void> toggle() async => _queue?.toggle();

  void next() => _queue?.nextSentence();

  void prev() => _queue?.prevSentence();

  /// 迷你条关闭：停播并释放引擎（阅读器不在场时由控制器兜底）。
  Future<void> stop() async {
    final q = _queue;
    if (q == null) return;
    if (_attached) {
      await q.stop();
      notifyListeners();
      return;
    }
    q.removeListener(_relay);
    _queue = null;
    await q.stop();
    q.dispose();
    await TtsNotify.hide();
    PetStore.I.emit(PetAction.ttsStop);
    for (final e in _engines) {
      unawaited(e.dispose());
    }
    _engines = const [];
    notifyListeners();
  }

  void _relay() {
    final q = _queue;
    if (q == null) return;
    if (!q.isRunning) {
      if (_attached) {
        notifyListeners();
        return;
      }
      // 脱离阅读器后自然读完：收尾（微任务里 dispose，别在 notify 迭代中销毁）
      final engines = _engines;
      _queue = null;
      _engines = const [];
      q.removeListener(_relay);
      notifyListeners();
      scheduleMicrotask(() {
        q.dispose();
        for (final e in engines) {
          unawaited(e.dispose());
        }
        unawaited(TtsNotify.hide());
        PetStore.I.emit(PetAction.ttsStop);
      });
      return;
    }
    if (!_attached && TtsNotify.supported) {
      final text = snippet.trim();
      unawaited(TtsNotify.show(
        title: '${bookTitle.isEmpty ? '听书' : bookTitle}'
            '${_chapterTitle.isEmpty ? '' : ' · $_chapterTitle'}',
        text: text.length > 42 ? '${text.substring(0, 42)}…' : text,
        playing: !q.isPaused,
      ));
    }
    notifyListeners();
  }
}
