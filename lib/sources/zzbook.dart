import '../dom.dart';
import '../models.dart';
import 'shuku_cms.dart';

/// 智能书库 www.zzbook.net（同款 CMS）
///
/// - 搜索：继承基类 POST /search.html；
/// - 卡片：`div.item`（title 属性 + 简介）∪ `#newscontent li`（书名 + 作者），按 url 补空；
/// - 详情：h1 书名 + `作者：xxx` 正则；目录 = 「章节目录」→ `/go/<cat>/<id>/1/`；
/// - 排行：9 分榜 `/list/<n>/1/`，分页根 `/list/` + 页码递增；
/// - 正文：base64 写入型 + 章内茎护栏（继承基类）。
class ZzbookSource extends ShukuCmsSource {
  @override
  String get id => 'zzbook';
  @override
  String get name => '智能书库';
  @override
  String get baseUrl => 'https://www.zzbook.net';

  static final _bookRe = RegExp(r'^/go/\d+/\d+/?$');
  static final _chapRe = RegExp(r'^/go/\d+/\d+/\d+\.html$');
  static final _tocPageRe = RegExp(r'^/go/\d+/\d+/\d+/?$');
  static final _authorRe = RegExp(r'作者\s*[：:]\s*(\S{1,15}?)(?=$|\s|状态|分类|更新)');

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

    // 形态一：div.item（title 属性 + dd 简介，无作者）
    for (final item in doc.querySelectorAll('div.item')) {
      Element? a;
      for (final x in item.querySelectorAll('a[href]')) {
        if (_bookRe.hasMatch(x.attributes['href'] ?? '')) { a = x; break; }
      }
      if (a == null) continue;
      final url = absUrl(pageUrl, a.attributes['href']);
      final title = cleanText(
          item.attributes['title'] ?? a.attributes['title'] ?? '');
      if (title.isEmpty) continue;
      final img = item.querySelector('img');
      final dd = textOf(item.querySelector('dd'));
      String? cover;
      final src = img?.attributes['data-original'] ?? img?.attributes['src'];
      if (src != null && src.isNotEmpty) cover = absUrl(pageUrl, src);
      add(Book(
        sourceId: id,
        id: url.split('/').where((s) => s.isNotEmpty).last,
        url: url,
        title: title,
        cover: cover ?? _coverOf(url),
        intro: (dd.isEmpty || dd == '......' || dd.length <= 20) ? null : dd,
      ));
    }

    // 形态二：#newscontent li（s2 书名 + s5 作者）
    for (final li in doc.querySelectorAll('#newscontent li')) {
      Element? a;
      for (final x in li.querySelectorAll('a[href]')) {
        if (_bookRe.hasMatch(x.attributes['href'] ?? '')) { a = x; break; }
      }
      if (a == null) continue;
      final url = absUrl(pageUrl, a.attributes['href']);
      final title = cleanText(a.attributes['title'] ?? textOf(a));
      if (title.isEmpty) continue;
      final au = textOf(li.querySelector('span.s5'));
      add(Book(
        sourceId: id,
        id: url.split('/').where((s) => s.isNotEmpty).last,
        url: url,
        title: title,
        author: au.isEmpty ? null : au,
        cover: _coverOf(url),
      ));
    }
    return out;
  }

  /// `/go/<cat>/<id>/` → `/img/<id>.jpg`
  String _coverOf(String url) {
    final segs = url.split('/').where((s) => s.isNotEmpty).toList();
    return '$baseUrl/img/${segs.isNotEmpty ? segs.last : ''}.jpg';
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '玄幻', url: '/list/1/1/'),
        RankTab(title: '重生', url: '/list/2/1/'),
        RankTab(title: '都市', url: '/list/3/1/'),
        RankTab(title: '军史', url: '/list/4/1/'),
        RankTab(title: '网游', url: '/list/5/1/'),
        RankTab(title: '科幻', url: '/list/6/1/'),
        RankTab(title: '灵异', url: '/list/7/1/'),
        RankTab(title: '言情', url: '/list/8/1/'),
        RankTab(title: '其他', url: '/list/9/1/'),
      ];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final url = nextUrl ?? '$baseUrl${tab.url}';
    final doc = await fetchDoc(url);
    return Paged(
        items: parseCards(doc, url),
        nextUrl: ShukuCmsSource.listNext(doc, url, '/list/'));
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
    final title = textOf(doc.querySelector('h1'));
    final am = _authorRe.firstMatch(textOf(doc.body));
    // 目录：「章节目录」→ /go/<cat>/<id>/1/
    var tocHref = findLinkByText(doc, '章节目录');
    tocHref ??= findLinkByText(doc, '章节目录', contains: true);
    if (tocHref != null) {
      final tocUrl = absUrl(book.url, tocHref);
      if (_tocPageRe.hasMatch(Uri.parse(tocUrl).path)) {
        final tdoc = await fetchDoc(tocUrl, referer: book.url);
        final chs = _chapters(tdoc, tocUrl);
        if (chs.isNotEmpty) {
          return BookDetail(
            book: _enrich(book, title, am?.group(1)),
            chapters: chs,
            nextChaptersUrl: _tocNext(tdoc, tocUrl),
          );
        }
      }
    }
    return BookDetail(
      book: _enrich(book, title, am?.group(1)),
      chapters: _chapters(doc, book.url),
      nextChaptersUrl: null,
    );
  }

  Book _enrich(Book b, String title, String? author) => Book(
        sourceId: b.sourceId, id: b.id, url: b.url,
        title: title.isEmpty ? b.title : title,
        author: author ?? b.author,
        cover: b.cover ?? _coverOf(b.url),
        intro: b.intro, status: b.status, latest: b.latest,
      );

  /// `/go/<cat>/<id>/<n>.html` 章链接，DOM 序去重。
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

  /// 目录翻页护栏：`/go/<cat>/<id>/<n>/` 且 ≠ 当前页（`.html`/回根拒）。
  String? _tocNext(Document doc, String currentUrl) {
    final next = nextPageUrl(doc, currentUrl, contains: true);
    if (next == null || next == currentUrl) return null;
    if (!_tocPageRe.hasMatch(Uri.parse(next).path)) return null;
    return next;
  }
}
