// 证据抓取：对一批 toc-empty 源走「搜索→详情页→tocUrl 目录页」，
// 把 HTML 原样存盘（供离线修规则）+ 打印各规则命中数。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/source_fetcher.dart';
import 'package:shuangyue/sources/legado_source.dart';

const outDir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';

// (序号, 标签, 源名精确包含, URL 包含)
const targets = [
  (1, 'sfacg_book', 'SF轻小说', 'book.sfacg.com'),
  (2, 'sfacg_lite', '轻小说吧', 'book.sfacg.com'),
  (3, 'sfacg_day', '日轻小说', 'sfacg.com'),
  (4, 'sfacg_line', '行轻小说', 's.sfacg.com'),
  (5, 'ihuaben_so', '画本阅读', 'so.ihuaben.com'),
  (6, 'ihuaben_www', '话本小说', 'www.ihuaben.com'),
  (7, 'ihuaben_so2', '话本小说', 'so.ihuaben.com/search'),
  (8, 'gaysay', '基友书屋', 'gaysay.com'),
  (9, 'dingdian', '顶点小说', 'dingdian888'),
  (10, 'bqgns', '18笔趣阁', 'bqgns.com'),
  (11, 'xtangsanshu', '唐三中文', 'xtangsanshu.com'),
  (12, 'ruochu', '若初文学', 'ruochu.com'),
  (13, 'po18', 'po18', 'po18co.com'),
  (14, 'jhssd', '精华书阁', 'm.jhssd.com'),
  (15, 'shubl', '书耽', 'm.shubl.com'),
  (16, 'tiantang', '天堂深圳', 'tiantangxiangzuoshenzhenwangyou'),
  (17, 'feilub', '飞卢小说', 'b.faloo.com'),
];

String slug(String s) {
  final b = StringBuffer();
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (RegExp(r'[a-zA-Z0-9_]').hasMatch(c)) b.write(c);
  }
  return b.toString();
}

Future<void> main() async {
  test('dump failing sources', () async {
    Directory(outDir).createSync(recursive: true);
    final text = File(
      'C:/Users/leey1/Desktop/A/A1/shuangyue/build/dist/重点测试书源.json',
    ).readAsStringSync();
    final all = parseSourceCollection(text);
    final client = SourceHttpClient();
    final svc = OnlineBookService(client: client);

    Future<String> get(String url, BookSource s) async {
      final resp = await client.get(url,
          headers: OnlineBookService.headerMap(s),
          timeout: const Duration(seconds: 20),
          retries: 1);
      if (!resp.ok) throw StateError('HTTP ${resp.statusCode}');
      return resp.body;
    }

    for (final (i, label, name, urlPart) in targets) {
      final matches = all
          .where((s) =>
              s.bookSourceName.contains(name) &&
              s.bookSourceUrl.contains(urlPart))
          .toList();
      if (matches.isEmpty) {
        print('DUMP¦$i¦$label¦NO_MATCH');
        continue;
      }
      final s = matches.first;
      final ls = LegadoSource(s);
      String bookUrl = '';
      try {
        final books = await ls.search('斗破苍穹').timeout(const Duration(seconds: 20));
        if (books.isNotEmpty) bookUrl = books.first.url;
      } catch (e) {
        print('DUMP¦$i¦$label¦SEARCH_ERR¦${e.toString().split('\n').first}');
        continue;
      }
      if (bookUrl.isEmpty) {
        print('DUMP¦$i¦$label¦NO_BOOK');
        continue;
      }
      print('DUMP¦$i¦$label¦book=$bookUrl');
      stdout.flush();

      final tocRule = s.tocRule;
      try {
        final detailHtml = await get(bookUrl, s);
        File('$outDir/${i.toString().padLeft(2, '0')}_${label}_book.html')
            .writeAsStringSync(detailHtml);
        final de = AnalyzeRule(detailHtml, baseUrl: s.bookSourceUrl);
        final detailCount = tocRule == null
            ? -1
            : OnlineBookService.parseChapters(de, tocRule, bookUrl).length;
        print('DUMP¦$i¦$label¦detail=$detailCount');

        // tocUrl
        String? tocPageUrl;
        final turl = s.bookInfoRule?.tocUrl;
        if (turl != null && turl.trim().isNotEmpty) {
          final got = de.getStrings(turl).where((x) => x.trim().isNotEmpty);
          final raw = got.isEmpty ? '' : got.first;
          final resolved = resolveUrl(raw, s.bookSourceUrl);
          print('DUMP¦$i¦$label¦tocUrlRule=$turl => "$raw" => $resolved');
          if (resolved.isNotEmpty) {
            try {
              final tocHtml = await get(resolved, s);
              File('$outDir/${i.toString().padLeft(2, '0')}_${label}_toc.html')
                  .writeAsStringSync(tocHtml);
              final te = AnalyzeRule(tocHtml, baseUrl: s.bookSourceUrl);
              final tocCount = tocRule == null
                  ? -1
                  : OnlineBookService.parseChapters(te, tocRule, resolved).length;
              print('DUMP¦$i¦$label¦tocPage=$tocCount');
            } catch (e) {
              print('DUMP¦$i¦$label¦tocFetchErr¦${e.toString().split('\n').first}');
            }
          }
        }
        // nextTocUrl 求值（详情页）
        final nurl = tocRule?.nextTocUrl;
        if (nurl != null && nurl.trim().isNotEmpty) {
          final got = de.getStrings(nurl).where((x) => x.trim().isNotEmpty);
          print('DUMP¦$i¦$label¦nextTocRule=$nurl => ${got.take(2).toList()}');
          final first = got.isEmpty ? '' : got.first;
          final resolved = resolveUrl(first, s.bookSourceUrl);
          if (resolved.isNotEmpty) {
            try {
              final nh = await get(resolved, s);
              File('$outDir/${i.toString().padLeft(2, '0')}_${label}_next.html')
                  .writeAsStringSync(nh);
              final ne = AnalyzeRule(nh, baseUrl: s.bookSourceUrl);
              final nc = tocRule == null
                  ? -1
                  : OnlineBookService.parseChapters(ne, tocRule, resolved).length;
              print('DUMP¦$i¦$label¦nextPage=$nc url=$resolved');
            } catch (e) {
              print('DUMP¦$i¦$label¦nextFetchErr¦${e.toString().split('\n').first}');
            }
          }
        }
        // 整链（应用逻辑）结果显示
        try {
          final info = await svc
              .fetchInfo(s, bookUrl)
              .timeout(const Duration(seconds: 40));
          print('DUMP¦$i¦$label¦fetchInfo_chapters=${info.chapters.length}');
        } catch (e) {
          print('DUMP¦$i¦$label¦fetchInfoErr¦${e.toString().split('\n').first}');
        }
      } catch (e) {
        print('DUMP¦$i¦$label¦BOOK_ERR¦${e.toString().split('\n').first}');
      }
      stdout.flush();
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
