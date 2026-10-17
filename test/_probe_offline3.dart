// 离线验证 #3：一批 tou-empty 源的候选规则，全部对已存盘的原始 HTML 试跑。
// 覆盖：sfacg 模板 tocUrl / 目录页 chapterList、xtangsanshu、gaysay(base64)、
// jhssd 双 ul、po18 ul.lb.fk + !-1、bqgns 候选、tiantang、feilub 回归。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/src_dump';
String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline-3 candidates', () {
    // ===== sfacg：两种变体 + 模板 tocUrl =====
    final b01 = AnalyzeRule(read('01_sfacg_book_book.html'), baseUrl: 'book.sfacg.com');
    print('01紧凑 text.目录列表@href -> ${b01.getStrings('text.目录列表@href')}');
    print('01紧凑 #BasicOperation a.0@href -> ${b01.getStrings('#BasicOperation a.0@href')}');
    final b02 = AnalyzeRule(read('02_sfacg_lite_book.html'), baseUrl: 'https://book.sfacg.com');
    print('02完整 #BasicOperation a.0@href -> ${b02.getStrings('#BasicOperation a.0@href')}');
    print('02完整 text.点击阅读@href -> ${b02.getStrings('text.点击阅读@href')}');

    final t1 = AnalyzeRule(
      '<html><body>无选择器可命中的占位</body></html>',
      vars: {
        'book': {'bookUrl': 'https://book.sfacg.com/Novel/249775'},
      },
    );
    print('模板 {{book.bookUrl}}/MainIndex/ -> ${t1.getStrings('{{book.bookUrl}}/MainIndex/')}');
    print('模板 链式(##/?\$##/MainIndex/) -> ${t1.getStrings(r'{{book.bookUrl}}##/?$##/MainIndex/')}');
    final t2 = AnalyzeRule(
      '<html><body>占位</body></html>',
      vars: {
        'book': {'bookUrl': 'https://book.sfacg.com/Novel/249775/'},
      },
    );
    print('模板 链式(带尾斜杠) -> ${t2.getStrings(r'{{book.bookUrl}}##/?$##/MainIndex/')}');

    // toc 页三种 chapterList 写法
    final toc = AnalyzeRule(read('02_sfacg_lite_toc.html'), baseUrl: 'https://book.sfacg.com');
    print('toc SF写法  ul/li/a -> ${toc.getRawList('class.catalog-list@tag.ul@tag.li@tag.a').length}');
    print('toc 日轻写法 li     -> ${toc.getRawList('class.catalog-list@tag.li').length}');
    print('toc 轻吧写法 .cl a  -> ${toc.getRawList('.catalog-list li a').length}');
    final tocRaw = toc.getRawList('class.catalog-list@tag.ul@tag.li@tag.a');
    if (tocRaw.isNotEmpty) {
      print('  首项 text=${toc.getStrings('text', ctx: tocRaw.first)} href=${toc.getStrings('href', ctx: tocRaw.first)}');
    }
    final tocRaw2 = toc.getRawList('class.catalog-list@tag.li');
    if (tocRaw2.isNotEmpty) {
      print('  li写法 首项 name=${toc.getStrings('tag.a@text', ctx: tocRaw2.first)} url=${toc.getStrings('tag.a@href', ctx: tocRaw2.first)}');
    }

    // ===== xtangsanshu =====
    final xt = AnalyzeRule(read('11_xtangsanshu_book.html'), baseUrl: 'http://www.xtangsanshu.com');
    final xtl = xt.getRawList('.listmain@dd@a');
    print('xtangsanshu .listmain@dd@a -> ${xtl.length}');
    if (xtl.isNotEmpty) {
      print('  首项 text=${xt.getStrings('text', ctx: xtl.first)} href=${xt.getStrings('href', ctx: xtl.first)}');
      print('  末项 text=${xt.getStrings('text', ctx: xtl.last)} href=${xt.getStrings('href', ctx: xtl.last)}');
    }

    // ===== gaysay（base64 data 属性）=====
    final gy = AnalyzeRule(read('08_gaysay_toc.html'), baseUrl: 'https://www.gaysay.com');
    final gyl = gy.getRawList('class.BCsectionTwo-top@tag.li@tag.a');
    print('gaysay toc li@a -> ${gyl.length}');
    if (gyl.isNotEmpty) {
      print('  首项 显示文本=${gy.getStrings('text', ctx: gyl.first)}');
      print('  首项 真名=${gy.getStrings('data-coad6bbb', ctx: gyl.first)}');
      print('  首项 真链=${gy.getStrings(r'data-co84e3c3##@base64##', ctx: gyl.first)}');
      print('  末项 真名=${gy.getStrings('data-coad6bbb', ctx: gyl.last)} 真链=${gy.getStrings(r'data-co84e3c3##@base64##', ctx: gyl.last)}');
    }
    print('gaysay toc text.下一页@href -> ${gy.getStrings('text.下一页@href')}');
    print('gaysay toc .pagination a@href -> ${gy.getStrings('.pagination a@href')}');

    // ===== jhssd =====
    final jh = AnalyzeRule(read('14_jhssd_book.html'), baseUrl: 'https://m.jhssd.com');
    final jh20 = jh.getRawList('class.chapter.1@tag.li@tag.a');
    final jhAll = jh.getRawList('class.chapter@tag.li@tag.a');
    print('jhssd 书页 .chapter.1 li a -> ${jh20.length} | .chapter li a -> ${jhAll.length}');
    if (jh20.isNotEmpty) {
      print('  首项 text=${jh.getStrings('text', ctx: jh20.first)} href=${jh.getStrings('href', ctx: jh20.first)}');
    }
    print('jhssd 书页 option!0@value -> ${jh.getStrings('option!0@value').take(4).toList()}');
    final jh2 = AnalyzeRule(read('14_jhssd_next.html'), baseUrl: 'https://m.jhssd.com');
    final jh2l = jh2.getRawList('class.chapter.1@tag.li@tag.a');
    print('jhssd index_2 .chapter.1 li a -> ${jh2l.length}');
    if (jh2l.isNotEmpty) {
      print('  首项 text=${jh2.getStrings('text', ctx: jh2l.first)} href=${jh2.getStrings('href', ctx: jh2l.first)}');
    }

    // ===== po18 =====
    final po = AnalyzeRule(read('13_po18_toc.html'), baseUrl: 'https://m.po18co.com');
    final pol = po.getRawList(r'class.lb.fk@tag.li!-1');
    print('po18 ul.lb.fk li!-1 -> ${pol.length}');
    print('po18 .showpage a@href -> ${po.getStrings('.showpage a@href').take(3).toList()}');
    if (pol.isNotEmpty) {
      print('  首项 name=${po.getStrings('tag.a@text', ctx: pol.first)} url=${po.getStrings('tag.a@href', ctx: pol.first)}');
    }

    // ===== bqgns 候选 =====
    final bq = AnalyzeRule(read('10_bqgns_book.html'), baseUrl: 'https://www.bqgns.com');
    for (final r in [
      'div.v-sheet div a',
      '.v-list a',
      'div[role=list] a',
      'class.v-list@tag.a',
      'div.v-card a',
      'div.detail_list a',
    ]) {
      print('bqgns "$r" -> ${bq.getRawList(r).length}');
    }

    // ===== tiantang =====
    final tt = AnalyzeRule(read('16_tiantang_book.html'),
        baseUrl: 'https://tiantangxiangzuoshenzhenwangyou.qwyd.net');
    final ttl = tt.getRawList('class.thumbnails@tag.li');
    print('tiantang .thumbnails li -> ${ttl.length}');
    if (ttl.isNotEmpty) {
      print('  首项 name=${tt.getStrings('tag.a@text', ctx: ttl.first)} url=${tt.getStrings('tag.a@href', ctx: ttl.first)}');
    }

    // ===== feilub 回归 =====
    final fb = AnalyzeRule(read('17_feilub_book.html'), baseUrl: 'https://b.faloo.com');
    print('feilub 书页 chapterList -> ${fb.getRawList('class.DivTd@tag.a||class.DivTd3@tag.a').length}');
    final fbn = AnalyzeRule(read('17_feilub_next.html'), baseUrl: 'https://b.faloo.com');
    print('feilub v页 chapterList -> ${fbn.getRawList('class.DivTd@tag.a||class.DivTd3@tag.a').length}');
  });
}
