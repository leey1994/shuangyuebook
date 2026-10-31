// 全局会话：脱手 / 接管 / 停止的最小语义。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/tts/tts_controller.dart';
import 'package:shuangyue/tts/tts_engine.dart';
import 'package:shuangyue/tts/tts_queue.dart';

class _QuietEngine implements TtsEngine {
  final List<String> spoken = [];
  Completer<void>? _active;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    _active = Completer<void>();
    await _active!.future;
  }

  void finish() {
    final c = _active;
    _active = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  bool get canResumeMidSentence => true;
  @override
  Future<void> prepare({
    required String voiceId,
    required double rate,
    required double pitch,
  }) async {}
  @override
  Future<void> pause() async {}
  @override
  Future<void> resume() async {}
  @override
  Future<void> stop() async => finish();
  @override
  Future<void> setVolume(double v) async {}

  @override
  Future<void> precache(String text) async {}
  @override
  Future<void> dispose() async {}
}

void main() {
  const book = Book(sourceId: 's', id: '1', url: 'book://1', title: '测试书');

  test('弃用：脱手后 loader 变 null（本章读完即停）', () async {
    final c = TtsController.I;
    final e = _QuietEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(const ['一句。']);
    unawaited(q.play());
    await Future<void>.delayed(Duration.zero);
    c.adopt(q,
        book: book,
        chapterIndex: 3,
        chapterTitle: '第三章',
        paraBase: 10,
        engines: [e]);
    expect(c.active, isTrue);
    expect(c.attached, isTrue);
    c.detach();
    expect(c.attached, isFalse);
    expect(await q.loader(), isNull);
    await c.stop();
    expect(c.queue, isNull);
    expect(c.active, isFalse);
  });

  test('接管：阅读器回归后 attached 复位', () async {
    final c = TtsController.I;
    final e = _QuietEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(const ['一句。']);
    unawaited(q.play());
    await Future<void>.delayed(Duration.zero);
    c.adopt(q, book: book, chapterIndex: 0, chapterTitle: '', paraBase: 0);
    c.detach();
    expect(c.attached, isFalse);
    c.adopt(q, book: book, chapterIndex: 0, chapterTitle: '', paraBase: 0);
    expect(c.attached, isTrue);
    await c.stop();
  });
}
