// 规则列表顺序前缀：`-` 反转、`+` 正序（legado AnalyzeRule 语义）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';

const _html = '<html><body><ul class="list">'
    '<li class="c"><a href="/1">第一章</a></li>'
    '<li class="c"><a href="/2">第二章</a></li>'
    '<li class="c"><a href="/3">第三章</a></li>'
    '</ul></body></html>';

void main() {
  test('`-` 前缀反转列表 / `+` 保持', () {
    final e = AnalyzeRule(_html, baseUrl: 'https://x.test/');
    expect(e.getStrings('tag.li@text'), ['第一章', '第二章', '第三章']);
    expect(e.getStrings('-tag.li@text'), ['第三章', '第二章', '第一章']);
    expect(e.getStrings('+tag.li@text'), ['第一章', '第二章', '第三章']);
    final els = e.getElements('-class.c@tag.a');
    expect(els.length, 3);
    expect(e.getElements('-class.c@tag.a').length, 3);
    expect(e.getStrings('-class.c@tag.a@href'), ['/3', '/2', '/1']);
  });

  test('`-@js:` 反转脚本返回的数组（神文小说/禁忌书屋式）', () {
    final e = AnalyzeRule(_html, baseUrl: 'https://x.test/');
    final out = e.getRawList('-@js:["一","二","三"]');
    expect(out.length, 3);
    expect(out.first, '三');
    expect(e.getRawList('@js:["一","二","三"]').first, '一');
  });

  test('单值规则不受前缀影响（`-` 只在列表语义下成立）', () {
    final e = AnalyzeRule(_html, baseUrl: 'https://x.test/');
    expect(e.getString('tag.ul@class'), isNotNull);
  });
}
