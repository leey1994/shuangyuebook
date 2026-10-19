// 引擎兼容性修复的单测：URL 模板（含 2.0 旧语法）/ :has 选择器 / POST 默认表单头与
// 编码 / 请求头清洗 / 搜索结果明细归因 / 模板引擎（{{}}·@put·@get）/ JSONPath 增强 /
// CSS 阶段（排除·切片·jsoup 伪类）/ XPath 谓词与自动路由。全部离线，不打真实网络。
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shuangyue/legado/analyze_css.dart';
import 'package:shuangyue/legado/analyze_json.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/analyze_xpath.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/rule_analyzer.dart';
import 'package:shuangyue/legado/source_store.dart';

String? _headerOf(http.BaseRequest req, String name) {
  for (final e in req.headers.entries) {
    if (e.key.toLowerCase() == name) return e.value;
  }
  return null;
}

void main() {
  group('parseUrlTemplate', () {
    test('旧版 @post-> 语法翻译为 POST 请求选项', () {
      final t = parseUrlTemplate(
        'https://m.libahao2.com/search.php@post->keyword={{key}}',
      );
      expect(t.url, 'https://m.libahao2.com/search.php');
      expect(t.options['method'], 'POST');
      expect(t.options['body'], 'keyword={{key}}');
    });

    test('旧版 @get-> 语法并入查询串', () {
      final t = parseUrlTemplate('https://a.com/s@get->q={{key}}&p=1');
      expect(t.url, 'https://a.com/s?q={{key}}&p=1');
      expect(t.options['method'], isNull);
    });

    test('<js> 前置块剥离后保留明文地址', () {
      final t = parseUrlTemplate(
        '<js>java.removeCookie("dualstack");</js>\nhttps://a.com/search?q={{key}}',
      );
      expect(t.url, 'https://a.com/search?q={{key}}');
    });

    test('前置块与 ,{...} 请求选项共存', () {
      final t = parseUrlTemplate(
        '<js>x = 1;</js> https://a.com/s,{"method":"POST","body":"k={{key}}"}',
      );
      expect(t.url, 'https://a.com/s');
      expect(t.options['method'], 'POST');
    });

    test('纯 JS 搜索入口不剥离（由上层明确报错）', () {
      final t = parseUrlTemplate('<js>var u = "https://a.com/" + key;</js>');
      expect(t.url.contains('<js'), isTrue);
    });
  });

  group(':has() 降级选择器', () {
    final doc = parseHtml('''
<ul class="novelslist2">
  <li class="c1"><a href="/b/1">斗破苍穹</a></li>
  <li class="c2"><span>占位</span></li>
</ul>''');

    test('li:has(a) 过滤出含后代 a 的 li', () {
      final els = selectElements(doc, 'ul.novelslist2 li:has(a)');
      expect(els.length, 1);
      expect(els.first.querySelector('a')!.attributes['href'], '/b/1');
    });

    test('原选择器语义不受影响', () {
      expect(selectElements(doc, 'ul.novelslist2 li').length, 2);
      expect(selectElements(doc, 'li:has(table)'), isEmpty);
    });

    test('复杂形态回退原逻辑（不崩、同「找不到元素」语义）', () {
      expect(selectElements(doc, 'li:has(a, span)'), isEmpty);
    });

    test('首段属性名回退：单段 href 取属性，单段标签仍作选择器', () {
      final e = AnalyzeRule(
        '<ul class="list"><li><a href="/b/1">书一</a></li></ul>',
        baseUrl: 'https://t.com',
      );
      final li = e.getRawList('li').first;
      final a = e.getRawList('a').first;
      // `href` → 选择器选不到 <href> 标签 → 回退取当前节点的 href 属性
      expect(e.getString('href', ctx: a), '/b/1');
      // 单段标签在行元素上是选择器（修前被当属性提取 → 整行为空）
      expect(e.getString('a@href', ctx: li), '/b/1');
      expect(e.getString('a@text', ctx: li), '书一');
    });
  });

  group('POST 请求', () {
    test('缺省补表单 Content-Type；charset=gbk 时按 GBK 编码请求体', () async {
      http.Request? captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response('ok', 200);
      });
      final client = SourceHttpClient(client: mock);

      await client.post('https://a.com/s.php', body: 'keyword=值');
      expect(
        _headerOf(captured!, 'content-type'),
        'application/x-www-form-urlencoded',
      );
      expect(utf8.decode(captured!.bodyBytes), 'keyword=值');

      await client.post(
        'https://a.com/s.php',
        body: 'keyword=值',
        charset: 'gbk',
      );
      expect(
        _headerOf(captured!, 'content-type'),
        'application/x-www-form-urlencoded; charset=gbk',
      );
      expect(gbk.decode(captured!.bodyBytes), 'keyword=值');
    });

    test('书源已给 Content-Type 时不覆盖', () async {
      http.Request? captured;
      final mock = MockClient((req) async {
        captured = req;
        return http.Response('ok', 200);
      });
      final client = SourceHttpClient(client: mock);
      await client.post(
        'https://a.com/s.php',
        headers: {'Content-Type': 'application/json'},
        body: '{}',
      );
      expect(_headerOf(captured!, 'content-type'), 'application/json');
    });
  });

  test('非法请求头名 / 含换行的值被清洗，合法头保留', () async {
    http.Request? captured;
    final mock = MockClient((req) async {
      captured = req;
      return http.Response('ok', 200);
    });
    final client = SourceHttpClient(client: mock);
    await client.request(
      'GET',
      'https://a.com/',
      headers: {
        'User\u2011Agent': 'x', // U+2011 连字符：非 RFC token，须丢弃
        'X-Ok': 'fine',
        'X-Bad': 'a\r\nInjected: 1',
      },
    );
    expect(_headerOf(captured!, 'x-ok'), 'fine');
    // 默认 UA 仍在（真书源里的假冒 UA 头被丢弃后不裸奔）
    expect(
      captured!.headers.entries.any(
        (e) => e.key.toLowerCase() == 'user-agent' && e.value.isNotEmpty,
      ),
      isTrue,
    );
    expect(captured!.headers.keys.any((k) => k.contains('\u2011')), isFalse);
    expect(_headerOf(captured!, 'x-bad'), isNull);
  });

  group('搜索结果明细归因', () {
    BookSource mk(String bookUrlRule) => BookSource.fromJson({
          'bookSourceName': '测试',
          'bookSourceUrl': 'https://t.com',
          'bookSourceType': 0,
          'searchUrl': 'https://t.com/s?q={{key}}',
          'ruleSearch': {
            'bookList': '.list li',
            'name': 'a@text',
            'bookUrl': bookUrlRule,
          },
        });

    const html =
        '<ul class="list"><li><a href="/b/1">书一</a></li><li><a href="/b/2">书二</a></li></ul>';

    test('bookUrl 依赖 JS（java.getString）：有 JS 解析 2 本 / 无 JS 降级明细 2 条', () {
      final repo = OnlineRepo(store: SourceStore());
      final r =
          repo.parseSearchPageDetailed(mk('@js:java.getString("a@href")'), html);
      if (r.books.isEmpty) {
        // 无 JS 桥（DLL 缺失）降级路径：bookUrl 整条求值失败 → 明细 2 条供排障
        expect(r.rows, 2);
        expect(r.noUrl, 2);
        expect(r.noName, 0);
      } else {
        // 有 JS 桥：java.getString 正常求值（对齐 legado）
        expect(r.books.length, 2);
        expect(r.books.first.bookUrl, 'https://t.com/b/1');
        expect(r.books.last.bookUrl, 'https://t.com/b/2');
        expect(r.noUrl, 0);
        expect(r.noName, 0);
      }
    });

    test('明文规则 → 正常解析且无失败计数', () {
      final repo = OnlineRepo(store: SourceStore());
      final r = repo.parseSearchPageDetailed(mk('a@href'), html);
      expect(r.books.length, 2);
      expect(r.books.first.bookUrl, 'https://t.com/b/1');
      expect(r.noUrl, 0);
      expect(r.noName, 0);
    });

    test('bookUrl 最后求值：可用 {{book.kind}}（字段先于链接解析）', () {
      final repo = OnlineRepo(store: SourceStore());
      final src = BookSource.fromJson({
        'bookSourceName': '测试',
        'bookSourceUrl': 'https://t.com',
        'bookSourceType': 0,
        'searchUrl': 'https://t.com/s?q={{key}}',
        'ruleSearch': {
          'bookList': '.list li',
          'name': 'a@text',
          'kind': 'em@text',
          'bookUrl': 'https://t.com/b/{{book.kind}}',
        },
      });
      final r = repo.parseSearchPageDetailed(
        src,
        '<ul class="list"><li><a href="/b/1">书一</a><em>玄幻</em></li></ul>',
      );
      expect(r.books.length, 1);
      expect(r.books.single.kind, '玄幻');
      expect(r.books.single.bookUrl, 'https://t.com/b/玄幻');
    });
  });

  group('模板引擎（{{}} / {\$} / @put / @get / @@）', () {
    test('{{key}} 按 UTF-8 编码；算术表达式不编码', () {
      expect(
        renderUrlTemplate('https://a.com/s?q={{key}}', {'key': '穿越 火线'}),
        'https://a.com/s?q=${Uri.encodeComponent('穿越 火线')}',
      );
      expect(
        renderUrlTemplate('https://a.com/s?p={{ (page-1)*10 }}', {'page': 3}),
        'https://a.com/s?p=20',
      );
    });

    test('charset=gbk 时 key 按 GBK 百分号编码', () {
      expect(
        renderUrlTemplate(
          'https://a.com/s?q={{key}}',
          {'key': '穿越'},
          charset: 'gbk',
        ),
        'https://a.com/s?q=%B4%A9%D4%BD',
      );
    });

    test('未知表达式（java.* / 语句 JS）降级为空串', () {
      expect(
        renderUrlTemplate('https://a.com/s?q={{java.md5(key)}}', {'key': 'x'}),
        'https://a.com/s?q=',
      );
    });

    test('{{@@规则}} 引用另一条规则的结果', () {
      final e = AnalyzeRule('<h3 class="t">书名</h3>');
      expect(e.getString('{{@@.t@text}}'), '书名');
    });

    test('@put 求值后可由 @get 回填（宜搜式目录地址）', () {
      final e = AnalyzeRule(
        '<ul class="list"><li data-nid="77"><a href="/b/77">书A</a></li></ul>',
        baseUrl: 'https://t.com',
      );
      final li = e.getRawList('li').first;
      expect(e.getString('a@text@put:{nid:data-nid}', ctx: li), '书A');
      expect(
        e.getString('https://t.com/toc?nid=@get:{nid}', ctx: li),
        'https://t.com/toc?nid=77',
      );
    });

    test('单花括号 {\$JSONPath} 以当前上下文求值', () {
      final e = AnalyzeRule('{"list":[{"id":42}]}');
      final item = e.getRawList(r'$.list[*]').first;
      expect(
        e.getString('https://a.com/b/{\$.id}', ctx: item),
        'https://a.com/b/42',
      );
    });

    test('字面 URL 规则不再被当 CSS 选择器吞掉', () {
      final e = AnalyzeRule('<div>x</div>');
      expect(
        e.getString('https://t.com/toc?nid=77'),
        'https://t.com/toc?nid=77',
      );
    });

    test('尾随 @js: 剥离（保留脚本前结果，无 JS 引擎的尽力降级）', () {
      final e = AnalyzeRule('<a href="/b/1">书一</a>');
      expect(e.getString('a@text@js:result.trim()'), '书一');
    });

    test('纯模板字段渲染后即为值（kind 常见写法）', () {
      final e = AnalyzeRule('{"category":"玄幻","finished":"连载"}');
      expect(
        e.getString('{{\$.category}},{{\$.finished}}@js:result'),
        '玄幻,连载',
      );
    });

    test('java.getString 模拟（JSONPath 取值）', () {
      final e = AnalyzeRule('{"category":"玄幻"}');
      expect(
        e.getString("{{java.getString('\$.category')}}"),
        '玄幻',
      );
    });

    test('buildRequest 剥离搜索地址尾随 @js', () {
      final t = buildRequest(
        'https://a.com/s?q={{key}}@js:java.md5(key)',
        'https://a.com',
        {'key': 'x'},
      );
      expect(t.url, 'https://a.com/s?q=x');
    });
  });

  group('JSONPath 增强', () {
    final data = {
      'list': [
        {'id': 1, 'x': 1},
        {'id': 2},
        {'id': 3, 'x': 3},
      ],
    };

    test('过滤 [?(...)]：存在 / 比较 / || 组合', () {
      expect(jsonSelect(data, r'$.list[?(@.x)]').length, 2);
      expect(jsonSelect(data, r'$.list[?(@.x >= 3)]').length, 1);
      expect(jsonSelect(data, r'$.list[?(@.id==1 || @.id==3)]').length, 2);
    });

    test('切片 / 多下标 / 负下标', () {
      expect(jsonSelect(data, r'$.list[0:2]').length, 2);
      expect((jsonSelect(data, r'$.list[-1]').single as Map)['id'], 3);
      expect(jsonSelect(data, r'$.list[0,2]').length, 2);
    });

    test(r'$..[?(...)] 全后代过滤（真实源写法）', () {
      final d = {
        'data': {
          'books': [
            {'novelName': 'A'},
            {'other': 1},
            {'novelName': 'B'},
          ],
        },
      };
      expect(jsonSelect(d, r'$..[?(@.novelName)]').length, 2);
    });

    test(r'$.[*] 宽松写法', () {
      expect(jsonSelect([1, 2, 3], r'$.[*]').length, 3);
    });
  });

  group('CSS 规则阶段（排除 / 切片 / 下标 / jsoup 伪类）', () {
    final e = AnalyzeRule(
      '<ul class="u"><li>1</li><li>2</li><li>3</li><li>4</li></ul>',
    );

    test('!N 排除与 [N:M] 切片 / [n,m] 多下标', () {
      expect(e.getStrings('li!0@text'), ['2', '3', '4']);
      expect(e.getStrings('li!0:1@text'), ['3', '4']);
      expect(e.getStrings('class.u@tag.li[1:3]@text'), ['2', '3']);
      expect(e.getStrings('li[0,3]@text'), ['1', '4']);
    });

    test('负下标与 .N 合并写法', () {
      expect(e.getString('li.0@text'), '1');
      expect(e.getString('li.-1@text'), '4');
    });

    test('jsoup 位置伪类 :lt/:gt/:eq 与类型位置', () {
      final ul = parseHtml('<ul><li>1</li><li>2</li><li>3</li></ul>');
      expect(selectElements(ul, 'li:lt(2)').length, 2);
      expect(selectElements(ul, 'li:gt(1)').length, 1);
      expect(selectElements(ul, 'li:eq(1)').first.text, '2');
      final p = parseHtml('<div><p>a</p><span>s</span><p>b</p></div>');
      expect(selectElements(p, 'p:nth-of-type(2)').first.text, 'b');
      expect(selectElements(p, 'p:first-of-type').first.text, 'a');
    });

    test('属性正则 [attr~=a|b]', () {
      final doc = parseHtml(
        '<div><i property="category">1</i><i property="status">2</i>'
        '<i property="other">3</i></div>',
      );
      expect(selectElements(doc, 'i[property~=category|status]').length, 2);
    });

    test('## 替换链作用于未折叠空白的原始串（P1-4）', () {
      // XPath 文本节点：原始换行保留（CSS @text 按 jsoup 语义归一，无原始串）
      final eng = AnalyzeRule(
        '<div><p>第一段\n\n\n第二段</p></div>',
      );
      expect(eng.getString(r'//p/text()##\n+##|'), '第一段|第二段');
      expect(eng.getString(r'//p/text()##\s+##+'), '第一段+第二段');
      // JSON 值同样是原始串
      final j = AnalyzeRule('{"c":"甲\\n\\n乙"}');
      expect(j.getString(r'$.c##\n+##/'), '甲/乙');
    });
  });

  group('XPath 谓词', () {
    final xmlDoc = parseXmlLoose(
      '<div><a href="/n1">开始阅读</a><a href="/n2">下一页</a></div>',
    )!;

    test('[text()="v"] 与 contains()', () {
      expect(
        evalXPath(xmlDoc, '//a[text()="开始阅读"]/@href').strings,
        ['/n1'],
      );
      expect(
        evalXPath(xmlDoc, "//a[contains(text(),'下一')]/@href").strings,
        ['/n2'],
      );
      expect(
        evalXPath(xmlDoc, "//a[contains(@href,'/n2')]/@href").strings,
        ['/n2'],
      );
    });

    test('[tag] 子元素存在断言', () {
      final d = parseXmlLoose(
        '<ul><li><span>x</span><a href="/a">A</a></li>'
        '<li><a href="/b">B</a></li></ul>',
      )!;
      expect(evalXPath(d, '//li[span]/a/@href').strings, ['/a']);
    });

    test('相对路径 .// 与 ..（legado jsoupXpath 常用写法）', () {
      final d = parseXmlLoose(
        '<div id="box"><ul><li><a href="/c1">一</a></li>'
        '<li><a href="/c2">二</a></li></ul></div>',
      )!;
      final box = d.rootElement;
      // .// 从当前元素起（含自身后代）
      expect(evalXPath(box, './/a/@href').strings, ['/c1', '/c2']);
      // ./ 单步（子轴，不跨层）
      expect(evalXPath(box, './ul/li/a/@href').strings, ['/c1', '/c2']);
      expect(evalXPath(box, './a').elements, isEmpty);
      // .. 父轴：li → ul → div（带 id）
      final li = evalXPath(box, './/li').elements.first;
      expect(evalXPath(li, '../@id').strings, isEmpty);
      expect(evalXPath(li, '../../@id').strings, ['box']);
    });

    test('复合谓词 and / or / not / starts-with', () {
      final d = parseXmlLoose(
        '<ul>'
        '<li><a href="/c1">第一章</a></li>'
        '<li><a href="javascript:void(0)">JS伪链</a></li>'
        '<li><a href="/c2">第二章</a></li>'
        '</ul>',
      )!;
      expect(
        evalXPath(
          d,
          "//a[contains(@href,'/c') and not(contains(@href,'javascript'))]/@href",
        ).strings,
        ['/c1', '/c2'],
      );
      expect(
        evalXPath(d, "//a[starts-with(@href,'/c1')]/@href").strings,
        ['/c1'],
      );
      expect(
        evalXPath(d, "//a[@href='/c1' or @href='/c2']/@href").strings,
        ['/c1', '/c2'],
      );
    });

    test('不支持的谓词：整条规则失败（宁空勿错，不再保留全部）', () {
      final d = parseXmlLoose(
        '<ul><li><a href="/c1">一</a></li><li><a href="/c2">二</a></li></ul>',
      )!;
      // substring() 未实现 → 返回空而不是把两章都留下
      expect(evalXPath(d, "//a[substring(@href,1,2)='/c']/@href").strings,
          isEmpty);
    });

    test('string() 取路径文本', () {
      final d = parseXmlLoose('<div><p>你好</p></div>')!;
      expect(evalXPath(d, 'string(//p)').strings, ['你好']);
    });

    test('裸 // 规则自动走 XPath（书源主流写法）', () {
      final e = AnalyzeRule(
        '<html><head><meta property="og:novel:book_name" content="书名"/>'
        '</head><body><div>x</div></body></html>',
      );
      expect(
        e.getString('//meta[@property="og:novel:book_name"]/@content'),
        '书名',
      );
    });

    test('P1-2 XPath 列表 + CSS 习惯字段规则：上下文限定在条目内', () {
      // 站点 LOGO 与真实目录并存：若上下文被换成整页，每条的 a@text 都会拿到全页链接
      const src = '<div>站点 LOGO<a href="/">首页</a>'
          '<ul><li><a href="/c/1.html">第一章 开端</a></li>'
          '<li><a href="/c/2.html">第二章 试炼</a></li></ul></div>';
      final eng = AnalyzeRule(src);
      final doc = parseXmlLoose(src)!;
      final items = evalXPath(doc, '//li').elements;
      expect(items.length, 2);
      // a@text / a@href 按 `tag@attr` shim 走，逐条只取自己的链接
      expect(eng.getString('a@text', ctx: items[0]), '第一章 开端');
      expect(eng.getString('a@text', ctx: items[1]), '第二章 试炼');
      expect(eng.getString('a@href', ctx: items[0]), '/c/1.html');
      expect(eng.getString('a@href', ctx: items[1]), '/c/2.html');
      // 复杂选择器（shim 不认）落到片段解析：仍限定在条目内，且条目间不串味
      expect(eng.getString('a', ctx: items[0]), '第一章 开端');
      expect(eng.getString('li a', ctx: items[1]), '第二章 试炼');
      // 提取器关键字（裸 text）保持原样
      expect(eng.getString('text', ctx: items[0]), '第一章 开端');
    });
  });

  group('URL 选项尾与 baseUrl 清理', () {
    test('单引号选项尾解析', () {
      final t = parseUrlTemplate(
        "https://a.com/s, {'method': 'POST', 'body': 'q={{key}}', 'charset': 'gbk'}",
      );
      expect(t.url, 'https://a.com/s');
      expect(t.options['method'], 'POST');
      expect(t.options['body'], 'q={{key}}');
      expect(t.options['charset'], 'gbk');
    });

    test('buildRequest：body 模板按原始值渲染（不百分号编码）', () {
      final t = buildRequest(
        'https://a.com/s,{"method":"POST","body":"keyword={{key}}&p={{page}}"}',
        'https://a.com',
        {'key': '斗破苍穹', 'page': 2},
      );
      expect(t.url, 'https://a.com/s');
      expect(t.options['body'], 'keyword=斗破苍穹&p=2');
    });

    test('未加引号的模板值（JSON5 形态）容忍解析', () {
      final t = buildRequest(
        'https://a.com/s,'
        '{"method":"POST","body":{"keyword":{{key}},"page":{{page}}}}',
        'https://a.com',
        {'key': '斗破苍穹', 'page': 2},
      );
      expect(t.options['method'], 'POST');
      expect(t.options['body'], {'keyword': '斗破苍穹', 'page': '2'});
    });

    test('bookSourceUrl 的 ##分组 尾缀在相对地址解析前清理', () {
      expect(
        RuleAnalyzer.cleanBaseUrl('https://www.qidian.com##分类'),
        'https://www.qidian.com',
      );
      expect(
        resolveUrl('/search?q=1', 'https://www.qidian.com##分类'),
        'https://www.qidian.com/search?q=1',
      );
    });

    test('发现页 {{page}} 渲染（顺序敏感：先模板后单花括号）', () {
      expect(
        OnlineRepo.renderExploreUrl(
          '/nav/xh-qh-{{page}}.html',
          'https://t.com',
          2,
        ),
        'https://t.com/nav/xh-qh-2.html',
      );
      expect(
        OnlineRepo.renderExploreUrl('/list/{page}.shtml', 'https://t.com', 3),
        'https://t.com/list/3.shtml',
      );
    });
  });

  test('replaceRegex 净化（##正则##替换，模板先渲染）', () {
    final e = AnalyzeRule(null, vars: {
      'book': {'name': '《书名》'},
    });
    expect(e.applyReplaceRegex('abc123abc456', '##\\d+##X'), 'abcXabcX');
    expect(e.applyReplaceRegex('ab《书名》cd', '##{{book.name}}##'), 'abcd');
  });

  test('空 base 链（##正则##替换###）：作用于元素 outerHtml（对齐 legado toString）', () {
    final eng = AnalyzeRule(
        '<ul><li><a href="/book2/123456">斗破</a></li></ul>',
        baseUrl: 'http://x/');
    final els = eng.getElements('li');
    expect(els.length, 1);
    final u = eng.getString(
        r'##(?:/book2/|novelid=)(\d+)##http://app-cdn.jjwxc.net/androidapi/novelbasicinfo?novelId=$1###',
        ctx: els.first);
    expect(u, 'http://app-cdn.jjwxc.net/androidapi/novelbasicinfo?novelId=123456');
  });

  test('XPath 元素 ctx：//@href 取元素自身属性（descendant-or-self）', () {
    final eng = AnalyzeRule(
        '<div><span>t</span><a href="https://x/1.htm">c1</a></div>',
        baseUrl: 'http://x/');
    final els = eng.getElements('//a');
    expect(els.length, 1);
    expect(eng.getString(r'//@href', ctx: els.first), 'https://x/1.htm');
  });

  test('isUrl 语义：多匹配只取首个（legado getString0）', () {
    final eng = AnalyzeRule(
        '<div><a href="/a">目录</a><a href="/b">目录</a></div>',
        baseUrl: 'http://x/');
    expect(eng.getString('text.目录@href'), '/a\n/b');
    expect(eng.getString('text.目录@href', isUrl: true), '/a');
  });

  test('init 语义（legado setContent）：JSON 对象成为后续规则与模板的 content', () {
    final e = AnalyzeRule(
        '{"code":0,"data":{"bookId":"803201785","bookName":"斗破苍穹之大世界"}}');
    final init = e.getRawElement(r'$.data');
    expect(init, isA<Map>());
    e.setContentObject(init);
    expect(e.getString(r'$.bookName'), '斗破苍穹之大世界');
    expect(
      e.getString(r'https://x.com/itf/getvolume?bookId={{$.bookId}}'),
      'https://x.com/itf/getvolume?bookId=803201785',
    );
  });

  test('init 语义：data[0] 取数组元素对象', () {
    final e = AnalyzeRule('{"data":[{"id":7,"name":"a"},{"id":8}]}');
    e.setContentObject(e.getRawElement(r'$.data[0]'));
    expect(e.getString(r'$.id'), '7');
  });

  test('CSS/XPath init 不做 content 覆盖（getRawElement 返回 null）', () {
    final e = AnalyzeRule('<div class="book"><h1>书名</h1></div>');
    expect(e.getRawElement('.book'), isNull);
    expect(e.getString('h1@text'), '书名');
  });

  test('Map ctx 裸键直接访问（legado JS 对象键值访问，k/v）', () {
    final e = AnalyzeRule(null);
    final item = {'k': '第一章 序章', 'v': '/c/1/'};
    expect(e.getStrings('k', ctx: item), ['第一章 序章']);
    expect(e.getStrings('v', ctx: item), ['/c/1/']);
    // 缺键 → 空（与 legado result[key] 原样一致）
    expect(e.getStrings('text', ctx: item), isEmpty);
  });

  test('JS 对象列表 + 裸键（SF m 站 +@js: 章节列表）', () {
    final eng = AnalyzeRule('<html></html>',
        baseUrl: 'https://t.com/i/1/', js: JsEnv());
    final rule = TocRule(
      chapterList:
          r'+@js:[{k:"v1|c1",v:"/c/1/"},{k:"v1|c2",v:"/c/2/"}]',
      chapterName: 'k',
      chapterUrl: 'v',
    );
    final chs = OnlineBookService.parseChapters(eng, rule, 'https://t.com/i/1/');
    if (JsBridge.available) {
      expect(chs.length, 2);
      expect(chs.first.title, 'v1|c1');
      expect(chs.first.url, 'https://t.com/c/1/');
    } else {
      // 无 JS 桥：列表规则整体失败 → 0 章（与旧行为一致）
      expect(chs, isEmpty);
    }
  });

  test('JS 段后 {{result}}：result 绑定链上当前结果（legado evalJS(expr, result)）', () {
    final e = AnalyzeRule('{"id":123}');
    final v = e.getString(
        r'''$.id
<js>"A" + result</js>
https://x.com/b/{{result}}''');
    if (JsBridge.available) {
      expect(v, 'https://x.com/b/A123');
    } else {
      // 无 JS 桥：降级只保留文本段结论，{{result}} 无绑定 → 空
      expect(v, 'https://x.com/b/');
    }
  });

  test('java.put 返回写入值；会话变量经 @get 读回（legado put/get 同源）', () {
    if (!JsBridge.available) return;
    final e = AnalyzeRule('{}', js: JsEnv(session: JsSession()));
    expect(e.getString(r'@js:"x=" + java.put("k", "42")'), 'x=42');
    expect(e.getString('https://x.com/b/@get:{k}/c'), 'https://x.com/b/42/c');
  });

  test('header @js: 求值（QQ 浏览器源注入 Referer）', () {
    final src = BookSource(
      bookSourceUrl: 'https://q.qq.com',
      bookSourceName: 'q',
      header: '@js:\nJSON.stringify({"Referer": source.bookSourceUrl})',
    );
    final h = OnlineBookService.headerMap(src);
    if (JsBridge.available) {
      expect(h['Referer'], 'https://q.qq.com');
    } else {
      // 无 JS 桥：静态解析失败 → 空表（旧行为）
      expect(h, isEmpty);
    }
  });

  test('P1-8 header / 发现分类缓存：同源重复求值只算一次', () {
    OnlineBookService.debugClearHeaderCache();
    final src = BookSource(
      bookSourceUrl: 'https://hdr.test',
      bookSourceName: 'h',
      header: '{"Referer":"https://hdr.test/","UA":"x"}',
      exploreUrl: '[{"title":"男生","url":"/boy"},{"title":"女生","url":"/girl"}]',
    );
    final h1 = OnlineBookService.headerMap(src);
    final h2 = OnlineBookService.headerMap(src);
    expect(h1['Referer'], 'https://hdr.test/');
    expect(identical(h1, h2), isTrue); // 命中缓存：同一实例，未重新解析

    OnlineRepo.debugClearCategoryCache();
    final c1 = OnlineRepo.parseExploreCategories(src);
    final c2 = OnlineRepo.parseExploreCategories(src);
    expect(c1.map((e) => e.title).toList(), ['男生', '女生']);
    expect(identical(c1, c2), isTrue);
    // 清缓存后重新解析：内容一致（缓存不改变语义）
    OnlineRepo.debugClearCategoryCache();
    final c3 = OnlineRepo.parseExploreCategories(src);
    expect(c3.map((e) => e.title).toList(), ['男生', '女生']);

    // `@js:` 头同样只求值一次（引擎可用时）
    if (JsBridge.available) {
      OnlineBookService.debugClearHeaderCache();
      final js = BookSource(
        bookSourceUrl: 'https://hdr.test',
        bookSourceName: 'h',
        header: '@js:\nJSON.stringify({"Referer": source.bookSourceUrl})',
      );
      final j1 = OnlineBookService.headerMap(js);
      final j2 = OnlineBookService.headerMap(js);
      expect(j1['Referer'], 'https://hdr.test');
      expect(identical(j1, j2), isTrue);
    }
  });

  test('跨阶段变量袋：搜索 @put:{book:id} → 详情 @get:{book} 读回', () {
    if (!JsBridge.available) return;
    final session = JsSession();
    final e1 = AnalyzeRule('{}', js: JsEnv(session: session));
    // 17k 形态：条目规则内嵌 @put（裸键取 id）——put 只入袋不内嵌 URL
    expect(e1.getString('https://x.com/b/merge@put:{book:id}',
        ctx: {'id': 753943}), 'https://x.com/b/merge');
    expect(session.vars['book'], '753943');
    OnlineBookService.cacheItemVars('http://s/', 'http://s/b/1', session.vars);
    // 详情阶段：另一会话，itemVars 预填后 @get 读回（优先于同名绑定）
    final s2 = JsSession()..vars.addAll(OnlineBookService.itemVars('http://s/', 'http://s/b/1'));
    final e2 = AnalyzeRule('{}',
        js: JsEnv(session: s2), vars: {'book': {'name': 'x'}});
    expect(e2.getString('http://x.com/book/@get:{book}/volumes'),
        'http://x.com/book/753943/volumes');
  });

  test('P1-9 纯转换脚本结果缓存：同码同输入命中，含副作用/时间的不缓存', () {
    if (!JsBridge.available) return;
    JsBridge.debugClearJsCache();
    final env = JsEnv(sourceUrl: 'https://cache.test', baseUrl: 'https://cache.test/');
    const code = r'String(result).replace(/a/g, "b")';
    final first = JsBridge.evalCode(code, env: env, input: 'aaa');
    if (!JsBridge.available) return; // 引擎懒加载失败（测试机缺 DLL）：跳过
    expect(first, 'bbb');
    expect(JsBridge.debugJsCacheSize, 1);
    // 不同输入 → 不同签名 → 新条目，且结果仍正确
    expect(JsBridge.evalCode(code, env: env, input: 'aab'), 'bbb');
    expect(JsBridge.debugJsCacheSize, 2);
    // 同码同输入 → 命中（条数不涨）
    expect(JsBridge.evalCode(code, env: env, input: 'aaa'), 'bbb');
    expect(JsBridge.debugJsCacheSize, 2);
    // 纯 java.* 编解码也可缓存
    expect(JsBridge.evalCode('java.base64Encode(String(result))',
        env: env, input: 'abc'), 'YWJj');
    expect(JsBridge.debugJsCacheSize, 3);
    // 有副作用 / 依赖时间：不进缓存
    JsBridge.debugClearJsCache();
    JsBridge.evalCode('java.put("k", "1"); String(result)', env: env, input: 'x');
    JsBridge.evalCode('String(Date.now())', env: env, input: 'x');
    JsBridge.evalCode('String(Math.random())', env: env, input: 'x');
    expect(JsBridge.debugJsCacheSize, 0);
  });

  test('java-lib 垫层：DES/CBC/PKCS5 对齐 .NET 向量 + String.getBytes + org.jsoup', () {
    if (!JsBridge.available) return;
    // 向量：.NET DESCryptoServiceProvider 生成
    // key=KK!%G3Jd iv=1ae2c94b 明文="Hello 晋江 test 123"
    final out = JsBridge.evalCode(r'''
var dks = new DESKeySpec(String("KK!%G3JdCHJxpAF3%Vg9pN").getBytes());
var sk = SecretKeyFactory.getInstance("DES").generateSecret(dks);
var cipher = Cipher.getInstance("DES/CBC/PKCS5Padding");
var iv = new IvParameterSpec(String("1ae2c94b").getBytes("utf-8"));
cipher.init(Cipher.DECRYPT_MODE, sk, iv);
var plain = new String(cipher.doFinal(Base64.getDecoder().decode(
    "kvm9bG5u3/j3UJq8U+VfvCdoWT8C7MjD".getBytes())), "utf-8");
java.base64Encode(plain) + '|' + (typeof org.jsoup.Jsoup.connect);
''');
    final expectB64 = base64Encode(utf8.encode('Hello 晋江 test 123'));
    expect(out, '$expectB64|function');
    // String 扩展不破坏常规用法
    final s = JsBridge.evalCode('[String(123), new String("a") + "b", String.fromCharCode(66)]');
    expect('$s'.contains('123'), true);
  });
}
