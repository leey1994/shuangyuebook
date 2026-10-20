// 大字符串 JS 结果分片取回（桥的 JS_Eval 单次上限 8192 单元）回归测试。
//
// 背景：quickjs_c_bridge 的 JS_Eval 只能把 8192 个 UTF-16 单元以内的字符串
// 带回 Dart，超过即整体返回 null 且不带错误。书源里 `JSON.stringify(整页 JSON)`
// 这类规则（魔丸小说 bookList = `<js>…JSON.stringify(result)</js>\n$.data.items`）
// 因此静默变空。修复：脚本末尾把超长值挂到 `__lgBIG`，Dart 侧按 4000 分片取回。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/js_engine.dart';

JsEnv _env(String key) =>
    JsEnv(scopeKey: key, sourceUrl: key, session: JsSession());

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('超过 8192 单元的长字符串能完整取回', () {
    final env = _env('big-basic');
    for (final n in [8000, 8192, 9000, 40000, 65536]) {
      final out = JsBridge.evalCode("'x'.repeat($n)", env: env);
      expect(out, isNotNull, reason: 'n=$n 应能取回');
      expect(out!.length, n, reason: 'n=$n 长度应完整');
    }
  });

  test('分片边界不劈开代理对（emoji / 生僻字）', () {
    final env = _env('big-surrogate');
    final out = JsBridge.evalCode("'𝄞中'.repeat(9000)", env: env);
    expect(out, isNotNull);
    // '𝄞中' = 3 个 UTF-16 单元
    expect(out!.length, 27000);
    expect(out, '𝄞中' * 9000);
    expect(out.contains('\uFFFD'), isFalse, reason: '不应出现替换字符');
  });

  test('大结果经 JSON 往返后内容不变', () {
    final env = _env('big-json');
    final src = '{"a":"${'y' * 30000}"}';
    final out = JsBridge.evalCode('JSON.stringify(JSON.parse(result))',
        env: env, input: src);
    expect(out, isNotNull);
    expect(jsonDecode(out!)['a'], 'y' * 30000);
  });

  test('魔丸小说式链式规则：JS 大结果 + JSONPath 取列表', () {
    final env = _env('big-chain');
    final items = List.generate(
      120,
      (i) => '{"id":"$i","name":"书$i","author":"作者$i"}',
    ).join(',');
    final body = '{"code":0,"data":{"total":120,"items":[$items]}}';
    final rule = '<js>result = JSON.parse(result); JSON.stringify(result)</js>\n'
        r'$.data.items';
    final r = AnalyzeRule(body, baseUrl: 'https://api.example.com', js: env);
    final rows = r.getStrings(rule);
    expect(rows.length, 120);
    expect(rows.first, contains('"name":"书0"'));
  });

  test('普通（非超长）结果行为不变，对象仍是对象', () {
    final env = _env('big-normal');
    expect(JsBridge.evalCode("'abc'", env: env), 'abc');
    final obj = JsBridge.evalCode('({a:1})', env: env);
    expect(obj, isNotNull);
    expect(jsonDecode(obj!)['a'], 1);
  });
}
