import '../dom.dart';
import '../models.dart';
import 'shuku_cms.dart';

/// 素书卷 www.sushujuan.cc（同款 CMS）
///
/// - 搜索：继承基类 POST /search.html；
/// - 卡片：`article.qy-bcard` ∪ `li.qy-podium__item` ∪ 裸 `a.qy-cover`，按 url 补空；
/// - 详情：h1 书名 + `<title>` 提作者；目录 = 「章节目录」→ `/book/<id>/1.html`；
/// - 排行：9 分榜 `/sort/<n>/1.html`，分页根前缀 + 页码递增；
/// - 正文：base64 写入 `.qy-shell` + 章内茎护栏。
class SushujuanSource extends ShukuCmsSource {
  @override
  String get id => 'sushujuan';
  @override
  String get name => '素书卷';
  @override
  String get baseUrl => 'https://www.sushujuan.cc';

  static final _bookRe = RegExp(r'^/book/\d+\.html$');
  static final _chapRe = RegExp(r'^/read/\d+/\d+\.html$');
  static final _tocPageRe = RegExp(r'^/book/\d+/\d+\.html$');

  @override
  List<Book> parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final idx = <String, int>{};

    void add(Book b) {
      final i = idx[b.url];
      if (i == null) {
        idx[b.url] = out.length;
        out.add(b);
        return;
      }
      final o = out[i];
      out[i] = Book(
        sourceId: o.sourceId, id: o.id, url: o.url,
        title: o.title.isNotEmpty ? o.title : b.title,
        author: o.author ?? b.author,
        cover: o.cover ?? b.cover,
        intro: o.intro ?? b.intro,
        status: o.status ?? b.status,
        latest: o.latest ?? b.latest,
      );
    }

    String idOf(String url) =>
        url.split('/').last.replaceAll(RegExp(r'\.html?$'), '');
    String strip(String s) => s.replaceAll(RegExp(r'[《》]'), '').trim();

    // 形态一：article.qy-bcard（标题 + 作者 + 简介）
    for (final card in doc.querySelectorAll('article.qy-bcard')) {
      Element? a;
      for (final x in card.querySelectorAll('a[href]')) {
        if (_bookRe.hasMatch(x.attributes['href'] ?? '')) { a = x; break; }
      }
      if (a == null) continue;
      final url = absUrl(pageUrl, a.attributes['href']);
      var title = textOf(card.querySelector('.qy-bcard__title'));
      if (title.isEmpty) title = strip(a.attributes['title'] ?? '');
      if (title.isEmpty) continue;
      final au = textOf(card.querySelector('.qy-bcard__meta a'));
      final desc = textOf(card.querySelector('.qy-bcard__desc'));
      final img = a.querySelector('img');
      final src = img?.attributes['src'];
      add(Book(
        sourceId: id, id: idOf(url), url: url, title: title,
        author: au.isEmpty ? null : au,
        cover: (src == null || src.isEmpty)
            ? '$baseUrl/img/${idOf(url)}.jpg'
            : absUrl(pageUrl, src),
        intro: desc.isEmpty ? null : desc,
      ));
    }

    // 形态二：li.qy-podium__item（书名 + 作者）
    for (final li in doc.querySelectorAll('li.qy-podium__item')) {
      Element? a;
      for (final x in li.querySelectorAll('a[href]')) {
        if (_bookRe.hasMatch(x.attributes['href'] ?? '')) { a = x; break; }
      }
      if (a == null) continue;
      final url = absUrl(pageUrl, a.attributes['href']);
      var title = strip(textOf(a));
      if (title.isEmpty) title = strip(a.attributes['title'] ?? '');
      if (title.isEmpty) continue;
      final au = textOf(li.querySelector('p.qy-podium__au a'));
      add(Book(
        sourceId: id, id: idOf(url), url: url, title: title,
        author: au.isEmpty ? null : au,
        cover: '$baseUrl/img/${idOf(url)}.jpg',
      ));
    }

