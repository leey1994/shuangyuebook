import '../dom.dart';
import '../models.dart';
import 'shuku_cms.dart';

/// 全本小说网 quanben.io（同款 CMS）
///
/// - 搜索：覆写 GET `/index.php?c=book&a=search&keywords=`；
/// - 卡片：`div.list2`（itemprop 语义化标签），空时退 `p.links` 文字链；
/// - 详情：toc =「章节列表」→ `/n/<slug>/list.html`，h1/作者/状态 toc 页优先；
///   章 = `^/n/<slug>/<n>.html$` DOM 序；
/// - 排行：18 分榜 `/c/<name>.html`，分页根 = 路径剥 `(_\d+)?\.html$`；
/// - 正文：base64 写入型 + 章内茎护栏（继承基类）。
class QuanbenSource extends ShukuCmsSource {
  @override
  String get id => 'quanben';
  @override
  String get name => '全本小说网';
  @override
  String get baseUrl => 'https://quanben.io';

  static final _bookRe = RegExp(r'^/n/[a-z0-9_]+/$');
  static final _tocRe = RegExp(r'^/n/[a-z0-9_]+/list(_\d+)?\.html$');
  static final _chapPageRe = RegExp(r'/\d+\.html$'); // 纯数字章链（目录翻页要拒）
  static final _authorRe =
      RegExp(r'作者\s*[:：]\s*(\S{1,15}?)(?=$|\s|状态|分类|更新)');
  static final _statusRe =
      RegExp(r'状态\s*[:：]\s*(\S{1,15}?)(?=$|\s|状态|分类|更新)');

  @override
  Future<List<Book>> search(String query) async {
    final doc = await fetchDoc(
        '$baseUrl/index.php?c=book&a=search&keywords=${Uri.encodeQueryComponent(query)}');
    return parseCards(doc, '$baseUrl/');
  }

