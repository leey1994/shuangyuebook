// AppStore 离线缓存（P0-A 一章一文件）与轻量进度（P0-B）的回归测试。
//
// 覆盖：
//  1. 旧版整本 JSON（texts 大 Map）→ 首次访问自动迁移为一章一文件；
//  2. 章节命中只读一个小文件（不重复抓网、不重写目录）；
//  3. cachedChapterCount / cachedTexts / cachedDetail 口径不变；
//  4. downloadBook 已缓存章节跳过（不再整本读改写）；
//  5. clearCache 递归清掉各书子目录，但保留长期复用的 tts/；
//  6. 章内翻页只写 progress:* 轻量记录，换章才重写书架/历史；
//     模拟重启后由进度记录把最后页码补回来。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/dom.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/source.dart';
import 'package:shuangyue/store.dart';

/// 只为满足接口的假源：fetchChapter 依次返回预置段落并计数。
class _FakeSource extends NovelSource {
  _FakeSource(this.texts);
  final List<List<String>> texts;
  int fetches = 0;

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
      throw UnimplementedError();
  @override
  Future<List<Book>> search(String query) async => const [];
  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async =>
      throw UnimplementedError();
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    final t = fetches < texts.length ? texts[fetches] : <String>['占位'];
    fetches++;
    return t;
  }
}

Book _book() => const Book(
      sourceId: 'fake',
      id: 'b1',
      url: 'https://fake.test/book/1',
      title: '测试书',
    );

BookDetail _detail([Book? b]) => BookDetail(
      book: b ?? _book(),
      chapters: const [
        Chapter(title: '第1章', url: 'https://fake.test/book/1/c1'),
        Chapter(title: '第2章', url: 'https://fake.test/book/1/c2'),
        Chapter(title: '第3章', url: 'https://fake.test/book/1/c3'),
      ],
    );