    // 形态三：裸 a.qy-cover（首页书库滑条，title 属性带《》，后缀即作者）
    for (final a in doc.querySelectorAll('a.qy-cover[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_bookRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      final title = strip(a.attributes['title'] ?? '');
      if (title.isEmpty) continue;
      String? author;
      final t = textOf(a);
      final i = t.indexOf(title);
      if (i >= 0 && i + title.length < t.length) {
        final suf = t.substring(i + title.length).replaceAll(RegExp(r'[《》\s]'), '');
        if (suf.isNotEmpty) author = suf;
      }
      final img = a.querySelector('img');
      final src = img?.attributes['src'];
      add(Book(
        sourceId: id, id: idOf(url), url: url, title: title, author: author,
        cover: (src == null || src.isEmpty)
            ? '$baseUrl/img/${idOf(url)}.jpg'
            : absUrl(pageUrl, src),
      ));
    }
    return out;
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '玄幻', url: '/sort/1/1.html'),
        RankTab(title: '仙侠', url: '/sort/2/1.html'),
        RankTab(title: '都市', url: '/sort/3/1.html'),
        RankTab(title: '历史', url: '/sort/4/1.html'),
        RankTab(title: '网游', url: '/sort/5/1.html'),
        RankTab(title: '科幻', url: '/sort/6/1.html'),
        RankTab(title: '灵异', url: '/sort/7/1.html'),
        RankTab(title: '女频', url: '/sort/8/1.html'),
        RankTab(title: '其他', url: '/sort/9/1.html'),
      ];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final url = nextUrl ?? '$baseUrl${tab.url}';
    final doc = await fetchDoc(url);
    final root = ShukuCmsSource.dirOf('$baseUrl${tab.url}');
    return Paged(
        items: parseCards(doc, url),
        nextUrl: ShukuCmsSource.listNext(doc, url, root));
  }

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    if (nextUrl != null) {
      final doc = await fetchDoc(nextUrl, referer: book.url);
      return BookDetail(
          book: book,
          chapters: _chapters(doc, nextUrl),
          nextChaptersUrl: _tocNext(doc, nextUrl));
    }
    final doc = await fetchDoc(book.url);
    final h1 = textOf(doc.querySelector('h1'));
    // 作者：<title> split('_')[1] 减 h1、减「最新章节」，取 ' - ' 前段、减站名
    var author = book.author;
    final tt = doc.querySelector('title')?.text ?? '';
    final parts = tt.split('_');
    if (parts.length > 1) {
      var s = parts[1];
      if (h1.isNotEmpty) s = s.replaceFirst(h1, '');
      s = s.replaceFirst('最新章节', '');
      s = s.split(' - ').first.replaceAll('素书卷', '').trim();
      if (s.isNotEmpty) author = s;
    }
    final nb = Book(
      sourceId: book.sourceId, id: book.id, url: book.url,
      title: h1.isEmpty ? book.title : h1,
      author: author,
      cover: book.cover ?? '$baseUrl/img/${book.id}.jpg',
      intro: book.intro, status: book.status, latest: book.latest,
    );
    // 目录：「章节目录」→ /book/<id>/1.html
    var tocHref = findLinkByText(doc, '章节目录');
    tocHref ??= findLinkByText(doc, '查看完整章节目录', contains: true);
    if (tocHref != null) {
      final tocUrl = absUrl(book.url, tocHref);
      if (_tocPageRe.hasMatch(Uri.parse(tocUrl).path)) {
        final tdoc = await fetchDoc(tocUrl, referer: book.url);
        final chs = _chapters(tdoc, tocUrl);
        if (chs.isNotEmpty) {
          return BookDetail(
              book: nb, chapters: chs, nextChaptersUrl: _tocNext(tdoc, tocUrl));
        }
      }
    }
    return BookDetail(book: nb, chapters: _chapters(doc, book.url), nextChaptersUrl: null);
  }

  /// `/read/<id>/<n>.html` 章链接，DOM 序去重。
  List<Chapter> _chapters(Document doc, String pageUrl) {
    final out = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_chapRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      out.add(Chapter(title: t, url: url));
    }
    return out;
  }

  /// 目录翻页：含「下一页」+ `/book/<id>/<n>.html` 前缀 + 页码递增（末页回 /book/<id>.html 拒）。
  String? _tocNext(Document doc, String currentUrl) {
    final next = nextPageUrl(doc, currentUrl, contains: true);
    if (next == null) return null;
    if (!_tocPageRe.hasMatch(Uri.parse(next).path)) return null;
    final cp = ShukuCmsSource.pageOf(currentUrl);
    final np = ShukuCmsSource.pageOf(next);
    if (cp != null && np != null && np <= cp) return null;
    return next;
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final b64 = parasFromB64Writes(doc.documentElement?.innerHtml ?? '');
    if (b64.isNotEmpty) return b64;
    return parasInContainer(doc.querySelector('.qy-shell'));
  }
}
