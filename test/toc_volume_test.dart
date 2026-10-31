// 目录字段对齐：isVolume（卷行分组，不可点）、isVip / isPay（付费角标）。
// 用真实 HTML + 真实规则走 OnlineBookService.parseChapters，不发网络请求。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/models.dart' show Chapter;

const _html = '''
<ul class="list">
  <li><span class="vol">第一卷 起风</span></li>
  <li><a href="/c/1.html">第1章 起点</a></li>
  <li><a class="vip" href="/c/2.html">第2章 迷雾</a></li>
  <li><span class="vol">第二卷 落雨</span></li>
  <li><a class="pay" href="/c/3.html">第3章 归途</a></li>
</ul>
''';

void main() {
  test('卷行 / VIP / 付费章各归其位', () {
    final engine = AnalyzeRule(_html, baseUrl: 'https://x.test/book/1');
    final rule = TocRule(
      chapterList: 'class.list@tag.li',
      chapterName: 'tag.a@text||class.vol@text',
      chapterUrl: 'tag.a@href',
      isVolume: 'class.vol@text',
      isVip: 'class.vip@text',
      isPay: 'class.pay@text',
    );
    final chapters =
        OnlineBookService.parseChapters(engine, rule, 'https://x.test/book/1');

    expect(chapters.map((c) => c.title).toList(), [
      '第一卷 起风',
      '第1章 起点',
      '第2章 迷雾',
      '第二卷 落雨',
      '第3章 归途',
    ]);
    expect(chapters[0].isVolume, isTrue);
    expect(chapters[0].url, isEmpty); // 卷行没有链接
    expect(chapters[1].isVolume, isFalse);
    expect(chapters[1].isVip, isFalse);
    expect(chapters[2].isVip, isTrue);
    expect(chapters[2].isPay, isFalse);
    expect(chapters[3].isVolume, isTrue);
    expect(chapters[4].isPay, isTrue);
    expect(chapters[4].url, 'https://x.test/c/3.html');
  });

  test('没有 isVolume 规则的源保持原样（不误伤）', () {
    final engine = AnalyzeRule(_html, baseUrl: 'https://x.test/book/1');
    final rule = TocRule(
      chapterList: 'class.list@tag.li',
      chapterName: 'tag.a@text',
      chapterUrl: 'tag.a@href',
    );
    final chapters =
        OnlineBookService.parseChapters(engine, rule, 'https://x.test/book/1');
    expect(chapters.length, 3);
    expect(chapters.every((c) => !c.isVolume), isTrue);
  });

  test('Chapter 序列化带上标记（缓存/进度不丢结构）', () {
    const c = Chapter(title: '第一卷', url: '', isVolume: true, isVip: true);
    final back = Chapter.fromJson(c.toJson());
    expect(back.isVolume, isTrue);
    expect(back.isVip, isTrue);
    expect(back.isPay, isFalse);
    // 旧缓存没有这些键 → 默认 false，不会崩
    final legacy = Chapter.fromJson({'title': 'x', 'url': 'u'});
    expect(legacy.isVolume, isFalse);
  });
}
