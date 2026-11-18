import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/collect/hot_board.dart';
import 'package:shuangyue/sources/fanqie.dart';
import 'package:shuangyue/sources/fanqie_font.dart';

/// 番茄书源的离线单测：字体表解码 + __INITIAL_STATE__ 解析 + 详情/正文解析。
///
/// 联网链路（首页推荐 / 目录接口 / 正文）见 tool/fanqie_probe.dart，
/// 这里只覆盖「给一段站点原样返回，能不能解对」的部分。
void main() {
  group('字体反爬还原', () {
    test('PUA 码位换成真字，非 PUA 原样保留', () {
      // e3e9=在 e3ea=主 e3eb=特：站点把「在」等常用字换成了私有区码位
      expect(decodeFanqieText('\uE3E9\uE3EA\uE3EB'), '在特'.length == 2 ? '在主特' : '');
      expect(decodeFanqieText('第1章 \uE3E9'), '第1章 在');
      expect(decodeFanqieText('abc，。！123'), 'abc，。！123');
      expect(decodeFanqieText(''), '');
    });

    test('表里没有的 PUA 码位保持原样（宁可不改，也别写错字）', () {
      // U+F8FF 不在 363 条之内
      expect(decodeFanqieText('\uF8FF'), '\uF8FF');
    });
  });

  group('__INITIAL_STATE__ 解析', () {
    test('裸 undefined 与尾部包装代码都能吃掉', () {
      const html = '<script>window.__INITIAL_STATE__='
          '{"page":{"bookName":"\uE3E9","x":undefined,"list":[1,undefined]}}'
          ';\n})()</script>';
      final st = FanqieSource.initialState(html);
      expect(st, isNotNull);
      final page = st!['page'] as Map;
      expect(page['bookName'], '\uE3E9');
      expect(page['x'], isNull);
      expect((page['list'] as List).length, 2);
    });

    test('字符串里的花括号不打断括号配对', () {
      const html = '__INITIAL_STATE__={"a":"}{","b":1};</script>';
      final st = FanqieSource.initialState(html);
      expect(st!['a'], '}{');
      expect(st['b'], 1);
    });

    test('没有 state 返回 null', () {
      expect(FanqieSource.initialState('<html></html>'), isNull);
    });
  });

  group('详情解析', () {
    const html = '__INITIAL_STATE__={"page":{'
        '"bookId":"7069948840148732967","bookName":"\uE3E9\uE3EA",'
        '"author":"\uE3EB","abstract":"\uE3EC",'
        '"thumbUrl":"https://x/c.jpg","creationStatus":"1",'
        '"lastChapterTitle":"\uE3ED",'
        '"volumeNameList":["\uE3EE\uE3EF"],'
        '"chapterListWithVolume":[['
        '{"itemId":"111","title":"\uE3F0\uE3F1"},'
        '{"itemId":"222","title":"\uE3F2\uE3F3"}]]}};';

    test('书名/作者/简介/状态/封面与章节表都解出来', () {
      const book = Book(
        sourceId: 'fanqie',
        id: '7069948840148732967',
        url: 'https://fanqienovel.com/page/7069948840148732967',
        title: '旧名',
      );
      final d = FanqieSource.parseDetail(html, book);
      expect(d.book.title, '在主'); // e3e9=在 e3ea=主
      expect(d.book.author, '特');
      expect(d.book.status, '完结');
      expect(d.book.cover, 'https://x/c.jpg');
      expect(d.book.latest, '军');
      expect(d.chapters.length, 2);
      expect(d.chapters.first.url,
          'https://fanqienovel.com/reader/111');
      expect(d.chapters.last.title, '要只'); // e3f2=要 e3f3=只
    });

    test('结构对不上时抛错，不返回半截数据', () {
      expect(
        () => FanqieSource.parseDetail(
            '__INITIAL_STATE__={"page":null};',
            const Book(sourceId: 'fanqie', id: '1', url: 'u', title: 't')),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('正文解析', () {
    test('<p> 分段 + 解码', () {
      final paras = FanqieSource.parseChapterContent(
          '<p>\uE3E9\uE3EA</p><p>hello</p><p> </p>');
      expect(paras, ['在主', 'hello']);
    });

    test('整页取 chapterData.content', () {
      const page = '__INITIAL_STATE__={"reader":{"chapterData":'
          '{"title":"\uE3EB","content":"<p>\uE3E9</p><p>\uE3EA</p>"}}};';
      expect(FanqieSource.parseChapterBody(page), ['在', '主']);
    });

    test('空正文抛错（下架/要登录），不写空缓存', () {
      const page = '__INITIAL_STATE__={"reader":{"chapterData":'
          '{"content":""}}};';
      expect(() => FanqieSource.parseChapterBody(page),
          throwsA(isA<Exception>()));
    });
  });

  group('番茄榜（权威榜页）', () {
    // e3e9=在 e3ea=主 e3eb=特 e3ec=家
    const page = '__INITIAL_STATE__={"rank":{"book_list":[{'
        '"bookId":"7690783449048697881","bookName":"",'
        '"author":"","abstract":"","creationStatus":"0",'
        '"lastChapterTitle":"第1章","thumbUri":"https://x/c.jpg"}]}};';

    test('条目直接带 book（bookId 就是详情页），书名 / 简介回落 PUA 解码', () {
      final items = parseFanqieRank(page, site: '番茄小说', board: '男频阅读榜');
      expect(items.length, 1);
      final i = items.single;
      expect(i.title, '在主');
      expect(i.author, '特');
      expect(i.category, '男频阅读榜');
      expect(i.status, '连载');
      expect(i.book, isNotNull);
      expect(i.book!.id, '7690783449048697881');
      expect(i.book!.sourceId, 'fanqie');
      expect(i.book!.url, 'https://fanqienovel.com/page/7690783449048697881');
    });

    test('结构不对 / 榜单为空 → 空列表（让上层报「站点改版」）', () {
      expect(parseFanqieRank('<html></html>', site: 'x', board: 'y'), isEmpty);
      expect(
          parseFanqieRank('__INITIAL_STATE__={"rank":{}};',
              site: 'x', board: 'y'),
          isEmpty);
    });

    test('番茄榜挂在权威榜第二位（替换原纵横榜）', () {
      expect(HotBoard.all[1].id, 'fanqie_rank');
      expect(HotBoard.all[1].label, '番茄榜');
      expect(HotBoard.fanqieBoards.length, 4);
    });
  });
}
