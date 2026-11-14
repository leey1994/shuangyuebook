// P1 规则语义单测（离线，无需 QuickJS）：
//   - `##` 四段链 replaceFirst 提取语义（legado replaceRegex）
//   - `%%` 拉链合并（legado splitRule %% round-robin）
//   - 平衡拆分（`||` / `&&` 忽略括号引号内部）
//   - 宽松 header 解析（单引号 JSON）
//   - `text.X` 选择器（ownText 包含，大小写不敏感）
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/rule_analyzer.dart';

void main() {
  test('## 四段链 replaceFirst：提取首段并展开组', () {
    final parts = RuleAnalyzer.splitReplaces(
        r'a@href##\d+$##https://a.heiyan.com/ajax/chapter/content/$0##');
    expect(parts.chains.length, 1);
    expect(parts.chains.first.replaceFirst, isTrue);
    final out = RuleAnalyzer.applyReplaces(
        'https://www.heiyan.com/book/155711/13443829', parts.chains);
    expect(out, 'https://a.heiyan.com/ajax/chapter/content/13443829');

    // 无匹配 → 空串（legado: matcher.find() false → ""）
    final title = RuleAnalyzer.splitReplaces(r'tag.title@text##《(.*?)》##$1###');
    expect(title.chains.first.replaceFirst, isTrue);
    expect(RuleAnalyzer.applyReplaces('斗破苍穹', title.chains), '');

    // 三段链仍是全量替换
    final strip = RuleAnalyzer.splitReplaces(r'x##\s##');
    expect(strip.chains.first.replaceFirst, isFalse);
    expect(RuleAnalyzer.applyReplaces('a b c', strip.chains), 'abc');
  });

  test('%% 拉链合并：按第 0 列表长度轮转', () {
    const html = '<div class="v"><i>卷1</i><i>卷2</i></div>'
        '<div class="c"><a>章1</a><a>章2</a><a>章3</a></div>';
    final eng = AnalyzeRule(html, baseUrl: 'http://x/');
    final r = eng.getStrings('class.v@tag.i@text%%class.c@tag.a@text');
    expect(r, ['卷1', '章1', '卷2', '章2']);
    // && 仍然顺序串接
    final r2 = eng.getStrings('class.v@tag.i@text&&class.c@tag.a@text');
    expect(r2, ['卷1', '卷2', '章1', '章2', '章3']);
  });

  test('平衡拆分：括号/引号内的 || && 不拆', () {
    expect(RuleAnalyzer.splitAlternatives(r"$.a[?(@.x=='a||b')]||b@text").length, 2);
    final comb = RuleAnalyzer.splitCombine('a&&b%%c');
    expect(comb, isNotNull);
    expect(comb!.$1, '&&'); // 首个出现的分隔符为准（legado 语义）
    expect(comb.$2, ['a', 'b%%c']);
  });

  test('宽松 header：单引号 JSON / 行文本', () {
    final m = RuleAnalyzer.parseHeaderJson(
        "{'User-Agent': 'okhttp/4.9.2','client-brand': 'Redmi'}");
    expect(m['User-Agent'], 'okhttp/4.9.2');
    expect(m['client-brand'], 'Redmi');
    final m2 = RuleAnalyzer.parseHeaderJson(
        'User-Agent: okhttp/4.9.2\nReferer: http://x/');
    expect(m2['User-Agent'], 'okhttp/4.9.2');
    expect(m2['Referer'], 'http://x/');
    expect(RuleAnalyzer.parseHeaderJson('not json at all').isEmpty, isTrue);
  });

  test('text.X：ownText 包含匹配（祖先不抢先）', () {
    const html = '<html><body><div><a href="/catalog">目录</a>'
        '<a href="/next">下一页</a></div></body></html>';
    final eng = AnalyzeRule(html, baseUrl: 'http://x/');
    expect(eng.getString('text.目录@href'), '/catalog');
    expect(eng.getString('text.下一页@href'), '/next');
    expect(eng.getString('text.不存在@href'), isNull);
  });

  test('xpath 元素 ctx：//@href（纯规则，离线可跑）', () {
    const html = '<html><body><div class="float-list"><ul>'
        '<li><span class="time">3-28</span><a href="https://www.heiyan.com/book/155711/13443829" class="name">第1章 阎王帖</a></li>'
        '<li><span class="time">3-28</span><a href="https://www.heiyan.com/book/155711/13443830" class="name">第2章 上门女婿</a></li>'
        '</ul></div></body></html>';
    final eng = AnalyzeRule(html, baseUrl: 'https://www.heiyan.com/');
    final els = eng.getElements('//li[span]/a');
    expect(els.length, 2);
    final first = els.first;
    final href = eng.getString(r'//@href', ctx: first);
    expect(href, 'https://www.heiyan.com/book/155711/13443829');
  });

  test('xpath 元素 ctx：<js> 链取 outerHtml/result', () {
    // 需要 QuickJS 原生库（本仓库其余 js_* 测试同一约定）：
    //   $env:PATH = "<quickjs_engine_native 的构建输出目录>;$env:PATH"
    // 库不在 PATH 时跳过（CI / 未配置的机器不红）。
    // 注意：markTestSkipped 只记「跳过」不中断执行，必须跟上 return。
    if (!_quickJsAvailable()) {
      markTestSkipped('QuickJS 原生库不在 PATH，跳过 <js> 规则用例');
      return;
    }
    const html = '<html><body><div class="float-list"><ul>'
        '<li><span class="time">3-28</span><a href="https://www.heiyan.com/book/155711/13443829" class="name">第1章 阎王帖</a></li>'
        '<li><span class="time">3-28</span><a href="https://www.heiyan.com/book/155711/13443830" class="name">第2章 上门女婿</a></li>'
        '</ul></div></body></html>';
    final eng = AnalyzeRule(html, baseUrl: 'https://www.heiyan.com/');
    final els = eng.getElements('//li[span]/a');
    expect(els.length, 2);
    final first = els.first;
    final nm = eng.getString(
        "<js>(/isvip/.test(String(result))?'L':'') + String(result).match(/>(.*?)</)[1]</js>",
        ctx: first);
    expect(nm, '第1章 阎王帖');
    final cu = eng.getString(
        "//@href<js>'https://a.heiyan.com/ajax/chapter/content/'+result.match(/\\d+\$/)[0]</js>",
        ctx: first);
    expect(cu, 'https://a.heiyan.com/ajax/chapter/content/13443829');
  });
}

/// QuickJS 是否真的可用：试求值一段极小脚本。
/// 只看 `JsBridge.available` 不够 —— 那是「上次用失败后」才翻 false 的惰性标记。
bool _quickJsAvailable() {
  try {
    return JsBridge.evalCode('1+1') == '2';
  } catch (_) {
    return false;
  }
}
