// 断句单测：引号、省略号、超长句二次切分、偏移一致性。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/tts/sentence.dart';

void main() {
  test('按句末标点切分，偏移可直接 substring', () {
    const p = '第一句。第二句！第三句？';
    final s = splitSentences(p);
    expect(s.map((e) => e.text).toList(), ['第一句。', '第二句！', '第三句？']);
    for (final x in s) {
      expect(p.substring(x.start, x.end), x.text);
    }
  });

  test('句末标点后的闭合引号归本句', () {
    const p = '他说：“走吧。”然后走了。';
    final s = splitSentences(p);
    expect(s.first.text, '他说：“走吧。”');
    expect(s[1].text, '然后走了。');
  });

  test('省略号/连续标点一起收尾', () {
    const p = '什么……？！真的吗？';
    final s = splitSentences(p);
    expect(s.first.text, '什么……？！');
    expect(s[1].text, '真的吗？');
  });

  test('超长句在软停顿处二次切分，偏移连续', () {
    final p = '${'啊' * 60}，${'呀' * 60}。';
    final s = splitSentences(p, maxLen: 80);
    expect(s.length, greaterThanOrEqualTo(2));
    expect(s.first.text.endsWith('，'), isTrue);
    var prevEnd = 0;
    for (final x in s) {
      expect(x.start, greaterThanOrEqualTo(prevEnd));
      expect(p.substring(x.start, x.end), x.text);
      prevEnd = x.end;
    }
  });

  test('纯空白段不产出句子', () {
    expect(splitSentences('   \n\t '), isEmpty);
  });

  test('换行也断句（本地 TXT）', () {
    const p = '第一行\n第二行';
    final s = splitSentences(p);
    expect(s.map((e) => e.text).toList(), ['第一行', '第二行']);
  });

  test('整章切句保留段索引', () {
    final s = splitChapter(['一。二。', '三。']);
    expect(s.map((e) => e.para).toList(), [0, 0, 1]);
    expect(s.map((e) => e.index).toList(), [0, 1, 0]);
  });

  test('句子偏移换算到渲染文本（带首行缩进）', () {
    const para = '第一句。第二句。';
    final s = splitSentences(para)[1];
    final rendered = '　　$para'; // 缩进两个全角空格 = 2 个 code unit
    final span = spanInRendered(rendered, para, s)!;
    expect(rendered.substring(span.start, span.end), '第二句。');
    expect(span.start, s.start + 2);
  });

  test('渲染文本比原文短时不给高亮（避免越界）', () {
    const para = '第一句。';
    final s = splitSentences(para).first;
    expect(spanInRendered('短', para, s), isNull);
  });

  test('纯符号句可见度低（队列跳过朗读，不跳过高亮）', () {
    expect(visibleRatio('……'), 0);
    expect(visibleRatio('***'), 0);
    expect(visibleRatio('嗯。'), greaterThan(0.3));
  });
}
