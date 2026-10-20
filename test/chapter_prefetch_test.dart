// 章节切换卡顿的回归测试：预取与前台共用同一个请求、内存 LRU、失败不刷屏。
//
// 「切下一章有时候要等很久」的根因之一是同一章被抓两次：后台预取正在抓
// 第 N+1 章，用户翻页时前台又发一遍，两个请求在同一个站点/IP 上互相拖。
// 这里锁死行为：
//  1. 预取在途时前台取同一章 → 只发一次网络请求，两边拿到同一份正文；
//  2. 同一章并发多次请求 → 只发一次（在途去重）；
//  3. 内存 LRU：来回翻章不再抓网；
//  4. 预取遇错即停，不抛出、不刷屏重试。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/dom.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/source.dart';
import 'package:shuangyue/store.dart';

/// 慢速假源：统计真正发出去的请求次数与顺序。
class _SlowSource extends NovelSource {
  _SlowSource({
    this.delay = const Duration(milliseconds: 120),
    this.fail = false,
  });

  final Duration delay;
  bool fail;
  int fetches = 0;
  final List<String> fetched = <String>[];

  @override
  String get id => 'slow';
  @override
  String get name => 'Slow';
  @override
  String get baseUrl => 'https://slow.test';

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
    fetches++;
    fetched.add(chapter.url);
    await Future<void>.delayed(delay);
    if (fail) throw Exception('网络挂了');
    return <String>['${chapter.title}正文'];
  }
}

Book _book() => const Book(
      sourceId: 'slow',
      id: 'b1',
      url: 'https://slow.test/book/1',
      title: '测试书',
    );

BookDetail _detail() => BookDetail(
      book: _book(),
      chapters: const [
        Chapter(title: '第1章', url: 'https://slow.test/book/1/c1'),
        Chapter(title: '第2章', url: 'https://slow.test/book/1/c2'),
        Chapter(title: '第3章', url: 'https://slow.test/book/1/c3'),
      ],
    );

Directory _tmpCache() => Directory.systemTemp.createTempSync('sy_ch_');

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('预取在途时前台取同一章：只发一次请求', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _SlowSource();
    final detail = _detail();

    // 后台预取从第 2 章开始（模拟刚翻到第 1 章后的自动缓存）
    final prefetching = AppStore.I.prefetchNext(src, detail, 1, 3);
    await Future<void>.delayed(const Duration(milliseconds: 30));
    expect(src.fetches, 1, reason: '预取应该已经在抓第 2 章');

    // 用户此刻翻到第 2 章：必须搭上那个在途请求，而不是再发一遍
    final text = await AppStore.I.chapterText(src, detail, detail.chapters[1]);
    expect(text, ['第2章正文']);
    expect(src.fetches, 1, reason: '同一章并发请求只能发一次');
    expect(src.fetched.first, detail.chapters[1].url);

    AppStore.I.cancelPrefetch(); // 别让后台预取跑完剩下的章
    await prefetching.timeout(const Duration(seconds: 5), onTimeout: () {});
  });

  test('同一章并发五次：只抓一次', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _SlowSource();
    final detail = _detail();

    final all = await Future.wait([
      for (var i = 0; i < 5; i++)
        AppStore.I.chapterText(src, detail, detail.chapters[0]),
    ]);
    expect(src.fetches, 1);
    for (final t in all) {
      expect(t, ['第1章正文']);
    }
  });

  test('内存 LRU：来回翻章不再抓网', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _SlowSource(delay: Duration.zero);
    final detail = _detail();

    await AppStore.I.chapterText(src, detail, detail.chapters[0]);
    await AppStore.I.chapterText(src, detail, detail.chapters[2]);
    expect(src.fetches, 2);

    // 翻回第 1 章：内存命中，不读盘不发网
    final t = await AppStore.I.chapterText(src, detail, detail.chapters[0]);
    expect(t, ['第1章正文']);
    expect(src.fetches, 2, reason: '内存命中不该再发请求');
  });

  test('预取遇错即停：不抛出、不重试', () async {
    final dir = _tmpCache();
    addTearDown(() => dir.deleteSync(recursive: true));
    AppStore.I.debugSetCacheDir(dir);
    final src = _SlowSource(delay: Duration.zero, fail: true);
    final detail = _detail();

    await AppStore.I.prefetchNext(src, detail, 1, 3);
    expect(src.fetches, 1, reason: '第一次失败就停，不刷屏重试');
  });
}
