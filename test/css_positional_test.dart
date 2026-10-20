// 组合选择器里的位置伪类（`:nth-child(2) a` 这类）验收。
//
// package:html（csslib）不支持 `:nth-child`/`:nth-of-type`/`:eq` 等出现在**组合
// 选择器中间**的形态：`:nth-child` 静默 0 命中、`:nth-of-type` 直接抛
// UnimplementedError。爽阅在 analyze_css.dart 里按顶层空格切段逐段选择。
import 'package:flutter_test/flutter_test.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:shuangyue/legado/analyze_css.dart';

const _html = '<div class="m"><p><span>[<a href="/c/1/" class="g">耽美</a>]</span>'
    '<span><a href="/book/9/" title="T"><em>斗破</em>苍穹</a></span>/'
    '<span><a href="/w/3/">千里</a></span></p></div>';

List<String> _texts(String selector) {
  final doc = html_parser.parse(_html);
  return selectElements(doc, selector).map((e) => e.text.trim()).toList();
}

void main() {
  test('尾部位置伪类', () {
    expect(_texts('span:nth-child(2)'), ['斗破苍穹']);
    expect(_texts('span:nth-of-type(2)'), ['斗破苍穹']);
    expect(_texts('span:nth-last-child(1)'), ['千里']);
    expect(_texts('span:first-child'), ['[耽美]']);
    expect(_texts('span:last-child'), ['千里']);
    expect(_texts('span:eq(1)'), ['斗破苍穹']);
  });

  test('组合选择器中间的位置伪类（切段选择）', () {
    expect(_texts('span:nth-child(2) a'), ['斗破苍穹']);
    expect(_texts('span:nth-of-type(2) a'), ['斗破苍穹']);
    expect(_texts('span:eq(1) a'), ['斗破苍穹']);
    expect(_texts('span:first-child a'), ['耽美']);
    expect(_texts('span:nth-last-child(1) a'), ['千里']);
    expect(_texts('span:last-child a'), ['千里']);
    expect(_texts('p span:eq(1) a'), ['斗破苍穹']);
    expect(_texts('div.m span:nth-child(1) a'), ['耽美']);
  });

  test('组合子与普通选择器不受影响', () {
    expect(_texts('div.m > p').length, 1);
    expect(_texts('span a').length, 3);
    expect(_texts('.g').map((t) => t).toList(), ['耽美']);
  });

  // jsoup 文本伪类：9 个书源在用（书豪小说网、速读谷、抖音小说…）。
  test('contains / containsOwn 文本伪类', () {
    expect(_texts('a:contains(斗破)'), ['斗破苍穹']);
    expect(_texts('a:contains(斗破)').length, 1);
    expect(_texts('span a:contains(千里)'), ['千里']);
    // 大小写不敏感 + 引号包裹
    expect(_texts('a:contains("耽美")'), ['耽美']);
    // 未命中返回空，不抛
    expect(_texts('a:contains(不存在)'), isEmpty);
    // containsOwn 只看自身直接文本：`<em>斗破</em>苍穹` 的 a 自身文本是「苍穹」
    expect(_texts('a:containsOwn(苍穹)'), ['斗破苍穹']);
    expect(_texts('a:containsOwn(斗破)'), isEmpty);
  });
}