  @override
  List<Book> parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};

    void add(String href, String title,
        {String? author, String? intro, String? cover}) {
      if (!_bookRe.hasMatch(href) || title.isEmpty) return;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) return;
      final slug = href.split('/').where((s) => s.isNotEmpty).last;
      out.add(Book(
        sourceId: id,
        id: slug,
        url: url,
        title: title,
        author: author,
        intro: intro,
        cover: cover,
      ));
    }

    // 形态一：div.list2（itemprop 语义化）
    for (final item in doc.querySelectorAll('div.list2')) {
      Element? a;
      for (final x in item.querySelectorAll('a[href]')) {
        if (_bookRe.hasMatch(x.attributes['href'] ?? '')) {
          a = x;
          break;
        }
      }
      if (a == null) continue;
      var title = textOf(item.querySelector('span[itemprop="name"]'));
      if (title.isEmpty) title = cleanText(a.attributes['title'] ?? textOf(a));
      var au = textOf(item.querySelector('span[itemprop="author"]'));
      if (au.isNotEmpty) {
        au = au.replaceFirst(RegExp(r'^\s*作者\s*[:：]?\s*'), '').trim();
      }
      final intro = textOf(item.querySelector('p[itemprop="description"]'));
      final img = item.querySelector('img');
      final src = img?.attributes['src'];
      add(
        a.attributes['href'] ?? '',
        title,
        author: au.isEmpty ? null : au,
        intro: intro.isEmpty ? null : intro,
        cover: (src == null || src.isEmpty) ? null : absUrl(pageUrl, src),
      );
    }

    // 形态二兜底：p.links 文字链
    if (out.isEmpty) {
      for (final a in doc.querySelectorAll('p.links a[href]')) {
        add(a.attributes['href'] ?? '', textOf(a));
      }
    }
    return out;
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '玄幻', url: '/c/xuanhuan.html'),
        RankTab(title: '都市', url: '/c/dushi.html'),
        RankTab(title: '言情', url: '/c/yanqing.html'),
        RankTab(title: '穿越', url: '/c/chuanyue.html'),
        RankTab(title: '青春', url: '/c/qingchun.html'),
        RankTab(title: '仙侠', url: '/c/xianxia.html'),
        RankTab(title: '灵异', url: '/c/lingyi.html'),
        RankTab(title: '悬疑', url: '/c/xuanyi.html'),
        RankTab(title: '历史', url: '/c/lishi.html'),
        RankTab(title: '军事', url: '/c/junshi.html'),
        RankTab(title: '游戏', url: '/c/youxi.html'),
        RankTab(title: '竞技', url: '/c/jingji.html'),
        RankTab(title: '科幻', url: '/c/kehuan.html'),
        RankTab(title: '职场', url: '/c/zhichang.html'),
        RankTab(title: '官场', url: '/c/guanchang.html'),
        RankTab(title: '现言', url: '/c/xianyan.html'),
        RankTab(title: '耽美', url: '/c/danmei.html'),
        RankTab(title: '其它', url: '/c/qita.html'),
      ];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final url = nextUrl ?? '$baseUrl${tab.url}';
    final doc = await fetchDoc(url);
    // 分页根：/c/xuanhuan_2.html 的根是 /c/xuanhuan
    final root = Uri.parse('$baseUrl${tab.url}')
        .path
        .replaceFirst(RegExp(r'(_\d+)?\.html$'), '');
    return Paged(
        items: parseCards(doc, url),
        nextUrl: ShukuCmsSource.listNext(doc, url, root));
  }

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final segs = book.url.split('/').where((s) => s.isNotEmpty).toList();
    final slug = segs.isNotEmpty ? segs.last : book.id;
    final chapRe = RegExp('^/n/$slug/(\\d+)\\.html\$');

    if (nextUrl != null) {
      final doc = await fetchDoc(nextUrl, referer: book.url);
      return BookDetail(
        book: book,
        chapters: _chapters(doc, chapRe, nextUrl),
        nextChaptersUrl: _tocNext(doc, nextUrl, slug),
      );
    }

    final doc = await fetchDoc(book.url);
    // 目录：「章节列表」→ /n/<slug>/list.html
    var tocHref = findLinkByText(doc, '章节列表');
    tocHref ??= findLinkByText(doc, '章节列表', contains: true);
    Document tocDoc = doc;
    String tocUrl = book.url;
    if (tocHref != null) {
      final u = absUrl(book.url, tocHref);
      final p = Uri.parse(u).path;
      if (_tocRe.hasMatch(p) && p.startsWith('/n/$slug/')) {
        tocDoc = await fetchDoc(u, referer: book.url);
        tocUrl = u;
      }
    }
    // h1/作者/状态：toc 页优先，root 兜底
    String h1 = textOf(tocDoc.querySelector('h1'));
    if (h1.isEmpty) h1 = textOf(doc.querySelector('h1'));
    var author = _authorRe.firstMatch(textOf(tocDoc.body))?.group(1) ??
        _authorRe.firstMatch(textOf(doc.body))?.group(1) ??
        book.author;
    var status = _statusRe.firstMatch(textOf(tocDoc.body))?.group(1) ??
        _statusRe.firstMatch(textOf(doc.body))?.group(1) ??
        book.status;
    String? cover = book.cover;
    if (cover == null) {
      final img = tocDoc.querySelector('img[itemprop="image"]') ??
          doc.querySelector('img[itemprop="image"]');
      final src = img?.attributes['src'];
      if (src != null && src.isNotEmpty) cover = absUrl(book.url, src);
    }
    cover ??= metaContent(tocDoc, 'og:image') ?? metaContent(doc, 'og:image');
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: h1.isEmpty ? book.title : h1,
        author: author,
        cover: cover,
        intro: book.intro,
        status: status,
        latest: book.latest,
      ),
      chapters: _chapters(tocDoc, chapRe, tocUrl),
      nextChaptersUrl: _tocNext(tocDoc, tocUrl, slug),
    );
  }

  /// `/n/<slug>/<n>.html` 章链接（list.html 自然排除），DOM 序去重。
  List<Chapter> _chapters(Document doc, RegExp chapRe, String pageUrl) {
    final out = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!chapRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      out.add(Chapter(title: t, url: url));
    }
    return out;
  }

  /// 目录翻页：listNext + 拒纯数字章链（「下一页」误指章页时护栏）。
  String? _tocNext(Document doc, String currentUrl, String slug) {
    final next = ShukuCmsSource.listNext(doc, currentUrl, '/n/$slug/');
    if (next == null) return null;
    if (_chapPageRe.hasMatch(Uri.parse(next).path)) return null;
    return next;
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final b64 = parasFromB64Writes(doc.documentElement?.innerHtml ?? '');
    if (b64.isNotEmpty) return b64;
    return parasInContainer(doc.querySelector('#content, .main, .content'));
  }
}
