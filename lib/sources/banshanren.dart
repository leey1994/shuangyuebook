import '../dom.dart';
import '../models.dart';
import 'source.dart';

/// 搬山人小说网 www.banshanren.com
///
/// - 搜索：GET `/search/index?keyword=`；
/// - 卡片：`li.novel_li`（首页/榜单/搜索通用）；
/// - 详情：`<title>《书名》作者_分类…` → 作者从 title 提；
/// - 正文：`div.chapter_box`，无章内分页（下一章 → 另一章）。
class BanshanrenSource extends NovelSource {
  @override
  String get id => 'banshanren';
  @override
  String get name => '搬山人';
  @override
  String get baseUrl => 'https://www.banshanren.com';

  static final _bookRe = RegExp(r'^/novel/[a-z0-9_]+$');
  static final _chapRe = RegExp(r'^/novel/[a-z0-9_]+/\d+$');

  /// 卡片：li.novel_li（缺容器时退化为链接形状扫描）。
  List<Book> _parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final li in doc.querySelectorAll('li.novel_li')) {
      final a = li.querySelector('a[href]');
      if (a == null) continue;
      final href = a.attributes['href'] ?? '';
      if (!_bookRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final img = li.querySelector('img');      // 卡片文本形如「书名 76% 连载中 简介…」：首链接取书名，其后为状态/简介
      final title = cleanText(a.attributes['title'] ?? a.text);
      if (title.isEmpty) continue;
      final texts = li.text.split('\n').map(cleanText).where((t) => t.isNotEmpty);
      String? intro;
      String? status;
      for (final t in texts) {
        if (t == title) continue;
        if (t.contains('连载') || t.contains('完结')) {
          status = t;
        } else if (t.length > 12) {
          intro = t;
        }
      }
      final m = RegExp(r'([0-9.]+)%').firstMatch(li.text);
      out.add(Book(
        sourceId: id,
        id: url.split('/').last,
        url: url,
        title: title,
        author: null,
        cover: img == null
            ? null
            : absUrl(pageUrl, img.attributes['src'] ?? img.attributes['data-src']),
        intro: intro ?? (m != null ? null : cleanText(li.text)),
        status: status ?? (m != null ? '${m.group(1)}%' : null),
      ));
    }
    if (out.isNotEmpty) return out;
    // 兜底：形状扫描
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_bookRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final title = cleanText(a.attributes['title'] ?? a.text);
      if (title.isEmpty) continue;
      out.add(Book(sourceId: id, id: href.split('/').last, url: url, title: title));
    }
    return out;
  }

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return _parseCards(doc, '$baseUrl/');
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '排行榜', url: '/rank'),
        RankTab(title: '全部小说', url: '/all/0-0-0-0-0-0-1-1/'),
        RankTab(title: '奇幻玄幻', url: '/all/0-4-0-0-0-0-1-1/'),
        RankTab(title: '现代都市', url: '/all/0-3-0-0-0-0-1-1/'),
        RankTab(title: '穿越重生', url: '/all/0-7-0-0-0-0-1-1/'),
        RankTab(title: '武侠仙侠', url: '/all/0-8-0-0-0-0-1-1/'),
      ];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final doc = await fetchDoc(nextUrl ?? '$baseUrl${tab.url}');
    final items = _parseCards(doc, nextUrl ?? '$baseUrl${tab.url}');
    return Paged(items: items, nextUrl: null);
  }

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  @override
  Future<List<Book>> search(String query) async {
    final doc =
        await fetchDoc('$baseUrl/search/index?keyword=${Uri.encodeQueryComponent(query)}');
    return _parseCards(doc, baseUrl);
  }

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final doc = await fetchDoc(nextUrl ?? book.url);
    final title = textOf(doc.querySelector('h1'));
    // <title>《书名》作者_分类小说免费阅读》——作者夹在 》_ 之间
    final t = doc.querySelector('title')?.text ?? '';
    final am = RegExp(r'》([^》_]+)_').firstMatch(t);
    final author = am?.group(1)?.trim();
    String? cover;
    for (final img in doc.querySelectorAll('img')) {
      final s = img.attributes['src'] ?? img.attributes['data-src'] ?? '';
      if (s.contains('/file/') && !s.contains('logo') && !s.contains('static')) {
        cover = absUrl(book.url, s);
        break;
      }
    }
    // 目录：/novel/<slug>/<数字章id>
    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_chapRe.hasMatch(href)) continue;
      final url = absUrl(book.url, href);
      if (!seen.add(url)) continue;
      final name = cleanText(a.text);
      if (name.isEmpty) continue;
      chapters.add(Chapter(title: name, url: url));
    }
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title.isEmpty ? book.title : title,
        author: author ?? book.author,
        cover: cover ?? book.cover,
        intro: book.intro,
        status: book.status,
        latest: chapters.isEmpty ? null : chapters.last.title,
      ),
      chapters: chapters,
    );
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    return parasInContainer(doc.querySelector('.chapter_box, #chapter_box'));
  }

  @override
  String? pageNextUrl(Document doc, String currentUrl) {
    // 「下一章」指向的是另一章（不同 slug/id）→ 不跟随；章内真分页才跟
    final next = super.pageNextUrl(doc, currentUrl);
    if (next == null) return null;
    final curId = Uri.parse(currentUrl).pathSegments.last;
    final nextId = Uri.parse(next).pathSegments.last;
    return curId == nextId ? next : null;
  }
}
