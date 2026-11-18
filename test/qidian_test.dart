import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/qidian.dart';

/// 起点书源的离线解析单测（解析函数与取网分离，这里只喂站点原样的结构）。
///
/// 联网链路见 tool/qidian_probe.dart。
void main() {
  group('搜索 / 首页书卡', () {
    const page = '<div class="y-list__item">'
        '<a data-bid="1027368101" href="//m.qidian.com/chapter/1027368101/0/" '
        'title="万相之王在线阅读">'
        '<img data-src="//bookcover.yuewen.com/qdbimg/349573/1027368101/180">'
        '<h2><mark>万相</mark>之王</h2>'
        '<p class="_searchBookDesc_x">天地间，有万相。</p>'
        '<p class="_searchBookAuthor_x">天蚕土豆</p>'
        '<div class="_tags_x"><p>玄幻</p><p>连载</p><p>479万字</p></div>'
        '</a></div>';

    test('书名从 h2 拼回（<mark> 高亮不丢字），封面补 https:', () {
      final list = QidianSource.parseSearch(page);
      expect(list.length, 1);
      final b = list.single;
      expect(b.title, '万相之王');
      expect(b.author, '天蚕土豆');
      expect(b.status, '连载');
      expect(b.id, '1027368101');
      expect(b.url, 'https://m.qidian.com/book/1027368101/');
      expect(b.cover, 'https://bookcover.yuewen.com/qdbimg/349573/1027368101/180');
      expect(b.intro, '天地间，有万相。');
    });

    test('首页卡没有简介 / 状态也能出条目', () {
      const home = '<li><a data-bid="1" href="//m.qidian.com/book/1/" '
          'title="某书在线阅读"><img data-src="//x/c.jpg"></a>'
          '<figcaption><h2>某书</h2></figcaption><p>某作者</p></li>';
      final list = QidianSource.parseBookCards(home);
      expect(list.single.title, '某书');
      expect(list.single.author, '某作者');
      expect(list.single.intro, isNull);
    });
  });

  group('详情（JSON-LD）', () {
    const html = '<script type="application/ld+json">{"@context":"https://schema.org",'
        '"@graph":[{"@type":"Book","name":"万相之王",'
        '"author":{"@type":"Person","name":"天蚕土豆"},'
        '"image":"https://bookcover.yuewen.com/qdbimg/349573/1027368101/600",'
        '"description":"天地间，有万相。",'
        '"additionalProperty":[{"name":"连载状态","value":"连载"},'
        '{"name":"最新章节","value":"第1837章 大结局"}]}]}</script>';

    test('书名/作者/简介/状态/最新章节/封面都解出来', () {
      const fallback = Book(
          sourceId: 'qidian', id: '1027368101', url: 'u', title: '旧名');
      final b = QidianSource.parseDetailInfo(html, fallback);
      expect(b.title, '万相之王');
      expect(b.author, '天蚕土豆');
      expect(b.status, '连载');
      expect(b.latest, '第1837章 大结局');
      expect(b.cover, endsWith('/600'));
      expect(b.id, '1027368101');
    });

    test('没有 JSON-LD 就沿用手上的字段，不抛错', () {
      const fallback = Book(sourceId: 'qidian', id: '1', url: 'u', title: 'T');
      expect(QidianSource.parseDetailInfo('<html></html>', fallback).title, 'T');
    });
  });

  group('目录', () {
    const bid = '1027368101';
    final html = '<a class="_secondHeader_x" data-cid="999" '
            'href="//m.qidian.com/chapter/$bid/999/" data-bid="$bid">'
            '<h3>最新章节</h3></a>'
        '<a class="_chapterItem_x" data-cid="111" '
            'href="//m.qidian.com/chapter/$bid/111/" data-bid="$bid">'
            '<h2>第一章 我有三个相宫</h2></a>'
        '<a class="_chapterItem_x" data-cid="222" '
            'href="//m.qidian.com/chapter/$bid/222/" data-bid="$bid">'
            '<h2>第二章 相术</h2></a>';

    test('按页面顺序收章，跳过顶部「最新章节」快捷入口（否则整个目录倒序）', () {
      final chs = QidianSource.parseCatalog(html, bid);
      expect(chs.map((c) => c.title), ['第一章 我有三个相宫', '第二章 相术']);
      expect(chs.first.url, 'https://m.qidian.com/chapter/$bid/111/');
    });
  });

  group('正文', () {
    test('<p> 段落去掉全角缩进，空段不要', () {
      const html = '<main class="content r-font-black"><p>\u3000\u3000第一段</p>'
          '<p>\u3000\u3000</p><p>\u3000\u3000第二段</p></main>';
      expect(QidianSource.parseChapter(html), ['第一段', '第二段']);
    });

    test('VIP 章（lock-mask / 登录订阅本章）明确报错，不返回半截正文', () {
      const html = '<main class="content lock-mask"><p>\u3000\u3000开头…</p>'
          '<p>登录订阅本章: 15点</p></main>';
      expect(() => QidianSource.parseChapter(html),
          throwsA(isA<Exception>()));
    });

    test('正文出现字体反爬码位就报错（宁可不吐乱码）', () {
      const html = '<main class="content"><p>\u3000\u3000\uE3E9\uE3EA</p></main>';
      expect(() => QidianSource.parseChapter(html),
          throwsA(isA<Exception>()));
    });

    test('找不到正文容器 → 报错', () {
      expect(() => QidianSource.parseChapter('<html></html>'),
          throwsA(isA<Exception>()));
    });
  });
}
