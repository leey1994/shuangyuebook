// ignore_for_file: avoid_print
// 诊断探针：检查各书源正文采集是否完整（分页识别/选择器覆盖/抓全字符量）。
// 运行：dart run tool/probe_chapter.dart
import 'package:novel_reader/dom.dart';
import 'package:novel_reader/models.dart';
import 'package:novel_reader/net.dart';
import 'package:novel_reader/sources/registry.dart';

Future<void> main() async {
  for (final src in allSources) {
    print('===== ${src.id} ${src.baseUrl} =====');
    Book? book;
    try {
      final home = await src.fetchHome();
      if (home.isNotEmpty) book = home.first;
    } catch (e) {
      print('home fail: $e');
    }
    if (book == null) {
      try {
        final r = await src.search('凡人');
        if (r.isNotEmpty) book = r.first;
      } catch (e) {
        print('search fail: $e');
      }
    }
    if (book == null) {
      print('NO_BOOK');
      continue;
    }
    print('book: ${book.title} ${book.url}');
    BookDetail? d;
    try {
      d = await src.fetchDetail(book);
    } catch (e) {
      print('detail fail: $e');
    }
    if (d == null || d.chapters.isEmpty) {
      print('NO_CHAPTERS');
      continue;
    }
    final n = d.chapters.length;
    print('chapters: $n');
    final idxs = <int>{2, n ~/ 2, n - 3}.where((i) => i >= 0 && i < n);
    for (final i in idxs) {
      final ch = d.chapters[i];
      print('--- ch[$i] ${ch.title} ${ch.url}');
      try {
        final r = await Net.get(ch.url, referer: book.url);
        print('  http=${r.status} bytes=${r.body.length}');
        if (r.status != 200) continue;
        final doc = parseHtml(r.body);
        // 分页候选链接：文字含「下一页/下页/下一頁」或 rel=next
        final cands = <String>[];
        for (final a in doc.querySelectorAll('a')) {
          final t = cleanText(a.text);
          final rel = a.attributes['rel'] ?? '';
          if (t.contains('下一页') ||
              t.contains('下页') ||
              t.contains('下一頁') ||
              t.contains('下頁') ||
              rel.contains('next')) {
            final href = a.attributes['href'] ?? '';
            cands.add('[$t]->$href');
          }
        }
        print('  pagLinks=${cands.length} ${cands.take(6).join(' ')}');
        final det = nextPageUrl(doc, ch.url);
        print('  nextPageUrl=${det ?? "NULL"}');
        final sel = src.contentOf(doc, ch.url);
        final selChars = sel.join().length;
        final urlDropped = sel.where((p) => p.contains('http://') || p.contains('https://')).length;
        final pChars = doc.querySelectorAll('p').map((e) => e.text).join().length;
        print('  page1: selectorChars=$selChars allPChars=$pChars urlDropped=$urlDropped');
        final t0 = DateTime.now();
        final paras = await src.fetchChapter(d, ch);
        final chars = paras.join().length;
        final tail = paras.isEmpty
            ? ''
            : paras.last.substring(paras.last.length >= 40 ? paras.last.length - 40 : 0);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        print('  fetched: paras=${paras.length} chars=$chars ${ms}ms');
        print('  tail=...$tail');
      } catch (e) {
        print('  ERR $e');
      }
    }
  }
  print('DONE');
}
