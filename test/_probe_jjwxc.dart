// 定向：晋江(www) 章节页真实结构（App 引擎抓取存盘）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/source_fetcher.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/legado_source.dart';

const dumpDir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';

void main() {
  test('probe jjwxc chapter structure', () async {
    final text = File(
      'C:/Users/leey1/Desktop/A/A1/shuangyue/build/dist/重点测试书源.json',
    ).readAsStringSync();
    final all = parseSourceCollection(text).toList();
    final s = all.firstWhere((s) => s.bookSourceUrl == 'https://www.jjwxc.net');
    print('源: ${s.bookSourceName}');
    final ls = LegadoSource(s);
    final svc = OnlineBookService();
    List<Book> books = [];
    for (final k in ['斗破苍穹', '凡人修仙传']) {
      books = await ls.search(k).timeout(const Duration(seconds: 20));
      print('search($k) -> ${books.length}');
      if (books.isNotEmpty) break;
    }
    if (books.isEmpty) return;
    final b = books.first;
    print('书: ${b.title} | ${b.url}');
    final info = await svc.fetchInfo(s, b.url).timeout(const Duration(seconds: 30));
    print('chapters=${info.chapters.length}');
    for (final ch in info.chapters.take(3)) {
      print('  章: ${ch.title} | ${ch.url}');
    }
    if (info.chapters.isNotEmpty) {
      final ch = info.chapters.first;
      final resp = await SourceHttpClient().get(ch.url);
      print('章节页: ${resp.statusCode} | len=${resp.body.length}');
      File('$dumpDir/jjwxc_ch_app.html').writeAsStringSync(resp.body);
      final ct = await svc
          .fetchChapterText(s, ch.url, book: {'bookUrl': b.url, 'name': b.title})
          .timeout(const Duration(seconds: 30));
      print('fetchChapterText len=${ct.length} | 前80: ${ct.replaceAll('\n', '⏎').substring(0, ct.length > 80 ? 80 : ct.length)}');
    }
    print('JJWXC_DONE');
  });
}
