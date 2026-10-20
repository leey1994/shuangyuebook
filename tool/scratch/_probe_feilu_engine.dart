// 临时诊断：飞卢 wap 正文提取 + b.faloo 目录解析，逐步看引擎输出。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_css.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/rule_analyzer.dart';

void main() {
  test('feilu wap content + bfaloo toc', () async {
    final client = SourceHttpClient();

    // ---- 1) wap.faloo.com 章节页 ----
    // 已知搜索第一本：综漫：从斗破苍穹特殊篇开始。目录页规则 tocUrl=.btnLayout@a.1@href
    print('===== wap.faloo.com =====');
    final bookUrl = 'https://wap.faloo.com/5004966.html';
    final t = await client.get(bookUrl, headers: urlHeaders, timeout: const Duration(seconds: 20));
    final bookHtml = t.body;
    print('书页 HTTP ${t.statusCode} len=${bookHtml.length} btnLayout=${bookHtml.contains('btnLayout')}');
    final engine = AnalyzeRule(bookHtml, baseUrl: 'https://wap.faloo.com');
    final tocUrls = engine.getStrings('.btnLayout@a.1@href');
    print('tocUrl 规则结果: $tocUrls');
    final tocPage = tocUrls.isNotEmpty ? tocUrls.first : bookUrl;
    final r2 = await client.get(resolveU(tocPage, 'https://wap.faloo.com'), headers: urlHeaders, timeout: const Duration(seconds: 20));
    final tocHtml2 = r2.body;
    final tocEngine = AnalyzeRule(tocHtml2, baseUrl: 'https://wap.faloo.com');
    print('目录页 HTTP ${r2.statusCode} len=${tocHtml2.length} v_nodeList=${tocHtml2.contains('v_nodeList')}');
    final chUrls = tocEngine.getStrings('.v_nodeList li@a@href');
    print('章节数(引擎): ${chUrls.length}');
    final firstUrl = chUrls.isNotEmpty ? chUrls.first : '';
    print('第一章 URL: $firstUrl');
    if (firstUrl.isNotEmpty) {
      final cu = resolveU(firstUrl, 'https://wap.faloo.com');
      final rr = await client.get(cu, headers: urlHeaders, timeout: const Duration(seconds: 20));
      final chHtml = rr.body;
      print('章页 HTTP ${rr.statusCode} len=${chHtml.length} nodeContent=${chHtml.contains('nodeContent')}');
      // 阶段拆分查看
      final stages = parseCssStages('.nodeContent@p@html');
      print('阶段拆分: ${stages.map((s) => '${s.type}:${s.value}').join(' -> ')}');
      final e2 = AnalyzeRule(chHtml, baseUrl: 'https://wap.faloo.com');
      final viaRule = e2.getStrings('.nodeContent@p@html');
      print('规则 .nodeContent@p@html 结果段数=${viaRule.length} 总长=${viaRule.join('').length}');
      if (viaRule.isNotEmpty) {
        print('第一段前120字: ${viaRule.first.substring(0, (120).clamp(0, viaRule.first.length))}');
      } else {
        final alt1 = e2.getStrings('.nodeContent@html');
        print('备选 .nodeContent@html 段数=${alt1.length} 总长=${alt1.join('').length}');
        final alt2 = e2.getStrings('.nodeContent@p@text');
        print('备选 .nodeContent@p@text 段数=${alt2.length} 总长=${alt2.join('').length}');
        final raw = e2.getRawList('.nodeContent');
        print('getRawList(.nodeContent) 元素数=${raw.length}');
        final pdirect = e2.getRawList('p');
        print('getRawList(p) 元素数=${pdirect.length}');
      }
    }

    // ---- 2) b.faloo.com 目录 ----
    print('');
    print('===== b.faloo.com =====');
    final bUrl = 'https://b.faloo.com/1440069.html';
    final b = await client.get(bUrl, headers: urlHeaders, timeout: const Duration(seconds: 20));
    final bHtml = b.body;
    print('书页 HTTP ${b.statusCode} len=${bHtml.length} DivTd=${bHtml.contains('DivTd')}');
    final be = AnalyzeRule(bHtml, baseUrl: 'https://b.faloo.com');
    final stages3 = parseCssStages('class.DivTd@tag.a');
    print('阶段拆分: ${stages3.map((s) => '${s.type}:${s.value}').join(' -> ')}');
    final items = be.getRawList('class.DivTd@tag.a');
    print('getRawList(class.DivTd@tag.a) = ${items.length}');
    final direct = be.getRawList('.DivTd a');
    print('getRawList(.DivTd a) = ${direct.length}');
    final td = be.getRawList('class.DivTd');
    print('getRawList(class.DivTd) = ${td.length}');
    // 书页里到底几个 DivTd div，第一个里头是什么
    final m = RegExp(r'class="DivTd"').allMatches(bHtml).length;
    print('class="DivTd" 出现次数: $m');
    if (td.isNotEmpty) {
      final first = td.first;
      print('第一个 DivTd 前400字符: ${(first as Object).toString().substring(0, (400).clamp(0, first.toString().length))}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}

// 简易相对 URL 合成
String resolveU(String url, String base) {
  if (url.startsWith('http')) return url;
  final u = Uri.parse(base).resolve(url).toString();
  return u;
}

final Map<String, String> urlHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122 Mobile Safari/537.36',
};