Directory _tmpCache() => Directory.systemTemp.createTempSync('sy_cache_');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('章节缓存：一章一文件，命中不重抓，目录不随章重写', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _FakeSource([
      ['第一段', '第二段'],
      ['第三章正文'],
    ]);
    final detail = _detail();

    final t1 = await AppStore.I.chapterText(src, detail, detail.chapters[0]);
    expect(t1, ['第一段', '第二段']);
    expect(src.fetches, 1);

    // 再次读取同一章：命中，不再抓网
    final t2 = await AppStore.I.chapterText(src, detail, detail.chapters[0]);
    expect(t2, ['第一段', '第二段']);
    expect(src.fetches, 1);

    // 目录文件存在且没有 texts；章节文件是 {"u":..,"p":..} 小 JSON
    final File meta = dir.listSync().whereType<File>().single;
    final mj = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
    expect(mj['texts'], isNull);
    expect(mj['title'], '测试书');
    expect((mj['chapters'] as List).length, 3);
    final bookDir = dir.listSync().whereType<Directory>().single;
    final chFiles = bookDir.listSync().whereType<File>().toList();
    expect(chFiles.length, 1);
    final cj = jsonDecode(chFiles.single.readAsStringSync()) as Map;
    expect(cj['u'], detail.chapters[0].url);
    expect(cj['p'], ['第一段', '第二段']);

    // 换一章：目录文件内容不变（未重写，mtime 不变也行，这里比内容即可）
    final metaBefore = meta.readAsStringSync();
    await AppStore.I.chapterText(src, detail, detail.chapters[2]);
    expect(src.fetches, 2);
    expect(meta.readAsStringSync(), metaBefore);

    // 计数与内搜口径
    expect(await AppStore.I.cachedChapterCount(detail.book.url), 2);
    final texts = await AppStore.I.cachedTexts(detail.book.url);
    expect(texts[detail.chapters[0].url], ['第一段', '第二段']);
    expect(texts[detail.chapters[2].url], ['第三章正文']);

    // 离线目录兜底
    final cd = await AppStore.I.cachedDetail(detail.book);
    expect(cd, isNotNull);
    expect(cd!.chapters.length, 3);
  });

  test('旧版整本 JSON 自动迁移：texts 拆成一章一文件且不再重抓', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _FakeSource([
      ['新抓的'],
      ['新抓的'], // 第 1 章重抓时返回同样内容
    ]);
    final detail = _detail();

    // 先正常抓第 1 章，拿到目录文件路径
    await AppStore.I.chapterText(src, detail, detail.chapters[0]);
    final meta = dir.listSync().whereType<File>().single;
    final bookDir = dir.listSync().whereType<Directory>().single;

    // 伪造旧布局：目录里塞 texts（第 2 章有旧缓存），删掉章节子目录
    final mj = jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
    mj['texts'] = {
      detail.chapters[1].url: ['旧缓存的第二章'],
    };
    meta.writeAsStringSync(jsonEncode(mj), flush: true);
    bookDir.deleteSync(recursive: true);

    // 重置元数据缓存，模拟冷启动后首次访问
    AppStore.I.debugSetCacheDir(dir);

    // 第 2 章应直接命中旧缓存（不抓网），第 1 章重抓（子目录被删了）
    final t2 = await AppStore.I.chapterText(src, detail, detail.chapters[1]);
    expect(t2, ['旧缓存的第二章']);
    expect(src.fetches, 1); // 只有第 1 章重抓了一次

    // 迁移后：目录不再带 texts，第 2 章成为独立文件
    final mj2 =
        jsonDecode(meta.readAsStringSync()) as Map<String, dynamic>;
    expect(mj2['texts'], isNull);
    // 旧布局里只有第 2 章的正文（第 1 章文件已被删），所以计数为 1
    expect(
      (await AppStore.I.cachedChapterCount(detail.book.url)),
      1,
    );
    // 第 1 章再读会重新抓网并补上文件
    final t1 = await AppStore.I.chapterText(src, detail, detail.chapters[0]);
    expect(t1, ['新抓的']);
    expect(src.fetches, 2);
    expect(await AppStore.I.cachedChapterCount(detail.book.url), 2);
  });

  test('downloadBook：已缓存章节跳过，逐章落盘', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _FakeSource([
      ['一'],
      ['二'],
      ['三'],
    ]);
    final detail = _detail();

    var done = 0;
    final ok = await AppStore.I.downloadBook(src, detail,
        onProgress: (d, t) => done = d);
    expect(ok, isTrue);
    expect(done, 3);
    expect(src.fetches, 3);
    expect(await AppStore.I.cachedChapterCount(detail.book.url), 3);

    // 再下一次：全部命中，不再抓网
    await AppStore.I.downloadBook(src, detail);
    expect(src.fetches, 3);
  });

  test('clearCache：递归清掉各书子目录，保留 tts/', () async {
    final dir = _tmpCache();
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    AppStore.I.debugSetCacheDir(dir);
    final src = _FakeSource([['正文']]);
    final detail = _detail();
    await AppStore.I.chapterText(src, detail, detail.chapters[0]);

    final tts = Directory('${dir.path}/tts')..createSync(recursive: true);
    File('${tts.path}/a.mp3').writeAsStringSync('x');

    await AppStore.I.clearCache();

    expect(tts.existsSync(), isTrue);
    expect(await AppStore.I.cachedChapterCount(detail.book.url), 0);
    expect(await AppStore.I.cacheSize(), greaterThan(0)); // tts 还在
  });

  test('进度：章内翻页只写轻量记录，换章才重写历史；重启后页码补回', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    AppStore.I.inited = false;
    await AppStore.I.init();

    final book = _book();
    // 首次出现（新历史条目）→ 整表落盘
    AppStore.I.updateProgress(book,
        chapterIndex: 0, chapterTitle: '第1章', page: 1, chapterCount: 10);
    final sp = await SharedPreferences.getInstance();
    final history1 = sp.getString('history')!;
    expect((jsonDecode(history1) as List).first['page'], 1);

    // 同章翻页：历史不再重写，只写 progress:*
    AppStore.I.updateProgress(book,
        chapterIndex: 0, chapterTitle: '第1章', page: 7, chapterCount: 10);
    expect(sp.getString('history'), history1);
    final progKey = sp.getKeys().firstWhere((k) => k.startsWith('progress:'));
    expect((jsonDecode(sp.getString(progKey)!) as Map)['p'], 7);

    // 换章：整表落盘
    AppStore.I.updateProgress(book,
        chapterIndex: 1, chapterTitle: '第2章', page: 0, chapterCount: 10);
    final history2 = sp.getString('history')!;
    expect(history2, isNot(history1));
    expect(
        (jsonDecode(history2) as List).first['chapterTitle'], '第2章');

    // 章内翻页后模拟重启：进度记录把页码补回历史
    AppStore.I.updateProgress(book,
        chapterIndex: 1, chapterTitle: '第2章', page: 9, chapterCount: 10);
    expect(sp.getString('history'), history2);
    AppStore.I.inited = false;
    await AppStore.I.init();
    expect(AppStore.I.history.first.page, 9);
    expect(AppStore.I.history.first.chapterTitle, '第2章');
    expect(AppStore.I.history.first.chapterIndex, 1);

    // flushProgress：离开阅读器时把整表补写一次
    AppStore.I.updateProgress(book,
        chapterIndex: 1, chapterTitle: '第2章', page: 12, chapterCount: 10);
    AppStore.I.flushProgress();
    expect(
        (jsonDecode(sp.getString('history')!) as List).first['page'], 12);
  });
}
