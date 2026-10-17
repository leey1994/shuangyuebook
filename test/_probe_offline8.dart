// 离线验证 #8：sfacg 正文（双 class 同元素）、bqgns 正文 xpath vs css、ihuaben so 的 tocUrl 链。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/online_book_service.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline-8 final fixes', () {
    // ---- sfacg 正文 ----
    final sf = AnalyzeRule(read('sfacg_ch1.html'), baseUrl: 'https://book.sfacg.com');
    for (final r in ['class.article-content@html', 'class.article-content font16@html',
      'id.ChapterBody@html']) {
      final v = sf.getStrings(r);
      final cleaned = OnlineBookService.cleanChapterText(v.join('\n'));
      print('sfacg "$r" -> ${v.length} 项 / 清洗后 ${cleaned.length} 字'
          '${cleaned.isEmpty ? '' : ' | 前50: ${cleaned.replaceAll('\n', '⏎').substring(0, cleaned.length > 50 ? 50 : cleaned.length)}'}');
    }

    // ---- bqgns 正文 ----
    final bq = AnalyzeRule(read('bqgns_ch1.html'), baseUrl: 'https://www.bqgns.com');
    for (final r in [
      "//div[@class='text']/text()",
      'class.text@textNodes',
      'class.text@html',
      'class.text@text',
    ]) {
      final v = bq.getStrings(r);
      final cleaned = OnlineBookService.cleanChapterText(v.join('\n'));
      print('bqgns "$r" -> ${v.length} 项 / 清洗后 ${cleaned.length} 字'
          '${cleaned.isEmpty ? '' : ' | 前40: ${cleaned.replaceAll('\n', '⏎').substring(0, cleaned.length > 40 ? 40 : cleaned.length)}'}');
    }

    // ---- ihuaben so 的 tocUrl 链 ----
    final ih = AnalyzeRule(
      '<html><body><a href="/list/15011322.html">章节目录</a>'
      '<a href="//www.ihuaben.com/list/15011322.html">章节目录</a></body></html>',
      baseUrl: 'https://so.ihuaben.com',
    );
    const rule = r'text.章节目录@href##^//www\.ihuaben\.com/##https://www.ihuaben.com/##^/##https://www.ihuaben.com/';
    final v = ih.getString(rule);
    print('ihuaben so tocUrl 链 -> $v');
    print('  再走 resolveUrl -> ${resolveUrl(v ?? '', 'https://so.ihuaben.com#')}');
  });
}
