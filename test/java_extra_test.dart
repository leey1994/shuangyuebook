// java.getElements / htmlFormat / strToBytes / bytesToStr：
// 上游这几个成员缺失时是 TypeError，整条规则直接空
// （巴卡漫画靠 getElements 一次取全部章节 li）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

BookSource _src() => BookSource.fromJson({
      'bookSourceName': 'java扩展',
      'bookSourceUrl': 'https://example.test',
      'bookSourceType': 0,
      'customOrder': 0,
      'enabled': true,
      'searchUrl': 'https://example.test/s',
      'ruleSearch': {'bookList': '.x', 'name': 'a@text', 'bookUrl': 'a@href'},
      'ruleToc': {
        'chapterList': '.c a',
        'chapterName': 'text',
        'chapterUrl': 'href',
      },
      'ruleContent': {'content': '.content'},
    });

String _run(String code, {List<String> Function(String)? getElements}) {
  var env = OnlineRepo.jsEnvFor(_src(), JsSession());
  if (getElements != null) env = env.copyWith(getElements: getElements);
  final out = JsBridge.evalCode(code, env: env);
  return out == null ? 'ERR:${JsBridge.lastError}' : out;
}

void main() {
  test('java.getElements 返回可迭代 Elements', () {
    final out = _run(
      'var els = java.getElements("class.list@li");'
      'els.size() + "|" + els.get(1).text() + "|" + els.eachText().join(",");',
      getElements: (rule) => [
        '<li id="a">第一章</li>',
        '<li id="b">第二章</li>',
      ],
    );
    expect(out, '2|第二章|第一章,第二章');
  });

  test('getElements 支持 select/attr 链式', () {
    final out = _run(
      'var els = java.getElements("x");'
      'els.first().attr("id") + "/" + els.select("li").get(0).attr("id") + "/" '
      ' + els.select("li").size();',
      getElements: (rule) => ['<ul><li id="k1">A</li><li>B</li></ul>'],
    );
    expect(out, '/k1/2');
  });

  test('getElements 无元素时为空集合而不是报错', () {
    final out = _run('java.getElements("x").size() + "";',
        getElements: (rule) => const <String>[]);
    expect(out, '0');
  });

  test('java.htmlFormat 在标签边界换行并缩进', () {
    final out = _run(
      'java.htmlFormat("<div><p>a</p><p>b</p></div>").replace(/\\n/g, "|")'
      '.replace(/ {2}/g, "_");',
    );
    expect(out, '<div>|_<p>a</p>|_<p>b</p>|</div>|');
  });

  test('java.strToBytes / bytesToStr 往返（UTF-8 与 GBK）', () {
    final out = _run(
      'var b = java.strToBytes("中文", "UTF-8");'
      'var g = java.strToBytes("中文", "GBK");'
      'b.length + ":" + g.length + ":" + java.bytesToStr(b, "UTF-8") '
      '+ java.bytesToStr(g, "GBK");',
    );
    expect(out, '6:4:中文中文');
  });

  test('strToBytes 输出的字节与 utf8 一致', () {
    final out = _run('java.strToBytes("A中", "UTF-8").join("-");');
    expect(out, utf8.encode('A中').join('-'));
  });

  test('规则上下文里 java.getElements 走 AnalyzeRule（包子漫画式）', () {
    const html = '<html><body><div class="comic-contain">'
        '<amp-img data-src="https://x/1.jpg"></amp-img>'
        '<amp-img data-src="https://x/2.jpg"></amp-img></div></body></html>';
    final env = OnlineRepo.jsEnvFor(_src(), JsSession());
    final r = AnalyzeRule(html, baseUrl: 'https://cn.bzmanga.com/ch/1', js: env);
    final out = r.getString(
        '@js:var n = java.getElements("class.comic-contain@amp-img");'
        ' var c = [];'
        ' Array.from(n).forEach(function (x) { c.push(x.attr("data-src")); });'
        ' c.join(",");');
    expect(out, 'https://x/1.jpg,https://x/2.jpg');
  });

  test('java.setContent 后用 getElements 取本地内容（搬山人式）', () {
    final out = _run(
      'var va = { setContent: function (h, u) { java.setContent(h, u); } };'
      'va.setContent("<html><body><div class=\\"b\\"><a href=\\"/1\\">x</a></div></body></html>", "https://e.test/1");'
      'var docs = java.getElements("@css:html");'
      'docs.size() + ":" + docs.select("a").get(0).attr("href");',
    );
    expect(out, '1:/1');
  });

  test('java 交互类成员存在且不抛错（缺成员 = TypeError = 规则空）', () {
    final out = _run(
      'java.getVerificationCode() + "|" + java.upLoginData() + "|"'
      ' + java.clearCookie("t") + "|" + java.readFile("x") + "|"'
      ' + java.toURL("https://a.b/c?d=1").getPath() + "|"'
      ' + java.digestHex([15, 16]) + "|" + Array.isArray(java.getStringList("a"));',
    );
    expect(out, '|true|true||/c|0f10|true');
  });

  test('java.randomUUID 形状 / java.setCookie', () {
    final out = _run(
      'var u = java.randomUUID();' +
      r'/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(u)' +
      ' + "|" + u.length + "|" + java.setCookie("t", "k=v");',
    );
    expect(out, 'true|36|true');
  });
}
