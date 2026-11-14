// OwllookSource 解析层离线回归：搜索 / 目录 / 正文全部用真实抓取的 fixture，
// 纯静态函数，不打网络。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/owllook_source.dart';

void main() {
  group('搜索结果解析 parseOwllookSearch', () {
    // 真实 /search?wd= 的结构：a[href^="/chapter?"]，文字「站点--书名--作者」
    const fixture = '''
<a href="/chapter?url=http://a.test/book/1/&amp;novels_name=斗破苍穹">必去小说网--斗破苍穹--天蚕土豆</a>
<a href="/chapter?url=https://b.test/1/&amp;novels_name=斗破苍穹">爱曲小说--斗破苍穹之财动乾坤--辛酸盐</a>
<a href="/chapter?url=http://c.test/2&amp;novels_name=斗破苍穹">言情小说阁--斗破苍穹.2--柴老五</a>
<a href="/md/books">我的书架</a>
''';

    test('精确书名排最前，同人/衍生按包含关系排后', () {
      final hits = OwllookSource.parseOwllookSearch(fixture, '斗破苍穹');
      expect(hits.first.title, '斗破苍穹');
      expect(hits.first.author, '天蚕土豆');
      expect(hits.first.intro, '来自 必去小说网');
      expect(hits.first.url,
          'https://www.owllook.top/chapter?url=http://a.test/book/1/&novels_name=斗破苍穹');
      expect(hits.length, 3);
    });

    test('重复 chapterUrl 去重', () {
      final dup = '$fixture'
          '<a href="/chapter?url=http://a.test/book/1/&amp;novels_name=斗破苍穹">重复</a>';
      expect(
          OwllookSource.parseOwllookSearch(dup, '斗破苍穹').length, 3);
    });

    test('无关页面返回空', () {
      expect(OwllookSource.parseOwllookSearch('<html>没有结果</html>', 'x'),
          isEmpty);
    });
  });

  group('目录页解析 parseOwllookChapters', () {
    // 真实 /chapter?url=… 页：hidden #url/#novels_name/#content_url + 目录链接。
    // content_url=0 时正文地址 = #url + 相对链接（list.js 规则）。
    const fixture = '''
<input id="content_url" type="hidden" value="0">
<input id="url" type="hidden" value="http://a.test/book/1/">
<input id="novels_name" type="hidden" value="斗破苍穹">
<div class="book_list"><ul>
<li><a href="63431642.html">第1章 梦开始的地方</a></li>
<li><a href="63431643.html">第2章 张嘴就来</a></li>
</ul></div>''';

    test('按 list.js 规则拼出 owllook_content 正文地址', () {
      final r = OwllookSource.parseOwllookChapters(fixture);
      final u1 = Uri.encodeQueryComponent('http://a.test/book/1/63431642.html');
      final n1 = Uri.encodeQueryComponent('第1章 梦开始的地方');
      final cu = Uri.encodeQueryComponent('http://a.test/book/1/');
      final nn = Uri.encodeQueryComponent('斗破苍穹');
      expect(r.novelsName, '斗破苍穹');
      expect(r.chapters.length, 2);
      expect(r.chapters[0].title, '第1章 梦开始的地方');
      expect(r.chapters[0].url,
          'https://www.owllook.top/owllook_content?url=$u1&name=$n1&chapter_url=$cu&novels_name=$nn');
    });

    test('content_url=1：链接本身已是完整地址，不再拼接', () {
      final f1 = fixture
          .replaceAll('value="0"', 'value="1"')
          .replaceAll('href="63431642.html"', 'href="http://a.test/c/1.html"');
      final r = OwllookSource.parseOwllookChapters(f1);
      expect(r.chapters.first.url,
          contains('url=http%3A%2F%2Fa.test%2Fc%2F1.html'));
    });

    test('重复正文地址去重', () {
      const dup = '$fixture<li><a href="63431642.html">重复</a></li>';
      // 同一个 contentUrl 但标题不同 → 按正文地址去重，只留第一条
      final r = OwllookSource.parseOwllookChapters(dup);
      expect(r.chapters.length, 2);
    });

    test('无目录 → 空列表', () {
      expect(OwllookSource.parseOwllookChapters('<html>空</html>').chapters,
          isEmpty);
    });

    test('all-chapter + ul.info + content_url 是绝对 base（biqge365 式）', () {
      const f2 = '''
<input id="content_url" type="hidden" value="https://www.biquge365.net">
<input id="url" type="hidden" value="https://www.biquge365.net/newbook/65301/">
<input id="novels_name" type="hidden" value="诡秘之主">
<div class="container all-chapter"><ul class="info">
<li><a href="/chapter/65301/772271.html" title="第一章 绯红">第一章 绯红</a></li>
<li><a href="/chapter/65301/082271.html" title="第二章 情况">第二章 情况</a></li>
</ul></div>
<a href="/md/books">我的书架</a>''';
      final r = OwllookSource.parseOwllookChapters(f2);
      expect(r.chapters.length, 2);
      final target = Uri.encodeQueryComponent(
          'https://www.biquge365.net/chapter/65301/772271.html');
      expect(r.chapters.first.url.split('&').first,
          'https://www.owllook.top/owllook_content?url=$target');
      expect(r.chapters.first.title, '第一章 绯红');
    });
  });

  group('正文解析 parseOwllookContent', () {
    // 真实 /owllook_content 页：div#htmlContent 内 <br/> 分段。
    const fixture = '''
<div class="show-content">
<div class="contentbox clear" id="htmlContent">    “……斗者，一星！”<br/>
<br/>    一群人不约而同的开始倒吸冷气。<br/>
<br/>    萧炎面色平静，快步回到了自己的房间。</div>
</div>
<div class="pre_next"><a>上一页</a><a>下一页</a></div>''';

    test('按 br 切段、全角空格归一、导航行不进正文', () {
      final paras = OwllookSource.parseOwllookContent(fixture);
      expect(paras.length, 3);
      expect(paras[0], '“……斗者，一星！”');
      expect(paras[1], contains('倒吸冷气'));
      expect(paras[2], contains('快步回到了自己的房间'));
      expect(paras.any((p) => p == '上一页' || p == '下一页'), isFalse);
    });

    test('无正文容器 → 空列表', () {
      expect(OwllookSource.parseOwllookContent('<html>404</html>'), isEmpty);
    });

    test('标准版正文容器 div.show-content > div#txt（真机第142章式）', () {
      const page = '''
<div class="container all-content">
 <div class="left-bar-list"><div>目录</div><div>设置</div></div>
 <div class="show-content"><div class="txt" id="txt">
 <p><br>    “看起来很不错。”<br/>    接着，我告别黄贝贝。<br/>
 </div></div>
 <div class="pre_next"><a>上一页</a><a>下一页</a></div>
</div>''';
      final paras = OwllookSource.parseOwllookContent(page);
      expect(paras.length, 2);
      expect(paras[0], contains('看起来很不错'));
      expect(paras[1], contains('告别黄贝贝'));
      expect(paras.join(), isNot(contains('目录'))); // 不取外层导航
    });
  });

  group('榜单页 → Book 列表 parseOwllookRank', () {
    test('书名去重，url 指向站内搜索页（详情阶段再解析目录）', () {
      const fixture = '''
<table class="mdui-table"><tbody>
<tr><td>1</td><td><a href="/search?wd=大奉打更人">大奉打更人</a></td></tr>
<tr><td>2</td><td><a href="/search?wd=大奉打更人">大奉打更人</a></td></tr>
<tr><td>3</td><td><a href="/search?wd=剑来">剑来</a></td></tr>
</tbody></table>''';
      final books = OwllookSource.parseOwllookRank(fixture);
      expect(books.length, 2);
      expect(books[0].title, '大奉打更人');
      expect(books[0].url,
          'https://www.owllook.top/search?wd=${Uri.encodeQueryComponent('大奉打更人')}');
      expect(books[0].sourceId, OwllookSource.sourceId);
    });
  });

  group('源登记', () {
    test('id / baseUrl / 榜单页签', () {
      final s = OwllookSource();
      expect(s.id, 'owllook');
      expect(s.baseUrl, 'https://www.owllook.top');
      expect(s.isImageBook, isFalse);
    });
  });
}
