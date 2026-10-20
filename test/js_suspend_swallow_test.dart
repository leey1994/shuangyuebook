// 两处规则引擎语义回归：
//  1) JS 列表规则返回的字符串条目（`<a ...>` 片段）上，字段规则只在片段里取；
//  2) 脚本 `try { java.ajax() } catch (e) {}` 吞掉补网错误时仍要重跑补网
//     （legado 的 ajax 是同步的，脚本不会走到 catch —— 神文小说目录依赖这点）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

void main() {
  test('字符串条目上的 a@text / a@href 只在片段内取', () {
    final e = AnalyzeRule(
      '<html><body><a href="/all">全页链接</a></body></html>',
      baseUrl: 'https://x.test/',
    );
    const item = '<a href="/book/1/2.html">第一章 起始</a>';
    expect(e.getStrings('a@text', ctx: item), ['第一章 起始']);
    expect(e.getStrings('a@href', ctx: item), ['/book/1/2.html']);
    // 纯文本条目：不会退回整页（否则每条都拿到全页链接，被去重压成一章）
    expect(e.getStrings('a@text', ctx: '第一章 起始'), isEmpty);
  });

  test('try/catch 吞掉 java.ajax 也会补网并重跑', () async {
    final session = JsSession();
    final env = OnlineRepo.jsEnvFor(_src(), session);
    var resolved = 0;
    const code = "var r = '';"
        "try { r = '' + java.ajax('https://x.test/toc'); } catch (e) {}"
        'r';
    final out = await runWithJsSession<String>(
      session,
      () => JsBridge.evalCode(code, env: env) ?? 'ERR:${JsBridge.lastError}',
      (e) async {
        resolved++;
        session.ajaxCache[JsBridge.ajaxKey(e.method, e.target, e.body)] =
            'TOC-PAGE';
      },
    );
    expect(resolved, 1);
    expect(out, 'TOC-PAGE');
  });
}

BookSource _src() => BookSource.fromJson({
      'bookSourceName': 'suspend 回归',
      'bookSourceUrl': 'https://example.test',
      'bookSourceType': 0,
      'customOrder': 0,
      'enabled': true,
      'searchUrl': 'https://example.test/s',
      'ruleSearch': {'bookList': '.x', 'name': 'a@text', 'bookUrl': 'a@href'},
      'ruleToc': {'chapterList': '.c a'},
      'ruleContent': {'content': '.content'},
    });
