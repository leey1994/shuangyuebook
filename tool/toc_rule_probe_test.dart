// 单章节目录规则诊断：直接注入页面 HTML 后重放 chapterList 规则。
//   flutter test tool/toc_rule_probe_test.dart -r expanded --dart-define=SRC=... --dart-define=NAME=神文小说 --dart-define=BOOK=...
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/online_repo.dart';

const _src = String.fromEnvironment('SRC');
const _name = String.fromEnvironment('NAME');
const _book = String.fromEnvironment('BOOK');
// 逗号分隔的临时 CSS 规则，用来逐段定位选择器在哪一级断掉。
const _css = String.fromEnvironment('CSS');

Future<String> _get(String url) async =>
    (await SourceHttpClient().get(url)).body;

AnalyzeRule eng0(String html) => AnalyzeRule(html, baseUrl: _book);

void main() {
  test('toc rule probe', () async {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final m = (items as List).cast<Map>().firstWhere(
        (e) => (e['bookSourceName'] ?? '').toString().contains(_name));
    final s = BookSource.fromJson(m.cast<String, dynamic>());
    final rule = s.tocRule?.chapterList ?? '';
    print('rule=${rule.length}字 前40=${rule.substring(0, rule.length > 40 ? 40 : rule.length)}');
    final html = await _get(_book);
    final sample = RegExp(r'href="[^"]{0,60}/book/\d+/\d+[^"]*"')
        .allMatches(html).map((m) => m.group(0)).take(3).toList();
    print('页面 ${html.length} 字节');
    final hits = RegExp(r'<a[^>]+href="/book/(\d+)/(\d+)\.html"').allMatches(html).length;
    print('正则命中(绝对路径)=$hits');
    final hits2 = RegExp(r'href="[^"]*/book/(\d+)/(\d+)\.html"').allMatches(html).length;
    print('正则命中(任意前缀)=$hits2');
    print('章节链接样本=$sample');
    if (_css.isNotEmpty) {
      for (final r in _css.split('||')) {
        print('CSS[$r] → ${eng0(html).getStrings(r).length} 条');
      }
    }
    final session = JsSession();
    final env = OnlineRepo.jsEnvFor(s, session);
    session.ajaxCache[JsBridge.ajaxKey('GET', _book, null)] = html;
    final eng = AnalyzeRule(html, baseUrl: _book, js: env);
    final list = await runWithJsSession<List<Object>>(
      session,
      () => eng.getRawList(rule),
      (e) async {
        print('SUSPEND ${e.kind} ${e.target}');
        session.ajaxCache[JsBridge.ajaxKey('GET', e.target, null)] = html;
      },
    );
    print('列表条数=${list.length}');
    for (final it in list.take(3)) {
      final t = it is String ? it : '$it';
      print('  项: ${t.length > 80 ? t.substring(0, 80) : t}');
    }
    print('jsErr=${JsBridge.lastError?.split('\n').first}');
    if (list.isNotEmpty) {
      final one = list.first;
      print('项类型=${one.runtimeType}');
      print('name规则=${eng.getStrings('a@text', ctx: one)}');
      print('url规则=${eng.getStrings('a@href', ctx: one)}');
      print('章节数(parseChapters)=${OnlineBookService.parseChapters(eng, s.tocRule!, _book).length}');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
