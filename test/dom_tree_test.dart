// jsoup 节点树操作：children / parent / previousElementSibling / ownText。
//
// 上游 `result` 是 jsoup Element，源脚本用这些做「上一条标题」定位
// （如有度中文：分卷标题在卷首章节的上一兄弟节点）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

const _html = '''
<div id="list">
  <div class="volume">第一卷 少年</div>
  <div class="ch"><a href="/c/1">第1章 起始</a></div>
  <div class="ch special"><a href="/c/2">第2章 波澜</a></div>
  <div class="volume">第二卷 风起</div>
  <div class="ch"><a href="/c/3">第3章 归途</a></div>
</div>''';

String _run(BookSource s, String code) {
  final env = OnlineRepo.jsEnvFor(s, JsSession());
  final out = JsBridge.evalCode(code, env: env);
  return out == null ? 'ERR:${JsBridge.lastError}' : out;
}

BookSource _src() => BookSource.fromJson({
      'bookSourceName': 'dom树',
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

void main() {
  test('children()/childrenSize()', () {
    final out = _run(
      _src(),
      'var e = String.raw`$_html`;'
      'var d = Packages.org.jsoup.Jsoup.parse(e).selectFirst("#list");'
      'd.childrenSize() + ":" + d.children().size() + ":" '
      ' + d.children().get(0).text();',
    );
    expect(out, '5:5:第一卷 少年');
  });

  test('previousElementSibling 跨过同类节点', () {
    final out = _run(
      _src(),
      'var d = Packages.org.jsoup.Jsoup.parse(String.raw`$_html`);'
      'var chs = d.select(".ch a");'
      'var p = chs.get(2).parent().previousElementSibling();'
      'p.text();',
    );
    expect(out, '第二卷 风起');
  });

  test('nextElementSibling / parent / ownText', () {
    final out = _run(
      _src(),
      'var d = Packages.org.jsoup.Jsoup.parse(String.raw`$_html`);'
      'var first = d.select(".volume").get(0);'
      'var nx = first.nextElementSibling().selectFirst("a").text();'
      'var par = first.parent().attr("id");'
      'var own = first.ownText();'
      'nx + "|" + par + "|" + own;',
    );
    expect(out, '第1章 起始|list|第一卷 少年');
  });

  test('Elements.select 取并集', () {
    final out = _run(
      _src(),
      'var d = Packages.org.jsoup.Jsoup.parse(String.raw`$_html`);'
      'var links = d.select(".ch").select("a");'
      'links.size() + ":" + links.get(1).text();',
    );
    expect(out, '3:第2章 波澜');
  });
}
