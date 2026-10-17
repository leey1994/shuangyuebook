// JS 引擎冒烟探针（不参与全量 flutter test：非 _test.dart 命名）
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/js_engine.dart';

void main() {
  test('QuickJS 同步求值 / 桥往返 / 作用域共享 / 挂起重跑', () {
    expect(JsBridge.available, true, reason: '引擎不可用（DLL 未加载？）');

    // 1) 基本求值（完成值）
    expect(JsBridge.evalCode('1+2*3'), '7');
    // 2) 全局作用域持久（同一运行时，jsLib 语义）
    expect(JsBridge.evalCode('globalThis.__gx = 41; __gx + 1'), '42');
    expect(JsBridge.evalCode('__gx'), '41');
    // 3) java.* 桥
    expect(JsBridge.evalCode("java.base64Encode('\u4f60\u597d')"), '5L2g5aW9');
    expect(JsBridge.evalCode("java.base64Decode('5L2g5aW9')"), '\u4f60\u597d');
    expect(JsBridge.evalCode("java.md5Encode('abc')"), '900150983cd24fb0d6963f7d28e17f72');
    expect(JsBridge.evalCode("java.encodeURI('a b&c')"), 'a+b%26c');
    // 4) jsLib 作用域共享（同 scopeKey）
    final e = JsEnv(scopeKey: 't1', jsLib: 'function f(a){return a*2;}');
    expect(JsBridge.evalCode('f(21)', env: e), '42');
    // 5) 错误脚本 → null（不抛出）
    expect(JsBridge.evalCode('nope()'), isNull);
    // 6) 挂起→补网→重跑
    final ses = JsSession();
    final env = JsEnv(scopeKey: 't2', session: ses);
    var caught = '';
    try {
      JsBridge.evalCode("java.ajax('https://e/x')", env: env);
    } on JsSuspendException catch (ex) {
      caught = ex.target;
      ses.ajaxCache[ex.target] = 'BODY';
    }
    expect(caught, 'https://e/x');
    expect(JsBridge.evalCode("java.ajax('https://e/x')", env: env), 'BODY');
    // 7) Date 冻结（会话内重跑稳定）
    final e2 = JsEnv(scopeKey: 't3', session: JsSession());
    final t2a = JsBridge.evalCode('Date.now()', env: e2);
    final t2b = JsBridge.evalCode('Date.now()', env: e2);
    expect(t2a, t2b);
    // 8) 每次求值全新作用域：let/const 不跨调用冲突（对齐 legado 的 bindings 作用域）
    expect(JsBridge.evalCode('let data = 1; data + 1'), '2');
    expect(JsBridge.evalCode('let data = 2; data + 1'), '3');
    expect(JsBridge.evalCode('var __fresh = 9; __fresh'), '9');
    expect(JsBridge.evalCode('typeof __fresh'), 'undefined');
    // 9) chapter / title 绑定（目录逐项解析时可用）
    final ec = JsEnv(scopeKey: 't4', chapter: {'title': '第1章 🔒'});
    expect(JsBridge.evalCode('chapter.title', env: ec), '第1章 🔒');
    expect(JsBridge.evalCode('title', env: ec), '第1章 🔒');
    expect(
        JsBridge.evalCode('chapter === null', env: JsEnv(scopeKey: 't5')), 'true');
    // 10) baseUrl 绑定优先于 sourceUrl（AnalyzeRule 页面语义）
    final eb = JsEnv(
        scopeKey: 't6',
        sourceUrl: 'https://src/',
        baseUrl: 'https://page/detail/9');
    expect(JsBridge.evalCode('baseUrl', env: eb), 'https://page/detail/9');
    // 11) JSON 元素以对象传入 result（legado NativeObject 语义）
    expect(
        JsBridge.evalCode('result.novelId + 1',
            env: JsEnv(scopeKey: 't7'), input: {'novelId': 41}),
        '42');
    // 12) lastError 标记（供规则层脚本报错降级判断）
    JsBridge.evalCode('nope()');
    expect(JsBridge.lastError, isNotNull);
    JsBridge.evalCode('1');
    expect(JsBridge.lastError, isNull);
    // 13) URL 模板 JS 段（analyzeJs：@result 线程 / 页列表）
    final e14 = JsEnv(scopeKey: 't9');
    final r14a = buildRequest(
      '<js>var h = "https://s/"; h + 2</js>@result?p={{page}}',
      'https://base/',
      {'key': 'k', 'page': 3},
      js: e14,
    );
    expect(r14a.url, 'https://s/2?p=3');
    final r14b = buildRequest(
      '<js>"<https://a/x,https://a/y>"</js>',
      'https://b/',
      {'key': 'k', 'page': 2},
      js: e14,
    );
    expect(r14b.url, 'https://a/y');
  });
}
