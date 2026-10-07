import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/dom.dart';
import 'package:novel_reader/models.dart';
import 'package:novel_reader/paginate.dart';
import 'package:novel_reader/sources/huangjinwu.dart';
import 'package:novel_reader/sources/shuku52.dart';
import 'package:novel_reader/sources/suduguu.dart';
import 'package:novel_reader/sources/yewa.dart';
import 'package:flutter/painting.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('顶点小说 yewa', () {
    const listHtml = '''
<div id="list">
<article>
<p><a href="https://m.yewa.cc/xiaoshuo/72/72601/" title="吞噬星空：收徒万倍返还"><img src="https://m.yewa.cc/img/72/72601.jpg" alt="吞噬星空：收徒万倍返还"></a></p>
<a href="https://m.yewa.cc/xiaoshuo/72/72601/">
<div><h2>吞噬星空：收徒万倍返还</h2><p>作者：新乙</p><p>简介：意外穿越到吞噬星空世界。</p></div>
</a>
</article>
<article>
<p><a href="https://m.yewa.cc/xiaoshuo/71/71801/" title="无敌天命"><img src="/img/71/71801.jpg"></a></p>
<a href="https://m.yewa.cc/xiaoshuo/71/71801/"><div><h2>无敌天命</h2><p>作者：青鸾峰上</p><p>简介：谁言天命天注定？</p></div></a>
</article>
</div>''';

    test('解析书籍列表', () {
      final books = YewaSource.parseBookList(parseHtml(listHtml), 'https://m.yewa.cc/');
      expect(books.length, 2);
      expect(books[0].title, '吞噬星空：收徒万倍返还');
      expect(books[0].author, '新乙');
      expect(books[0].url, 'https://m.yewa.cc/xiaoshuo/72/72601/');
      expect(books[0].cover, 'https://m.yewa.cc/img/72/72601.jpg');
      expect(books[1].title, '无敌天命');
    });

    const detailHtml = '''
<html><head>
<meta property="og:title" content="大赤仙门"/>
<meta property="og:image" content="https://m.yewa.cc/img/72/72936.jpg"/>
<meta property="og:description" content="取坎填离会龙虎。"/>
<meta property="og:novel:author" content="古顽石"/>
<meta property="og:novel:book_name" content="大赤仙门"/>
<meta property="og:novel:status" content="连载"/>
</head><body>
<ul class="chapter">
<li><a href="/xiaoshuo/72/72936/39458646.html">第1章 择徒</a></li>
<li><a href="/xiaoshuo/72/72936/39458648.html">第2章 火虎牙</a></li>
</ul></body></html>''';

    test('解析详情与目录', () async {
      final src = YewaSource();
      // 直接验证选择器逻辑（不走网络）：用 fetchDoc 之外的解析路径
      final doc = parseHtml(detailHtml);
      expect(metaContent(doc, 'og:novel:book_name'), '大赤仙门');
      expect(metaContent(doc, 'og:novel:author'), '古顽石');
      final chs = doc
          .querySelectorAll('ul.chapter li a, #list li a')
          .map((a) => Chapter(title: cleanText(a.text), url: a.attributes['href']!))
          .toList();
      expect(chs.length, 2);
      expect(chs.first.title, '第1章 择徒');
      expect(src.baseUrl, 'https://m.yewa.cc');
    });

    test('正文选择器', () {
      final doc = parseHtml('<div id="text"><p>第一段。</p><p>第二段。</p></div>');
      expect(YewaSource().contentOf(doc, ''), ['第一段。', '第二段。']);
    });
  });

  group('52书库 shuku52', () {
    test('解析 书名_作者【完结】', () {
      const html = '''
<div class="content">
<article class="excerpt">
<header><h4 class="title"><span>1140.</span> <a href="/book/11407/">斗罗大陆_唐家三少【完结】</a></h4></header>
<p>　　简介：唐门外门弟子唐三。</p>
</article>
<article class="excerpt">
<header><h3><a href="/gl/02_b/bkcBD.html">我还想她[重生]_低绿枝【完结+番外】</a></h3></header>
<p>　　文案：方如练生性傲慢。</p>
</article>
</div>''';
      final books = Shuku52Source.parseExcerptList(parseHtml(html), 'https://www.52shuku.net/');
      expect(books.length, 2);
      expect(books[0].title, '斗罗大陆');
      expect(books[0].author, '唐家三少');
      expect(books[0].url, 'https://www.52shuku.net/book/11407/');
      expect(books[1].title, '我还想她[重生]');
      expect(books[1].author, '低绿枝');
    });

    test('正文选择器', () {
      final doc = parseHtml('<div id="text"><p>正文一</p><p>正文二</p></div>');
      expect(Shuku52Source().contentOf(doc, ''), ['正文一', '正文二']);
    });
  });

  group('速读谷 suduguu', () {
    const html = '''
<div class="item">
<a href="/21/"><img alt="苟在武道世界成圣" src="https://www.suduguu.com/files/cover/x.jpg" /></a>
<div class="itemtxt">
<h3><b class="rank1">01</b><a href="/21/">苟在武道世界成圣</a></h3>
<p><span>连载中</span><span>玄幻小说</span></p>
<p><a href="/21/">作者：在水中的纸老虎</a></p>
<ul><li><i>昨天</i><a href="/21/4650784.html">第929章 请求</a></li></ul>
</div></div>''';

    test('解析 item 卡片', () {
      final books = SuduGuuSource.parseItemList(parseHtml(html), 'https://www.suduguu.com/');
      expect(books.length, 1);
      final b = books.first;
      expect(b.title, '苟在武道世界成圣');
      expect(b.url, 'https://www.suduguu.com/21/');
      expect(b.author, '在水中的纸老虎');
      expect(b.cover, contains('files/cover'));
      expect(b.status, contains('连载中'));
      expect(b.status, contains('玄幻小说'));
      expect(b.latest, '第929章 请求');
    });

    test('正文选择器', () {
      final doc = parseHtml('<div class="con"><p>速读正文</p></div>');
      expect(SuduGuuSource().contentOf(doc, ''), ['速读正文']);
    });
  });

  group('黄金屋 huangjinwu', () {
    const html = '''
<div class="book-grid">
<a href="/novel/421" title="东京泡沫人生" class="book-card">
<div class="book-info">
<div class="book-title">东京泡沫人生</div>
<div class="book-author">作者：大肚杯</div>
<div class="book-desc">穿入泡沫年代的东京。</div>
<div class="book-badges">
<span class="book-badge category">都市</span>
<span class="book-badge status">连载</span>
<span class="book-badge words">432点击</span>
</div></div></a>
</div>''';

    test('解析 book-card', () {
      final books = HuangJinWuSource.parseCards(parseHtml(html), 'https://www.huangjinwu.org/rank');
      expect(books.length, 1);
      final b = books.first;
      expect(b.url, 'https://www.huangjinwu.org/novel/421');
      expect(b.title, '东京泡沫人生');
      expect(b.author, '大肚杯');
      expect(b.intro, contains('东京'));
      expect(b.status, contains('连载'));
      expect(b.status, contains('都市'));
    });

    test('正文选择器跳过更新时间', () {
      final doc = parseHtml(
          '<div class="reader-content"><h1>标题</h1><p class="reader-updated">更新于 2026</p><p>正文A</p></div>');
      expect(HuangJinWuSource().contentOf(doc, ''), ['正文A']);
    });

    test('章内翻页只跟随子页', () {
      final s = HuangJinWuSource();
      expect(
          s.allowFollow('https://www.huangjinwu.org/novel/421/434084',
              'https://www.huangjinwu.org/novel/421/434084/2.html'),
          true);
      // 指向兄弟章节（下一章）时禁止
      expect(
          s.allowFollow('https://www.huangjinwu.org/novel/421/434084',
              'https://www.huangjinwu.org/novel/421/434086'),
          false);
    });
  });

  group('通用工具', () {
    test('下一页链接识别（含「下一章」不误判）', () {
      const html = '''
<div><a href="/a/1.html">上一页</a><a href="/a/2.html">下一页</a>
<a href="/a/3.html">下一章</a></div>''';
      final doc = parseHtml(html);
      expect(nextPageUrl(doc, 'https://x.com/a/1.html'), 'https://x.com/a/2.html');
      const html2 = '<div><a href="/a/2.html">下一章</a></div>';
      expect(nextPageUrl(parseHtml(html2), 'https://x.com/a/1.html'), null);
    });

    test('书名_作者拆分', () {
      final r = splitTitleAuthor('12、斗罗大陆_唐家三少【完结】');
      expect(r.title, '斗罗大陆');
      expect(r.author, '唐家三少');
      final r2 = splitTitleAuthor('没有下划线的书名');
      expect(r2.title, '没有下划线的书名');
      expect(r2.author, null);
    });

    test('绝对地址拼接', () {
      expect(absUrl('https://a.com/x/y.html', '../z.html'), 'https://a.com/z.html');
      expect(absUrl('https://a.com/x/', '/top/'), 'https://a.com/top/');
      expect(absUrl('https://a.com/x/', 'https://b.com/'), 'https://b.com/');
    });
  });

  group('分页引擎', () {
    test('200 段切成多页且不丢段', () {
      final pages = paginateParas(
        paras: List.generate(200, (i) => '第$i段测试文字，长度中等，用于测量。'.padRight(40)),
        width: 300,
        height: 500,
        style: const TextStyle(fontSize: 16, height: 1.5),
        paraSpacing: 8,
      );
      expect(pages.length, greaterThan(1));
      expect(pages.expand((p) => p).length, 200);
    });

    test('超长单段被切分且拼回原文', () {
      final long = List.filled(20, '很长的一段文字，需要被切成多页。').join();
      final pages = paginateParas(
        paras: [long],
        width: 200,
        height: 300,
        style: const TextStyle(fontSize: 18, height: 1.6),
        paraSpacing: 6,
      );
      expect(pages.length, greaterThan(1));
      expect(pages.expand((p) => p).join(), long);
    });
  });

  group('正文采集加固', () {
    test('速读谷 document.write 脚本解出段落（含转义引号）', () {
      final ps = parasFromDocWrite(
          r'document.write("<p>甲段</p><p>乙段\"引\"</p>");');
      expect(ps, ['甲段', '乙段"引"']);
    });

    test('非脚本文本返回空', () {
      expect(parasFromDocWrite('plain text'), isEmpty);
    });

    test('52书库标签页链接不算书籍', () {
      final doc = parseHtml(
          '<article class="excerpt"><a href="/Tags/ZhuShouWen_BL/">主受文</a></article>');
      expect(
          Shuku52Source.parseExcerptList(doc, 'https://www.52shuku.net/')
              .isEmpty,
          isTrue);
    });
  });
}
