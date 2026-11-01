// 全局听书会话：逐句切分、跨章推进、章节级通知动作。
// 朗读用 debugSpeak 注入（不碰真实 TTS 引擎），跨章走 AppStore 缓存管线。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/data/tts_session.dart';
import 'package:shuangyue/dom.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/source.dart';
import 'package:shuangyue/store.dart';

/// 只为满足接口的假源：每章返回一段固定文本。
class _FakeSource extends NovelSource {
  @override
  String get id => 'fake';
  @override
  String get name => 'Fake';
  @override
  String get baseUrl => 'https://fake.test';

  @override
  Future<List<Book>> fetchHome() async => const [];
  @override
  Future<List<RankTab>> fetchRankTabs() async => const [];
  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async =>
      const Paged(items: []);
  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);
  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);
  @override
  Future<List<Book>> search(String query) async => const [];
  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async =>
      throw UnimplementedError();
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    return ['第二章的第一句。第二句！', '第二章第二段，只有一句。'];
  }
}

Book _book() => const Book(
      sourceId: 'fake',
      id: 'b1',
      url: 'https://fake.test/book/1',
      title: '测试书',
    );

BookDetail _detail() => BookDetail(
      book: _book(),
      chapters: const [
        Chapter(title: '第1章', url: 'https://fake.test/book/1/c1'),
        Chapter(title: '第2章', url: 'https://fake.test/book/1/c2'),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('splitSentences：句末标点切分、引号跟随、超长句兜底', () {
    expect(splitSentences('你好。'), ['你好。']);
    expect(splitSentences('甲。乙？丙！'), ['甲。', '乙？', '丙！']);
    // 引号跟在句末：并回本句，不孤立
    expect(splitSentences('他说：“来吧。”她走了。'), ['他说：“来吧。”', '她走了。']);
    // 超长句按逗号分摊（>200 字）
    final long = '${'字' * 150}，${'字' * 150}。';
    final parts = splitSentences(long);
    expect(parts.length, 2);
    expect(parts.every((p) => p.length <= 200), isTrue);
    // 空白段
    expect(splitSentences('  \n '), isEmpty);
  });

  test('会话：逐句朗读并自动跨章；通知按钮是章节级', () async {
    final dir = Directory.systemTemp.createTempSync('sy_tts_');
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);

    final read = <String>[];
    final s = TtsSession.I;
    // 稍作延迟：模拟真实朗读节奏，否则全书一瞬读完自动收场，测不到中间态
    s.debugSpeak = (line) async {
      read.add(line);
      await Future<void>.delayed(const Duration(milliseconds: 30));
    };
    addTearDown(() {
      s.debugSpeak = null;
      return s.stop();
    });

    final detail = _detail();
    await s.start(
      book: _book(),
      detail: detail,
      source: _FakeSource(),
      paras: ['第一章第一句。第二句？', '第一章第二段。'],
      chapterIndex: 0,
    );
    expect(s.active, isTrue);
    expect(s.chapterIndex, 0);

    // 等循环读到第二章（跨章走 AppStore 缓存管线），随即暂停定住中间态
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (s.chapterIndex < 1 && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(s.chapterIndex, 1, reason: '第一章读完应自动进第二章');
    expect(s.active, isTrue, reason: '第二章还没读完，会话应仍在');
    s.togglePause();

    expect(read, contains('第一章第一句。'));
    expect(read, contains('第二章的第一句。'));
    expect(s.chapterTitle, '第2章');

    // 通知动作 prev = 上一章（先暂停，防止朗读很快又翻回下一章）
    s.togglePause();
    await s.prevChapter();
    expect(s.chapterIndex, 0);

    // 暂停 / 恢复
    s.togglePause();
    expect(s.paused, isTrue);
    s.togglePause();
    expect(s.paused, isFalse);

    await s.stop();
    expect(s.active, isFalse);
  });
}
