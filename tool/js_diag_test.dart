// 书源 searchUrl 渲染失败归因探针（离线，不联网）。
//
// 对每个「searchUrl 含 JS/模板」的书源：
//   1) 先执行 jsLib（捕获编译/运行错误）；
//   2) 再走 buildRequest 渲染搜索地址；
//   3) 打印结果地址与 JsBridge.lastError（真因）。
//
// 运行：flutter test tool/js_diag_test.dart -r expanded
//       （需把 build\windows\x64\quickjs_engine_native\Release 放进 PATH）
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/rule_analyzer.dart';
import 'package:shuangyue/legado/online_repo.dart';

const _src =
    r'C:\Users\leey1\Desktop\A\A1\review\merged126.json';

void main() {
  test('searchUrl render diagnostics', () async {
    final all = (jsonDecode(await File(_src).readAsString()) as List)
        .cast<Map>()
        .map((e) => BookSource.fromJson(e))
        .toList();
    print('JS 引擎可用: ${JsBridge.available}');

    final targets = all
        .where((s) =>
            RuleAnalyzer.hasJs(s.searchUrl ?? '') ||
            (s.searchUrl ?? '').contains('{{'))
        .toList();

    var empty = 0;
    for (final s in targets) {
      final session = JsSession();
      final env = OnlineRepo.jsEnvFor(s, session);
      String? libErr;
      if ((s.jsLib ?? '').trim().isNotEmpty) {
        final r = JsBridge.evalCode(s.jsLib!, env: env);
        libErr = JsBridge.lastError;
        if (r == null && libErr != null) {
          // 记录后继续：Legado 里 jsLib 报错同样会让后续全局函数缺失
        }
      }
      print('');
      print('── ${s.bookSourceName}  (${s.bookSourceUrl})');
      print('   jsLib=${(s.jsLib ?? '').isEmpty ? '无' : '${s.jsLib!.length} 字符'}'
          '${libErr == null ? '' : '  ✗ jsLib 错误: ${libErr.split('\n').first}'}');
      try {
        JsBridge.lastError = null;
        final req = buildRequest(s.searchUrl!, s.bookSourceUrl, {
          'key': '测试关键词',
          'page': 1,
        }, js: env);
        final err = JsBridge.lastError;
        final ok = req.url.trim().isNotEmpty &&
            (req.url.startsWith('http://') ||
                req.url.startsWith('https://'));
        if (!ok) empty++;
        print('   渲染=${ok ? 'OK' : '空/非 http'} '
            '${req.url.length > 90 ? '${req.url.substring(0, 90)}…' : req.url}');
        print('   错误=${err?.split('\n').first ?? '无'}');
        if (req.options.isNotEmpty) {
          print('   选项=${req.options.keys.toList()} method=${req.options['method']}');
        }
      } catch (e) {
        empty++;
        print('   渲染=抛异常 ${e.toString().split('\n').first}');
      }
    }
    print('');
    print('合计 ${targets.length} 条待测，失败 $empty 条');
  }, timeout: const Timeout(Duration(minutes: 10)));
}
