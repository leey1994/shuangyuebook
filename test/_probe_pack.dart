// 临时体检：手机导入包全 56 源，应用引擎全链路（搜索→详情→目录→正文）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/batch_tester.dart';
import 'package:shuangyue/legado/source_fetcher.dart';

Future<void> main() async {
  test('batch health pack 56', () async {
    final text = File(
      'C:/Users/leey1/Desktop/A/A1/shuangyue/build/dist/重点测试书源.json',
    ).readAsStringSync();
    final all = parseSourceCollection(text);
    print('PACK_SRC_COUNT=${all.length}');
    for (final s in all) {
      BatchTestResult r;
      try {
        r = await BatchTester().testOne(s).timeout(const Duration(seconds: 75));
      } catch (e) {
        print('ROW¦${s.bookSourceName}¦${s.bookSourceUrl}¦crash¦${e.toString().split('\n').first}');
        continue;
      }
      final row = [
        'ROW',
        s.bookSourceName.replaceAll('¦', '/'),
        s.bookSourceUrl.replaceAll('¦', '/'),
        'search=${r.search}:${r.resultCount}',
        'name=${jsonEncode(r.sample).replaceAll('¦', '/')}',
        'toc=${r.detail}:${r.chapters}',
        'content=${r.content}:${r.chars}',
        r.failReason ?? '',
        '${r.ms}ms',
      ].join('¦');
      print(row);
      stdout.flush();
    }
  }, timeout: const Timeout(Duration(minutes: 60)));
}
