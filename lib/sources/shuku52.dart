import '../dom.dart';
import '../models.dart';
import 'source.dart';

/// 52书库 www.52shuku.net
///
/// 列表（首页/搜索/排行）统一为 `article.excerpt` 卡片；
/// 书单中心 `/tuijian/`；排行中心 `/Top/`。
/// 书名格式 `书名_作者【完结】`，按第一个 `_` 拆分。
class Shuku52Source extends NovelSource {
  @override
  String get id => 'shuku52';
  @override
  String get name => '52书库';
  @override
  String get baseUrl => 'https://www.52shuku.net';

  static bool _isBookHref(String href) {
    if (href.isEmpty || href.startsWith('javascript')) return false;
    if (href.contains('/tuijian/') || href.contains('/Top/')) return false;
    if (href.contains('/so/') || href.contains('search')) return false;
    if (href.contains('/Tags/')) return false; // 标签页不是书（进去是空章）
    // 书籍页：/book/11407/ 或 /gl/02_b/bkcBD.html 等
    return href.contains('/book/') || RegExp(r'/\w+_\w+/').hasMatch(href) ||
        RegExp(r'/(bl|gl|yanqing|nan|xiandaidushi|chongsheng|jiakong)/\S+\.html')
            .hasMatch(href) ||
        RegExp(r'/(bl|gl|yanqing|nan)/\d+_\w+/').hasMatch(href);
  }

  // ---------- 列表解析（首页 / 搜索 / 排行共用） ----------

