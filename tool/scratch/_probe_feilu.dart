// 临时探测 2：抓飞卢源的原始页面 HTML，看正文/目录选择器为何失配。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/batch_tester.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/source_fetcher.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/legado_source.dart';

void main() {
  test('probe feilu detail', () async {
    final text = File('build/dist/重点测试书源.json').readAsStringSync();
    final all = parseSourceCollection(text);
    final feilu = all.where((s) => s.bookSourceName.contains('飞卢')).toList();
    final client = SourceHttpClient();
    for (final s in feilu) {
      print('===== ${s.bookSourceName} @ ${s.bookSourceUrl}');
      final ls = LegadoSource(s);
      List<Book> books = [];
      try {
        books = await ls.search('斗破苍穹');
      } catch (e) {
        print('搜索失败: $e');
        continue;
      }
      if (books.isEmpty) {
        print('无结果');
        continue;
      }
      final b = books.first;
      print('书: ${b.title} -> ${b.url}');
      final svc = OnlineBookService();
      try {
        final info = await svc.fetchInfo(s, b.url);
        print('章节数: ${info.chapters.length}');
        for (final ch in info.chapters.take(3)) {
          print('  章: ${ch.title} -> ${ch.url}');
        }
        // 目录页原样长什么样
        final tocResp = await client.get(b.url, timeout: const Duration(seconds: 20));
        final toc = tocResp.body;
        print('目录页 HTTP ${tocResp.statusCode} 长度 ${toc.length}'
            ' 命中DivTd=${toc.contains("DivTd")} 命中v_nodeList=${toc.contains("v_nodeList")}'
            ' 命中nodeContent=${toc.contains("nodeContent")}');
        if (info.chapters.isNotEmpty) {
          final u = info.chapters.first.url;
          final r = await client.get(u, timeout: const Duration(seconds: 20));
          final body = r.body;
          print('章页 HTTP ${r.statusCode} 长度 ${body.length}'
              ' 命中nodeContent=${body.contains("nodeContent")}'
              ' 命中noveContent=${body.contains("noveContent")}'
              ' 命中GBK乱码=${body.contains("锛") || body.contains("銆")}');
          final i = body.indexOf('nodeContent');
          if (i >= 0) {
            final from = (i - 200).clamp(0, body.length);
            final to = (i + 700).clamp(0, body.length);
            print('--- nodeContent 附近 >>>');
            print(body.substring(from, to));
            print('<<<');
          } else {
            print('--- 前 600 字符 >>>');
            print(body.substring(0, 600.clamp(0, body.length)));
            print('<<<');
          }
        }
      } catch (e) {
        print('info/章页失败: $e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
