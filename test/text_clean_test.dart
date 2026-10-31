// 朗读前清洗：只删该删的，别动正文语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/tts/text_clean.dart';

void main() {
  test('零宽字符与软连字符删掉', () {
    expect(cleanForSpeech('你\u200b好\ufeff。'), '你好。');
  });

  test('网址删掉，句子其余部分保留', () {
    expect(cleanForSpeech('看这里 https://a.example/b?c=1 吧。'), '看这里 吧。');
    expect(cleanForSpeech('访问 www.foo.com 获取更多'), '访问 获取更多');
  });

  test('连续重复的逗号压成一个，省略号保留', () {
    expect(cleanForSpeech('等等，，，我还没说完。'), '等等，我还没说完。');
    expect(cleanForSpeech('什么……真的吗？'), '什么……真的吗？');
  });

  test('正常文本不被破坏', () {
    const t = '他说：“走吧。”然后头也不回地离开了。';
    expect(cleanForSpeech(t), t);
  });

  test('只剩网址/符号时判定为不可读', () {
    expect(hasSpeakableText('https://a.b/c'), isFalse);
    expect(hasSpeakableText('***'), isFalse);
    expect(hasSpeakableText('嗯。'), isTrue);
  });
}
