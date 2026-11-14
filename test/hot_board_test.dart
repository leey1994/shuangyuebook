// 权威榜单（hot_board.dart）解析回归测试：全部离线 fixtures，不打真实网络。
//
// fixtures 来自真实接口的一次抓取（截取结构、缩短条目），站点改版时
// 这里会先红 —— 改解析函数，别改断言语义。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/collect/hot_board.dart';
import 'package:shuangyue/models.dart';

void main() {
  group('17K 订阅榜 Top100 解析', () {
    // 真实结构：div#TOPBOX_TAB 后第一个 <table>，行 = 名次/[分类]/书名(title)/
    // 最新章/更新时间/作者(title)/状态；第一行是 <th> 表头。
    const fixture = '''
<div id="TOPBOX_TAB"></div>
<div class="TYPE"><table width="100%">
<tr><th>排名</th><th>类别</th><th>作品</th><th>最新章节</th><th>更新时间</th><th>作者</th><th>状态</th></tr>
<tr><td width="30">1</td><td width="60"><a href="/all/book/2_14_130______1.html">[时空穿梭]</a></td>
<td><a class="red" href="//www.17k.com/book/3583700.html" title="星痕之门">星痕之门</a></td>
<td><a href="//www.17k.com/chapter/3583700/1.html">病假条</a></td><td>2026-11-12 17:13</td>
<td><a href="//user.17k.com/see/www/?userId=26716073" title="伪戒">伪戒</a></td><td width="30">连载</td></tr>
<tr class="bg"><td width="30">2</td><td width="60"></td>
<td><a class="red" href="//www.17k.com/book/1398783.html" title="九星霸体诀">九星霸体诀</a></td>
<td><a href="//www.17k.com/chapter/1398783/2.html">第一章</a></td><td>2026-11-12 18:00</td>
<td><a href="//user.17k.com/see/www/?userId=1" title="平凡魔术师">平凡魔术师</a></td><td width="30">完结</td></tr>
</table></div>''';

    test('解析出全部条目，名次/分类/作者/状态各就各位', () {
      final r = parse17kSubscribeTop100(fixture);
      expect(r.items.length, 2);
      expect(r.items[0].rank, 1);
      expect(r.items[0].title, '星痕之门');
      expect(r.items[0].author, '伪戒');
      expect(r.items[0].category, '时空穿梭');
      expect(r.items[0].status, '连载');
      expect(r.items[1].rank, 2);
      expect(r.items[1].title, '九星霸体诀');
      expect(r.items[1].author, '平凡魔术师');
      expect(r.items[1].status, '完结');
    });

    test('表头行（无 td / 名次非数字）自动跳过', () {
      final r = parse17kSubscribeTop100(fixture);
      expect(r.items.any((i) => i.title.contains('排名')), isFalse);
    });

    test('页面无 TOPBOX_TAB / 无表格 → 空列表', () {
      expect(parse17kSubscribeTop100('<html>改版了</html>').items, isEmpty);
    });
  });

  group('晋江积分榜解析', () {
    // 真实结构：名次在 <td align="center">N</td>，条目是
    // onebook.php?novelid=… 链接（class=tooltip 的文字是书名），
    // 作者在同区块的 oneauthor.php 链接里，分类是「原创-言情-…」。
    const fixture = '''
<table>
<tr><td height="23" align="center">1</td>
<td height="23">&nbsp;<a title="藤萝为枝" href="oneauthor.php?authorid=2071925">藤萝为枝</a></td>
<td height="23">&nbsp;<a title="偏偏宠爱" href="onebook.php?novelid=3694555" class="tooltip">偏偏宠爱</a></td>
<td height="23" align="center">原创-言情-近代现代-爱情</td></tr>
<tr><td height="23" align="center">2</td>
<td height="23">&nbsp;<a title="竹已" href="oneauthor.php?authorid=1000002">竹已</a></td>
<td height="23">&nbsp;<a title="难哄" href="onebook.php?novelid=2000002" class="tooltip">难哄</a></td>
<td height="23" align="center">原创-言情-近代现代-爱情</td></tr>
</table>''';

    test('名次/书名/作者/分类成对解析，保持榜单顺序', () {
      final r = parseJjwxcScoreBoard(fixture);
      expect(r.items.length, 2);
      expect(r.items[0].rank, 1);
      expect(r.items[0].title, '偏偏宠爱');
      expect(r.items[0].author, '藤萝为枝');
      expect(r.items[0].category, '原创-言情-近代现代-爱情');
      expect(r.items[1].rank, 2);
      expect(r.items[1].title, '难哄');
      expect(r.items[1].author, '竹已');
    });

    test('同一本书重复出现只取第一个名次', () {
      const dup = '$fixture<table><tr>'
          '<td align="center">9</td>'
          '<td><a title="重复" href="oneauthor.php?authorid=9">重复</a></td>'
          '<td><a title="重复" href="onebook.php?novelid=3694555" class="tooltip">偏偏宠爱</a></td>'
          '</tr></table>';
      final r = parseJjwxcScoreBoard(dup);
      expect(r.items.length, 2);
      expect(r.items.any((i) => i.rank == 9), isFalse);
    });

    test('无条目 → 空列表', () {
      expect(parseJjwxcScoreBoard('<html>登录后查看</html>').items, isEmpty);
    });
  });

  group('17K 畅销榜（兜底源）解析', () {
    final fixture = () {
      final lis = StringBuffer();
      lis.write('<li><span class="click">3303</span> '
          '<span class="num  r ">1</span> '
          '<a href="//www.17k.com/book/3583700.html" target="_blank">星痕之门</a> '
          '<a class="book" href="//www.17k.com/book/3583700.html" target="_blank"> '
          '<img src="https://img.test/cover.jpg" alt="星痕之门">世间有星门，入者皆成神。</a></li>');
      lis.write('<li> <span class="num  r ">2</span> '
          '<a href="//www.17k.com/book/1398783.html" target="_blank">九星霸体诀</a></li>');
      lis.write('<li> <span class="num ">3</span> '
          '<a href="//www.17k.com/book/3660623.html" target="_blank">东北风云：黑血漫...</a></li>');
      lis.write('<li class="more"><a href="/top/x.html">更多</a> 更新时间：2026-11-14 14:20</li>');
      return '''
<div class="TABBOX">
  <div class="Title1"><h2 class="tit">畅销榜</h2></div>
  <div class="TYPE"><ul class="BOX Top1">$lis</ul></div>
</div>''';
    }();

    test('识别畅销榜区块，名次 / 书名 / 封面各就各位', () {
      final r = parse17kSalesBoard(fixture);
      expect(r.items.length, 3);
      expect(r.items[0].rank, 1);
      expect(r.items[0].title, '星痕之门');
      expect(r.items[1].title, '九星霸体诀');
      expect(r.items[0].cover, 'https://img.test/cover.jpg');
      expect(r.siteUpdated, '2026-11-14 14:20');
    });

    test('截断书名去掉省略号（匹配时按前缀兼容）', () {
      final items = parse17kSalesBoard(fixture).items;
      expect(items[2].title, '东北风云：黑血漫');
    });

    test('「更多」行不进榜（没有 /book/ 书名链接）', () {
      final items = parse17kSalesBoard(fixture).items;
      expect(items.any((i) => i.title.contains('更多')), isFalse);
    });

    test('畅销榜缺席时回退推荐票榜 / 作品点击榜', () {
      const body = '''
<div class="TABBOX"><div class="Title1"><h2 class="tit">推荐票榜</h2></div>
<div class="TYPE"><ul class="BOX"><li><span class="num">1</span>
<a href="//www.17k.com/book/1.html">榜首书</a></li></ul></div></div>''';
      final items = parse17kSalesBoard(body).items;
      expect(items.length, 1);
      expect(items[0].title, '榜首书');
    });

    test('页面解析不出任何榜单 → 空列表', () {
      expect(parse17kSalesBoard('<html><body>改版了</body></html>').items,
          isEmpty);
    });
  });

  group('owllook 榜单解析', () {
    // 真实 /md/qidian 的表格结构：每个 table 一个分榜，行 = 名次 + 书名链接。
    const fixture = '''
<div class="mdui-container">
<table class="mdui-table">
<thead><tr><th>#</th><th><a href="https://www.qidian.com/rank/yuepiao/">月票榜</a></th></tr></thead>
<tbody>
<tr><td>1</td><td><a href="/search?wd=玄鉴仙族">玄鉴仙族</a></td></tr>
<tr><td>2</td><td><a href="/search?wd=夜无疆">夜无疆</a></td></tr>
</tbody></table>
<table class="mdui-table">
<thead><tr><th>#</th><th><a href="https://www.qidian.com/rank/hotsales/">畅销榜</a></th></tr></thead>
<tbody>
<tr><td>1</td><td><a href="/search?wd=夜无疆">夜无疆</a></td></tr>
<tr><td>2</td><td><a href="/search?wd=诡秘之主">诡秘之主</a></td></tr>
</tbody></table>
</div>''';

    test('多分榜合并去重，rank 连续，分榜名进 category', () {
      final r = parseOwllookBoard(fixture, site: 'owllook·起点榜');
      expect(r.items.length, 3); // 夜无疆 在两张表出现，只留一次
      expect(r.items[0].rank, 1);
      expect(r.items[0].title, '玄鉴仙族');
      expect(r.items[0].category, '月票榜');
      expect(r.items[1].title, '夜无疆');
      expect(r.items[1].rank, 2);
      expect(r.items[2].title, '诡秘之主');
      expect(r.items[2].rank, 3);
    });

    test('Owllook 搜索次数榜：hint 带搜索次数，表头「小说名」不当分类', () {
      const hot = '''
<table class="mdui-table">
<thead><tr><th>#</th><th>小说名</th><th>搜索次数</th></tr></thead>
<tbody>
<tr><td>1</td><td><a href="/search?wd=大奉打更人">大奉打更人</a></td><td>153996</td></tr>
<tr><td>2</td><td><a href="/search?wd=剑来">剑来</a></td><td>68831</td></tr>
</tbody></table>''';
      final r = parseOwllookBoard(hot,
          site: 'owllook·搜索榜', withSearchCount: true);
      expect(r.items.length, 2);
      expect(r.items[0].title, '大奉打更人');
      expect(r.items[0].hint, '153996');
      expect(r.items[0].category, isNull);
      expect(r.items[1].hint, '68831');
    });

    test('页面无榜单表格 → 空列表', () {
      expect(parseOwllookBoard('<html>改版了</html>', site: 'x').items,
          isEmpty);
    });
  });

  group('榜单定义与缓存', () {
    test('三个 owllook 权威榜：起点 / 纵横 / 搜索榜，id 稳定', () {
      expect(HotBoard.all.length, 3);
      expect(HotBoard.all[0].id, 'owllook_qidian');
      expect(HotBoard.all[1].id, 'owllook_zongheng');
      expect(HotBoard.all[2].id, 'owllook_hot');
      expect(HotBoard.all[2].kind, HotBoardKind.search);
      expect(HotBoard.all[2].url, endsWith('/md/'));
      expect(HotBoard.byId('owllook_qidian').site, 'owllook·起点榜');
      expect(HotBoard.byId('不存在').id, 'owllook_qidian');
    });

    test('10 分钟内命中缓存，clear 后失效', () {
      HotBoardCache.clear();
      const board = HotBoard.owllookQidian;
      final data = HotBoardData(
        board: board,
        items: const [HotItem(rank: 1, title: '测试书', site: 'x')],
        fetchedAt: DateTime.now(),
      );
      HotBoardCache.put(data);
      expect(HotBoardCache.get(board.id), same(data));
      HotBoardCache.clear(board.id);
      expect(HotBoardCache.get(board.id), isNull);
    });

    test('过期缓存不再返回', () {
      HotBoardCache.clear();
      const board = HotBoard.owllookQidian;
      HotBoardCache.put(HotBoardData(
        board: board,
        items: const [],
        fetchedAt: DateTime.now().subtract(const Duration(minutes: 11)),
      ));
      expect(HotBoardCache.get(board.id), isNull);
    });
  });

  group('展示兜底（rank_screen _coverBook 的数据来源）', () {
    test('未匹配条目用榜单自带的书名/作者/封面构造展示书', () {
      const item = HotItem(
        rank: 5,
        title: '某本没匹配上的书',
        site: 'owllook·起点榜',
        author: '某人',
        cover: 'https://img.test/c.jpg',
        status: '连载',
      );
      final book = Book(
        sourceId: '',
        id: '',
        url: '',
        title: item.title,
        author: item.author,
        cover: item.cover,
        status: item.status,
      );
      expect(book.title, '某本没匹配上的书');
      expect(book.cover, 'https://img.test/c.jpg');
      expect(book.url, ''); // 空 url：点开必须走「去搜索」路径，不是详情页
    });
  });
}