  static List<Book> parseExcerptList(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final art in doc.querySelectorAll('article.excerpt, article')) {
      // 找卡片正文里的书籍链接：文字含 "_"（书名_作者）
      Element? link;
      for (final a in art.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        if (!_isBookHref(href)) continue;
        final t = cleanText(a.text);
        if (t.isEmpty) continue;
        link = a;
        break;
      }
      if (link == null) continue;
      final url = absUrl(pageUrl, link.attributes['href']);
      if (!seen.add(url)) continue;
      final parsed = splitTitleAuthor(cleanText(link.text));
      // 简介：卡片内的 p（去掉标题行）
      String? intro;
      for (final p in art.querySelectorAll('p')) {
        final t = textOf(p);
        if (t.isNotEmpty && !t.contains('_')) {
          intro = t;
          break;
        }
      }
      out.add(Book(
        sourceId: 'shuku52',
        id: url,
        url: url,
        title: parsed.title,
        author: parsed.author,
        intro: intro,
        cover: () {
          final img = art.querySelector('img');
          if (img == null) return null;
          final src = img.attributes['src'] ?? img.attributes['data-src'];
          return src == null || src.isEmpty ? null : absUrl(pageUrl, src);
        }(),
      ));
    }
    // 首页无 excerpt 卡片：书链在 div.relates 列表（书名_作者 文本链）
    if (out.isEmpty) {
      for (final a in doc.querySelectorAll('div.relates a[href]')) {
        final href = a.attributes['href'] ?? '';
        if (!_isBookHref(href)) continue;
        final t = cleanText(a.text);
        if (!t.contains('_')) continue;
        final url = absUrl(pageUrl, href);
        if (!seen.add(url)) continue;
        final parsed = splitTitleAuthor(t);
        out.add(Book(
          sourceId: 'shuku52',
          id: url,
          url: url,
          title: parsed.title,
          author: parsed.author,
        ));
      }
    }
    return out;
  }

  // ---------- 首页 ----------

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return parseExcerptList(doc, baseUrl);
  }

  // ---------- 排行 ----------

  @override
  Future<List<RankTab>> fetchRankTabs() async {
    final doc = await fetchDoc('$baseUrl/Top/');
    final seen = <String>{};
    final tabs = <RankTab>[];
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      final isTop = href.contains('/Top/');
      final isYearTop = href.contains('/tuijian/') && href.contains('op100');
      if (!isTop && !isYearTop) continue;
      final url = absUrl(baseUrl, href);
      if (!seen.add(url)) continue;
      var title = a.attributes['title'] ?? cleanText(a.text);
      title = title.replaceFirst(RegExp(r'小说排行榜$'), '');
      title = title.replaceFirst(RegExp(r'点赞\[?\(?(月榜|年榜)\)?\]?$'), r'$1');
      if (title.trim().isEmpty) continue;
      tabs.add(RankTab(title: title.trim(), url: url));
      if (tabs.length >= 60) break;
    }
    return tabs;
  }

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final url = nextUrl ?? tab.url;
    final doc = await fetchDoc(url);
    return Paged(
      items: parseExcerptList(doc, url),
      nextUrl: nextPageUrl(doc, url),
    );
  }

  // ---------- 书单 ----------

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async {
    final url = nextUrl ?? '$baseUrl/tuijian/';
    final doc = await fetchDoc(url);
    final out = <BooklistEntry>[];
    final seen = <String>{};
    for (final art in doc.querySelectorAll('article')) {
      final a = art.querySelector('header h2 a, h2 a, h3 a');
      if (a == null) continue;
      final u = absUrl(url, a.attributes['href']);
      if (!u.contains('/tuijian/') || !seen.add(u)) continue;
      String? intro;
      final span = art.querySelector('span');
      if (span != null) intro = textOf(span);
      String? date;
      final d = art.querySelector('p span, p');
      if (d != null) {
        final m = RegExp(r'\(([\d-]+)\)').firstMatch(textOf(d));
        date = m?.group(1);
      }
      out.add(BooklistEntry(
        title: cleanText(a.text),
        url: u,
        intro: intro,
        date: date,
      ));
    }
    return Paged(items: out, nextUrl: nextPageUrl(doc, url));
  }

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async {
    final doc = await fetchDoc(entry.url);
    final title = textOf(doc.querySelector('h1')).isNotEmpty
        ? textOf(doc.querySelector('h1'))
        : (textOf(doc.querySelector('h2 a')).isNotEmpty
            ? textOf(doc.querySelector('h2 a'))
            : entry.title);
    final paras = <String>[];
    final books = <Book>[];
    final seen = <String>{};
    final root = doc.querySelector('article, .content, body');
    for (final p in root?.querySelectorAll('p') ?? <Element>[]) {
      final t = textOf(p);
      if (t.isNotEmpty) paras.add(t);
    }
    for (final a in root?.querySelectorAll('a[href]') ?? <Element>[]) {
      final href = a.attributes['href'] ?? '';
      if (!_isBookHref(href)) continue;
      final t = cleanText(a.text);
      if (t.isEmpty) continue;
      final u = absUrl(entry.url, href);
      if (!seen.add(u)) continue;
      final parsed = splitTitleAuthor(t);
      books.add(Book(
        sourceId: id,
        id: u,
        url: u,
        title: parsed.title,
        author: parsed.author,
      ));
    }
    return Booklist(title: title, paragraphs: paras, books: books);
  }

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String query) async {
    final doc =
        await fetchDoc('$baseUrl/so/search.php?q=${Uri.encodeQueryComponent(query)}');
    return parseExcerptList(doc, '$baseUrl/so/search.php');
  }

  // ---------- 详情 ----------

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final url = nextUrl ?? book.url;
    final doc = await fetchDoc(url, referer: book.url);

    var title = textOf(doc.querySelector('.article-title, h1'));
    var author = book.author;
    if (title.contains('_')) {
      final parsed = splitTitleAuthor(title);
      if (parsed.author != null) {
        title = parsed.title;
        author = parsed.author;
      }
    }
    if (title.isEmpty) title = book.title;

    String? intro = book.intro;
    final content = doc.querySelector('.article-content, #content, .content');
    if (intro == null || intro.isEmpty) {
      final p = content?.querySelector('p');
      intro = p == null ? null : textOf(p);
    }

    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('ul.list li.mulu a, ul li.mulu a')) {
      final href = a.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final cu = absUrl(url, href);
      if (!seen.add(cu)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      chapters.add(Chapter(title: t, url: cu));
    }
    // 兜底：任意书内页链接
    if (chapters.isEmpty) {
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        if (!href.contains('.html')) continue;
        final u = absUrl(url, href);
        if (u == url || !u.contains(book.url.replaceAll(baseUrl, ''))) continue;
        if (seen.add(u)) {
          final t = textOf(a);
          if (t.isNotEmpty) chapters.add(Chapter(title: t, url: u));
        }
      }
    }

    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title,
        author: author,
        cover: book.cover,
        intro: intro,
        status: book.status,
        latest: book.latest,
      ),
      chapters: chapters,
      nextChaptersUrl: nextPageUrl(doc, url),
    );
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) =>
      parasFrom(doc, 'article.article-content p, div#text p, #text p');

  /// 本站「下一页」就是目录里的下一章（每“页”即一章），跟随会把后面几十章
  /// 拼进当前章（实测一次抓 18 万字）——禁止跟随，一章 = 一页。
  @override
  bool allowFollow(String currentUrl, String nextUrl) => false;
}
