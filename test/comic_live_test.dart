// 漫画书源真实链路探针：搜索/发现 → 目录 → fetchChapterImages。
//
// 默认跳过（不打真实网络、不进 CI）；要跑就设 COMIC_LIVE=1：
//   $env:COMIC_LIVE='1'; flutter test test/comic_live_test.dart
// 需要 QuickJS 原生库在 PATH（部分漫画源搜索依赖 JS）。
@Tags(['native'])

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/source_store.dart';

BookSource? _pickComic(List<dynamic> all, String urlHint) {
  for (final s in all) {
    if (s is Map &&
        s['bookSourceType'] == 2 &&
        '${s['bookSourceUrl']}'.contains(urlHint)) {
      return BookSource.fromJson(s);
    }
  }
  return null;
}

void main() {
  final live = Platform.environment['COMIC_LIVE'] == '1';
  final raw = jsonDecode(
          File('sources/raw-sources.json').readAsStringSync()) as List<dynamic>;

  test('真实漫画源：发现页 → 目录 → 图片地址列表', () async {
    if (!live) {
      markTestSkipped('设 COMIC_LIVE=1 才跑真实网络探针');
      return;
    }
    if (!JsBridge.available) {
      markTestSkipped('QuickJS 原生库不在 PATH');
      return;
    }
    final hint = Platform.environment['COMIC_HINT'] ?? '';
    final bs = _pickComic(raw, hint.isNotEmpty ? hint : 'bzmanga') ??
        _pickComic(raw, 'manhuafree');
    if (bs == null) fail('raw-sources.json 里没有可用的漫画源');
    // ignore: avoid_print
    print('漫画源: ${bs.bookSourceName} @ ${bs.bookSourceUrl}');

    final repo = OnlineRepo(store: SourceStore(initial: [bs]));
    final cats = await repo.exploreCategoriesAsync(bs);
    // ignore: avoid_print
    print('分类数: ${cats.length} → ${cats.take(3).map((c) => c.title).toList()}');
    expect(cats, isNotEmpty, reason: '漫画源应有发现页分类');

    final res = await repo.exploreSource(bs, cats.first);
    // ignore: avoid_print
    print('「${cats.first.title}」条目: ${res.books.length}');
    expect(res.books, isNotEmpty, reason: '发现页应有漫画条目');

    final first = res.books.first;
    // ignore: avoid_print
    print('第一本: ${first.name ?? '?'} / ${first.author ?? '?'} @ ${first.bookUrl}');
    final svc = OnlineBookService();
    final info = await svc.fetchInfo(bs, first.bookUrl!);
    // ignore: avoid_print
    print('目录章节数: ${info.chapters.length}');
    expect(info.chapters, isNotEmpty, reason: '目录应有章节');
    // ignore: avoid_print
    print('第 1 章 URL: ${info.chapters.first.url}');
    // 部分漫画书源的目录规则写死了第三方中转域（已失效/403），
    // 探针退回书籍详情页里同域的章节链接，验证引擎本身的解析能力。
    var chapterUrl = info.chapters.first.url;
    if (Uri.parse(chapterUrl).host != Uri.parse(bs.bookSourceUrl).host) {
      final page = await svc.fetchChapterHtml(bs, first.bookUrl!);
      final m = RegExp(r'href="([^"]*(?:page_direct|/comic/chapter/)[^"]*)"')
          .firstMatch(page.replaceAll('&amp;', '&'));
      if (m != null) {
        chapterUrl = m.group(1)!.startsWith('http')
            ? m.group(1)!
            : '${bs.bookSourceUrl}${m.group(1)}';
        // ignore: avoid_print
        print('改用站内章节页: $chapterUrl');
      }
    }
    final pageHtml = await svc.fetchChapterHtml(bs, chapterUrl);
    // ignore: avoid_print
    print('章节页 bytes=${pageHtml.length} '
        'amp-img=${'<amp-img'.allMatches(pageHtml).length} '
        'data-src=${'data-src'.allMatches(pageHtml).length} '
        'bzcdn=${'bzcdn'.allMatches(pageHtml).length}');

    final imgs = await svc.fetchChapterImages(
      bs,
      chapterUrl,
      book: {
        'name': info.name ?? first.name ?? '',
        'author': info.author ?? first.author ?? '',
        'bookUrl': first.bookUrl ?? '',
        'chapterTitle': info.chapters.first.title,
      },
    );
    // ignore: avoid_print
    print('第 1 章图片数: ${imgs.length} → ${imgs.take(2).toList()}');
    expect(imgs, isNotEmpty, reason: '第 1 章应解析出图片地址');
    expect(imgs.first.startsWith('http') || imgs.first.startsWith('data:'),
        isTrue, reason: '图片地址应是 http(s)/data URI');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
