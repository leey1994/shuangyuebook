// 离线验证 #4：包更新后的关键规则在存盘页上全链复验。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/analyze_url.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline-4 updated rules', () {
    // ===== ihuaben 新 chapterList =====
    final ih = AnalyzeRule(read('ihuaben_toc.html'), baseUrl: 'https://so.ihuaben.com');
    final rows = ih.getRawList('class.chapter-row');
    print('ihuaben class.chapter-row -> ${rows.length}');
    if (rows.isNotEmpty) {
      print('  首项 name=${ih.getStrings('a@text', ctx: rows.first)} url=${ih.getStrings('a@href', ctx: rows.first)}');
      print('  末项 name=${ih.getStrings('a@text', ctx: rows.last)} url=${ih.getStrings('a@href', ctx: rows.last)}');
      final raw = ih.getStrings('a@href', ctx: rows.first);
      if (raw.isNotEmpty) {
        print('  首项 resolveUrl(so.ihuaben.com# 基址) -> ${resolveUrl(raw.first, 'https://so.ihuaben.com#')}');
      }
    }

    // ===== bqgns 分页三方案 =====
    final bq = AnalyzeRule(read('10_bqgns_book.html'), baseUrl: 'https://www.bqgns.com');
    print('bqgns xpath 分页 -> ${bq.getStrings("//div[@class='seo_page']/a[text()='下一页']/@href")}');
    print('bqgns css 分页(首) -> ${bq.getStrings('class.seo_page@tag.a@href')}');
    print('bqgns css 分页(末) -> ${bq.getStrings('class.seo_page@tag.a.-1@href')}');
    print('bqgns chapterList -> ${bq.getRawList('div.v-sheet div a').length}');

    // ===== gaysay 组合规则 =====
    final gy = AnalyzeRule(read('08_gaysay_toc.html'), baseUrl: 'https://www.gaysay.com');
    final l = gy.getRawList('.BCsectionTwo-top li a');
    print('gaysay chapterList(.BCsectionTwo-top li a) -> ${l.length}');
    if (l.isNotEmpty) {
      final n = gy.getStrings('data-coad6bbb||text', ctx: l.first);
      final u = gy.getStrings(r'data-co84e3c3##@base64##', ctx: l.first);
      print('  首项 name=${n} url=${u}');
      print('  首项 resolveUrl -> ${resolveUrl(u.isEmpty ? '' : u.first, 'https://www.gaysay.com')}');
    }

    // ===== sfacg 模板 tocUrl（模拟 fetchInfo 求值路径）=====
    final eng = AnalyzeRule(
      '<html><body>占位</body></html>',
      vars: {
        'book': {'bookUrl': 'https://book.sfacg.com/Novel/249775'},
      },
    );
    print('sfacg 模板 tocUrl -> ${eng.getString('{{book.bookUrl}}/MainIndex/')}');
    final eng2 = AnalyzeRule(
      '<html><body>占位</body></html>',
      vars: {
        'book': {'bookUrl': 'https://book.sfacg.com/Novel/249775'},
      },
    );
    print('轻小说吧 双备选 tocUrl -> ${eng2.getString('#BasicOperation a.0@href||{{book.bookUrl}}/MainIndex/')}');
  });
}
