// 离线验证 #2：b.faloo 候选规则（复合选择器归一化 + nextTocUrl + 组合 chapterList）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';

const dir = 'C:/Users/leey1/AppData/Local/Temp/opencode/feilu_html';

String read(String n) => File('$dir/$n').readAsStringSync();

void main() {
  test('offline candidates', () {
    // ---- 复合选择器归一化 ----
    final book2 = read('bfaloo_book2.html'); // 1440069 书页(预览29章)
    final e2 = AnalyzeRule(book2, baseUrl: 'https://b.faloo.com');
    for (final r in [
      'id.mulu@class.C-Fo-Z-ML-TitleBox@tag.a@href',
      'id.mulu class.DivTd3@tag.a',
      '.C-Fo-Z-ML-TitleBox@tag.a@href',
    ]) {
      final v = e2.getStrings(r);
      print('书页 $r -> ${v.length} 项 ${v.take(2).toList()}');
    }
    // 组合 chapterList：书页上应取 DivTd3 的 29
    final cl = 'class.DivTd@tag.a||class.DivTd3@tag.a';
    final list2 = e2.getStrings(cl, ctx: null);
    print('书页 chapterList -> ${list2.length} 项（ctx=null 时是 href?）');
    final raw2 = e2.getRawList(cl);
    print('书页 chapterList raw -> ${raw2.length} 项');

    // ---- v_ 页全量 ----
    final vp = read('bfaloo_v2.html');
    final ev = AnalyzeRule(vp, baseUrl: 'https://b.faloo.com');
    final rawv = ev.getRawList('class.DivTd@tag.a||class.DivTd3@tag.a');
    print('v页 chapterList raw -> ${rawv.length} 项');
    if (rawv.isNotEmpty) {
      print('  首项 text=${ev.getStrings('text', ctx: rawv.first)} href=${ev.getStrings('href', ctx: rawv.first)}');
      print('  末项 text=${ev.getStrings('text', ctx: rawv.last)} href=${ev.getStrings('href', ctx: rawv.last)}');
    }
    // nextTocUrl 在书页求值
    final nexts = e2.getStrings('id.mulu@class.C-Fo-Z-ML-TitleBox@tag.a@href');
    print('书页 nextTocUrl -> $nexts');

    // ---- text. 选择器 ----
    const th = '<div id="m"><a href="http://x/1">章节目录</a>'
        '<a href="http://x/2">点击阅读</a><p>上一页 · 下一页</p>'
        '<a href="http://x/3" class="nx">下一页</a></div>';
    final et = AnalyzeRule(th, baseUrl: 'http://x');
    print('text.章节目录@href -> ${et.getStrings('text.章节目录@href')}');
    print('text.点击阅读@href -> ${et.getStrings('text.点击阅读@href')}');
    print('text.下一页@href -> ${et.getStrings('text.下一页@href')}');
    print('text.没有这个词@href -> ${et.getStrings('text.没有这个词@href')}');
  });
}
