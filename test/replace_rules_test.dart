// 替换净化：正则 / 纯文本、启用开关、坏规则不生效、整章被清空时保留原文。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/data/replace_rules.dart';

void main() {
  setUp(() {
    ReplaceRules.I.init(null);
    final r = ReplaceRules.I.rules;
    for (var i = r.length - 1; i >= 0; i--) {
      ReplaceRules.I.removeAt(i);
    }
  });

  test('正则 / 纯文本 / 关闭的规则', () {
    final rules = ReplaceRules.I;
    rules.add(ReplaceRule(
        name: '广告', pattern: r'本章未完.*?继续阅读', replacement: ''));
    rules.add(ReplaceRule(
        name: '字面', pattern: '（求月票）', isRegex: false));
    rules.add(ReplaceRule(
        name: '关掉的', pattern: '正文', replacement: 'X', enabled: false));

    expect(rules.applyTo('正文本章未完，请点击下一页继续阅读（求月票）'),
        '正文');
  });

  test('坏正则不生效，也不会清空正文', () {
    final rules = ReplaceRules.I;
    rules.add(ReplaceRule(name: '坏', pattern: '([', replacement: ''));
    final paras = ['正常一段', '正常两段'];
    expect(rules.apply(paras), paras);
  });

  test('规则把整章替换成空时保留原文', () {
    final rules = ReplaceRules.I;
    rules.add(ReplaceRule(name: '全删', pattern: '.*', replacement: ''));
    expect(rules.apply(['第一段', '第二段']), ['第一段', '第二段']);
  });
}
