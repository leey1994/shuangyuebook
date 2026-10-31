// 句子队列状态机单测：用假引擎驱动，不碰网络/音频。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/tts/tts_engine.dart';
import 'package:shuangyue/tts/tts_queue.dart';

class FakeEngine implements TtsEngine {
  FakeEngine({this.canResumeMidSentence = true});

  @override
  final bool canResumeMidSentence;

  final List<String> spoken = [];
  final List<String> precached = [];
  final List<double> volumes = [];
  Completer<void>? _active;
  String? failOnce;
  bool _failed = false;

  @override
  Future<void> prepare({
    required String voiceId,
    required double rate,
    required double pitch,
  }) async {}

  @override
  Future<void> speak(String text) async {
    if (!_failed && text == failOnce) {
      _failed = true;
      spoken.add(text);
      throw StateError('boom');
    }
    spoken.add(text);
    final c = Completer<void>();
    _active = c;
    await c.future;
  }

  /// 模拟「这一句读完」。
  void finish() {
    final c = _active;
    _active = null;
    if (c != null && !c.isCompleted) c.complete();
  }

  @override
  Future<void> pause() async {
    if (!canResumeMidSentence) finish(); // 系统引擎：停掉本句
  }

  @override
  Future<void> resume() async {}

  @override
  Future<void> stop() async => finish();

  @override
  Future<void> setVolume(double v) async => volumes.add(v);

  @override
  Future<void> precache(String text) async => precached.add(text);

  @override
  Future<void> dispose() async {}
}

Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  List<String> paras() => ['第一句。第二句！', '第三句？'];

  test('顺序读完，自然结束', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(paras(), title: '第一章');
    final done = q.play();
    await pump();
    expect(q.state, TtsState.playing);
    expect(e.spoken, ['第一句。']);
    expect(q.currentPara, 0);
    e.finish();
    await pump();
    expect(e.spoken, ['第一句。', '第二句！']);
    e.finish();
    await pump();
    expect(e.spoken.last, '第三句？');
    e.finish();
    await done;
    expect(q.state, TtsState.idle);
    expect(q.finished, isTrue);
  });

  test('系统引擎：暂停不推进，恢复重读本句', () async {
    final e = FakeEngine(canResumeMidSentence: false);
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(paras());
    unawaited(q.play());
    await pump();
    expect(e.spoken, ['第一句。']);
    await q.pause();
    expect(q.state, TtsState.paused);
    await pump();
    expect(e.spoken, ['第一句。']); // 没有跳到第二句
    await q.resume();
    await pump();
    expect(e.spoken, ['第一句。', '第一句。']); // 重读本句
    expect(q.current?.index, 0);
    e.finish();
    await pump();
    expect(e.spoken.last, '第二句！');
    await q.stop();
    expect(q.state, TtsState.idle);
  });

  test('在线引擎：暂停从句子中间续播，不重读', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(paras());
    unawaited(q.play());
    await pump();
    await q.pause();
    await q.resume();
    await pump();
    expect(e.spoken, ['第一句。']);
    e.finish();
    await pump();
    expect(e.spoken, ['第一句。', '第二句！']);
    await q.stop();
  });

  test('章节内上一句/下一句', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(paras());
    unawaited(q.play());
    await pump();
    q.nextSentence();
    await pump();
    expect(e.spoken.last, '第二句！');
    e.finish();
    await pump();
    expect(e.spoken.last, '第三句？');
    q.prevSentence();
    await pump();
    expect(e.spoken.last, '第二句！');
    await q.stop();
  });

  test('跨章：读完自动向 loader 要下一章', () async {
    final e = FakeEngine();
    var calls = 0;
    final q = TtsQueue(engine: e, loader: () async {
      calls++;
      if (calls > 1) return null;
      return const TtsChapter(title: '第二章', paras: ['下一章第一句。']);
    });
    q.load(const ['本章唯一一句。']);
    final done = q.play();
    await pump();
    e.finish();
    await pump();
    expect(calls, 1);
    expect(q.chapterTitle, '第二章');
    expect(e.spoken.last, '下一章第一句。');
    e.finish();
    await done;
    expect(q.finished, isTrue);
    await q.stop();
  });

  test('单句失败：重试一次后继续', () async {
    final e = FakeEngine()..failOnce = '第一句。';
    final errors = <Object>[];
    final q = TtsQueue(
      engine: e,
      loader: () async => null,
      onError: errors.add,
    );
    q.load(paras());
    unawaited(q.play());
    await pump();
    expect(errors.length, 1);
    expect(e.spoken.where((s) => s == '第一句。').length, 2); // 失败一次 + 重试一次
    e.finish();
    await pump();
    expect(e.spoken.last, '第二句！');
    await q.stop();
  });

  test('预取窗口取后 3 句，纯符号句不读', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null, prefetchWindow: 3);
    q.load(['***', '一句。', '二句。', '三句。', '四句。', '五句。']);
    unawaited(q.play());
    await pump();
    expect(q.current?.text, '一句。');
    expect(e.precached, ['二句。', '三句。', '四句。']);
    await q.stop();
  });

  test('朗读前清洗：网址不念，纯链接句直接跳过', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(['看 https://a.b/c 这里。https://only.link']);
    unawaited(q.play());
    await pump();
    expect(e.spoken, ['看 这里。']);
    e.finish();
    await pump();
    expect(q.finished, isTrue);
  });

  test('音量透传到引擎（定时淡出用）', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    await q.setVolume(0.4);
    expect(e.volumes, [0.4]);
  });

  test('断点续听：按段定位', () async {
    final e = FakeEngine();
    final q = TtsQueue(engine: e, loader: () async => null);
    q.load(paras(), para: 1);
    unawaited(q.play());
    await pump();
    expect(q.current?.text, '第三句？');
    expect(q.currentPara, 1);
    await q.stop();
  });
}
