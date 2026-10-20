// 通用规则诊断：抓一个页面，按给定规则求值并打印结果与条目片段。
//   flutter test tool/rule_probe_test.dart -r expanded --dart-define=URL=... --dart-define=RULE=... [--dart-define=POST=key=v] [--dart-define=BASE=...]
// ignore_for_file: avoid_print
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/http_client.dart';

const _url = String.fromEnvironment('URL');
const _rule = String.fromEnvironment('RULE');
const _post = String.fromEnvironment('POST');
const _base = String.fromEnvironment('BASE');
const _sub = String.fromEnvironment('SUBRULE');

void main() {
  test('rule probe', () async {
    final client = SourceHttpClient();
    final resp = _post.isEmpty
        ? await client.get(_url)
        : await client.post(_url, body: _post);
    final html = resp.body;
    final base = _base.isEmpty ? resp.finalUrl : _base;
    print('HTTP ${resp.statusCode}  ${html.length} 字节  base=$base');
    if (html.length < 600) print('页面=${html.replaceAll(RegExp(r'\s+'), ' ')}');
    final eng = AnalyzeRule(html, baseUrl: base);
    final list = eng.getRawList(_rule);
    print('规则[$_rule] → ${list.length} 条');
    for (var i = 0; i < list.length && i < 3; i++) {
      final it = list[i];
      final txt = it is String ? it : eng.getString('@css:@root', ctx: it) ?? '$it';
      print('  [$i] ${txt.length > 220 ? txt.substring(0, 220) : txt}'.replaceAll(RegExp(r'\s+'), ' '));
      if (_sub.isNotEmpty) {
        print('      子规则[$_sub] → ${eng.getStrings(_sub, ctx: it).take(3).toList()}');
      }
    }
    if (html.contains(_rule.split('@').first)) {} else {
      print('提示：规则首段未出现在页面里，可能是站点改版或需要 JS 渲染');
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
