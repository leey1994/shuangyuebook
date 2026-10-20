// 定向 mini 探针：诊断 sfacg 三兄弟 toc 为空、bqgns/话本www 修复生效、
// 唐三/顶点/QQ系 content=short 的真实原因（打印原始响应片段）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/source_fetcher.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/legado_source.dart';

const dumpDir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
const keywords = ['斗破苍穹', '凡人修仙传'];

String brief(Object? o, [int n = 120]) {
  final s = (o ?? '').toString().replaceAll('\n', ' ');
  return s.length > n ? '${s.substring(0, n)}…' : s;
}

Future<void> main() async {
  final text = File(
    'C:/Users/leey1/Desktop/A/A1/shuangyue/build/dist/重点测试书源.json',
  ).readAsStringSync();
  final all = parseSourceCollection(text).toList();

  Future<void> probe(String label, bool Function(dynamic) pick,
      {bool fetchContent = false, bool dumpToc = false}) async {
    final s = all.firstWhere(pick);
    print('===== MINI¦$label | ${s.bookSourceName} | ${s.bookSourceUrl}');
    final ls = LegadoSource(s);
    final svc = OnlineBookService();
    var books = <Book>[];
    for (final k in keywords) {
      try {
        books = await ls.search(k).timeout(const Duration(seconds: 20));
        if (books.isNotEmpty) {
          print('  search("$k") -> ${books.length} 本');
          for (final b in books.take(3)) {
            print('    - ${b.title} | ${b.url}');
          }
          break;
        } else {
          print('  search("$k") -> 0 本');
        }
      } catch (e) {
        print('  search("$k") 异常: ${brief(e)}');
      }
    }
    if (books.isEmpty) return;
    final book = books.firstWhere((b) => b.url.startsWith('http'),
        orElse: () => books.first);
    print('  用书: ${book.title} | ${book.url}');
    try {
      final info =
          await svc.fetchInfo(s, book.url).timeout(const Duration(seconds: 25));
      print('  fetchInfo: chapters=${info.chapters.length}');
      if (info.chapters.isNotEmpty) {
        print('    首章: ${info.chapters.first.title} | ${info.chapters.first.url}');
      }
      if (info.chapters.isEmpty && dumpToc) {
        // 手动复算 tocUrl + 直接抓一次，看状态码与页面特征
        final bookPage = await SourceHttpClient().get(book.url);
        final eng = AnalyzeRule(bookPage.body, baseUrl: s.bookSourceUrl);
        eng.vars['book'] = {'bookUrl': book.url};
        final tocRule = s.bookInfoRule?.tocUrl ?? '';
        final tocUrl = eng.getString(tocRule);
        print('    手动 tocUrl 规则: ${brief(tocRule, 80)}');
        print('    求值结果: ${brief(tocUrl, 120)}');
        if (tocUrl != null && tocUrl.isNotEmpty) {
          try {
            final resp = await SourceHttpClient().get(tocUrl);
            print('    toc 抓取: ${resp.statusCode} | len=${resp.body.length} | '
                '含 catalog-list=${resp.body.contains('catalog-list')} | '
                '含 BasicOperation=${resp.body.contains('BasicOperation')}');
            File('$dumpDir/mini_toc_${label.replaceAll('/', '_')}.html')
                .writeAsStringSync(resp.body);
          } catch (e) {
            print('    toc 抓取异常: ${brief(e)}');
          }
        }
      }
      if (fetchContent && info.chapters.isNotEmpty) {
        final ch = info.chapters.first;
        try {
          final ct = await svc
              .fetchChapterText(s, ch.url, book: {
                'name': book.title,
                'author': book.author,
                'bookUrl': book.url,
                'durChapterTitle': ch.title,
                'chapterTitle': ch.title,
              })
              .timeout(const Duration(seconds: 25));
          final flat = ct.replaceAll(RegExp(r'\s+'), '');
          print('  content: len=${flat.length} | 预览: ${brief(ct, 90)}');
          if (flat.length < 80) {
            final raw = await SourceHttpClient().get(ch.url);
            print('    原始响应: ${raw.statusCode} | len=${raw.body.length}');
            print('    contentRule: ${brief(s.contentRule?.content, 100)}');
            print('    raw 前120: ${brief(raw.body, 120)}');
            File('$dumpDir/mini_ch_${label.replaceAll('/', '_')}.html')
                .writeAsStringSync(raw.body);
          }
        } catch (e) {
          print('  content 异常: ${brief(e)}');
        }
      }
    } catch (e) {
      print('  fetchInfo 异常: ${brief(e, 200)}');
    }
    print('');
  }

  // 1) sfacg 三兄弟（顺带轻小说吧做对照）
  await probe('sflite', (s) => s.bookSourceUrl == 'book.sfacg.com', dumpToc: true);
  await probe('sfday', (s) => s.bookSourceUrl.contains('图片') && s.bookSourceUrl.contains('sfacg'),
      dumpToc: true);
  await probe('sfxing', (s) => s.bookSourceUrl == 'http://s.sfacg.com', dumpToc: true);
  await probe('sftie', (s) => s.bookSourceUrl.startsWith('https://book.sfacg.com#'),
      dumpToc: false);

  // 2) bqgns / 话本www
  await probe('bqgns', (s) => s.bookSourceUrl.contains('bqgns.com'));
  await probe('ihuaben-www', (s) => s.bookSourceUrl.contains('www.ihuaben.com'));

  // 3) 正文诊断
  await probe('xtang', (s) => s.bookSourceUrl.contains('xtangsanshu'), fetchContent: true);
  await probe('dingdian', (s) => s.bookSourceUrl.contains('dingdian888'), fetchContent: true);
  await probe('qqpg', (s) => s.bookSourceUrl == 'novel.html5.qq.com', fetchContent: true);

  // 4) po18 网络抖动复查
  await probe('po18', (s) => s.bookSourceUrl.contains('po18co.com'));

  print('MINI_DONE');
}
