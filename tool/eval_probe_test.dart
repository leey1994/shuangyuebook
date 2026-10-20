import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';

void main() {
  test('eval 可用性探针', () {
    final env = JsEnv(scopeKey: 'probe:eval');
    for (final code in [
      'typeof eval',
      'String(eval("1+1"))',
      '(function(){ return String(eval("2+2")); }).call({a:1})',
      '(function(){ var infoMap={}; return JSON.stringify((function(){ return eval("infoMap") }).call({})) })()',
      'JSON.stringify((function(){ var s="x"; var __r = eval("var out=[1,2]; out"); return __r; }).call({}))',
    ]) {
      try {
        final out = JsBridge.evalCode(code, env: env);
        print('IN: $code\n  → $out');
      } catch (e) {
        print('IN: $code\n  → THROWN $e');
      }
    }
  });
}
