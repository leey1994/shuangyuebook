// jsoup 风格选择器：兄弟组合子 `~`/`+` 与 `:contains` 共存。
// package:html 遇 `:contains` 直接抛错 → 整条规则静默 0 命中
// （抖音小说目录 `#list dt:contains(正文) ~ dd a` 就是这样丢的）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';

const _html = '<html><body><div id="list">'
    '<dt>最新章节</dt><dd><a href="/new">新</a></dd>'
    '<dt>正文</dt>'
    '<dd><a href="/1">第一章</a></dd>'
    '<dd><a href="/2">第二章</a></dd>'
    '<dd><a href="/3">第三章</a></dd>'
    '</div></body></html>';

void main() {
  final e = AnalyzeRule(_html, baseUrl: 'https://x.test/');

  test('`~` 后继兄弟', () {
    expect(e.getStrings('#list dt:contains(正文) ~ dd a@href'),
        ['/1', '/2', '/3']);
    expect(e.getStrings('dt:contains(正文) ~ dd a@text'),
        ['第一章', '第二章', '第三章']);
  });

  test('`+` 紧邻兄弟', () {
    expect(e.getStrings('#list dt:contains(正文) + dd a@href'), ['/1']);
  });

  test('无 jsoup 伪类的兄弟选择器仍走原路径', () {
    expect(e.getStrings('#list dt ~ dd a@href'),
        ['/new', '/1', '/2', '/3']);
    // 括号里的 `~` / `+` 不是组合子
    expect(e.getStrings('#list dt:contains(1+1)').length, 0);
  });
}
