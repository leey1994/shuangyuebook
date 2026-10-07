import '../dom.dart';
import '../models.dart';
import 'source.dart';

/// 黄金屋 www.huangjinwu.org
///
/// 卡片 `a.book-card`；排行 `/rank/{id}` + `.filter-tags` 标签；
/// 详情 `/novel/{id}`（章节目录分页 `/novel/{id}/{page}.html`）；
/// 正文 `.reader-content`，章内分页 `#nextChapter`「下一页」`/2.html`。
/// 站点带简易浏览器检查（见 Net 的 `__sc_clearance` 重试）。
class HuangJinWuSource extends NovelSource {
  @override
  String get id => 'huangjinwu';
  @override
  String get name => '黄金屋';
  @override
  String get baseUrl => 'https://www.huangjinwu.org';

  static final _chapterRe = RegExp(r'^/novel/\d+/\d+$');

  // ---------- 卡片列表 ----------

  static List<Book> parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a.book-card[href]')) {
      final url = absUrl(pageUrl, a.attributes['href']);
      if (!seen.add(url)) continue;
      final title = textOf(a.querySelector('.book-title')).isNotEmpty
          ? textOf(a.querySelector('.book-title'))
          : (a.attributes['title'] ?? '');
      var author = textOf(a.querySelector('.book-author'));
      author = author.replaceFirst(RegExp(r'^作者\s*[：:]?\s*'), '');
      final intro = textOf(a.querySelector('.book-desc'));
      final badges =
          a.querySelectorAll('.book-badge').map((e) => textOf(e)).toList();
      String? status;
      String? category;
      for (final b in badges) {
        if (b.contains('连载') || b.contains('全本') || b.contains('完结')) {
          status = b;
        } else if (b.contains('点击') || b.contains('字')) {
          // 点击数/字数，不进 status
        } else {
          category ??= b;
        }
      }
      out.add(Book(
        sourceId: 'huangjinwu',
        id: url,
        url: url,
        title: title,
        author: author.isEmpty ? null : author,
        intro: intro.isEmpty ? null : intro,
        status: category == null ? status : '$status · $category',
      ));
    }
    // 兜底：排行模块 ranking-item
    if (out.isEmpty) {
      final seen2 = <String>{};
      for (final a in doc.querySelectorAll('a.ranking-title[href]')) {
        final url = absUrl(pageUrl, a.attributes['href']);
        if (!seen2.add(url)) continue;
        final p = a.parent;
        final author = p is Element
            ? textOf(p.querySelector('.ranking-author'))
                .replaceFirst(RegExp(r'^作者\s*[：:]?\s*'), '')
            : '';
        out.add(Book(
          sourceId: 'huangjinwu',
          id: url,
          url: url,
          title: cleanText(a.attributes['title'] ?? a.text),
          author: author.isEmpty ? null : author,
        ));
      }
    }
    return out;
  }

  // ---------- 首页 / 排行 ----------

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return parseCards(doc, baseUrl);
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async {
    final doc = await fetchDoc('$baseUrl/rank');
    final seen = <String>{};
    final tabs = <RankTab>[];
    for (final a in doc.querySelectorAll('.filter-tags a.filter-tag[href]')) {
      final url = absUrl(baseUrl, a.attributes['href']);
      if (!seen.add(url)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      tabs.add(RankTab(title: t, url: url));
    }
    if (tabs.isEmpty) {
      tabs.add(const RankTab(title: '排行榜', url: 'https://www.huangjinwu.org/rank'));
    }
    return tabs;
  }

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final url = nextUrl ?? tab.url;
    final doc = await fetchDoc(url);
    return Paged(
      items: parseCards(doc, url),
      nextUrl: nextPageUrl(doc, url),
    );
  }

  // ---------- 书单（该站没有） ----------

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  // ---------- 搜索 ----------

  @override
  Future<List<Book>> search(String query) async {
    final doc = await fetchDoc(
        '$baseUrl/search?keyword=${Uri.encodeQueryComponent(query)}');
    return parseCards(doc, '$baseUrl/search');
  }

  // ---------- 详情 ----------

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final url = nextUrl ?? book.url;
    final doc = await fetchDoc(url, referer: book.url);

    var title = metaContent(doc, 'og:novel:book_name') ??
        textOf(doc.querySelector('.detail-title, h1'));
    if (title.isEmpty) title = book.title;
    final author =
        metaContent(doc, 'og:novel:author') ?? book.author;
    final cover = metaContent(doc, 'og:image') ?? book.cover;
    var intro = metaContent(doc, 'og:description') ??
        textOf(doc.querySelector('.detail-intro-content'));
    if (intro.isEmpty) intro = book.intro ?? '';
    final status = metaContent(doc, 'og:novel:status') ?? book.status;

    // 章节目录只取「章节目录」小节，避开「最新章节」（倒序）
    Element? tocSection;
    for (final sec in doc.querySelectorAll('.detail-section')) {
      final h = textOf(sec.querySelector('h2, h3'));
      if (h.contains('章节目录')) {
        tocSection = sec;
        break;
      }
    }
    final root = tocSection ?? doc;

    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final a in root.querySelectorAll('.chapter-item a[href]')) {
      final cu = absUrl(url, a.attributes['href']);
      if (!_chapterRe.hasMatch(Uri.parse(cu).path) || !seen.add(cu)) continue;
      final t = cleanText(a.attributes['title'] ?? a.text);
      if (t.isEmpty) continue;
      chapters.add(Chapter(title: t, url: cu));
    }
    // 兜底：未匹配到目录小节时全页抓
    if (chapters.isEmpty) {
      for (final a in doc.querySelectorAll('.chapter-item a[href]')) {
        final cu = absUrl(url, a.attributes['href']);
        if (!_chapterRe.hasMatch(Uri.parse(cu).path) || !seen.add(cu)) continue;
        final t = cleanText(a.attributes['title'] ?? a.text);
        if (t.isNotEmpty) chapters.add(Chapter(title: t, url: cu));
      }
    }

    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title,
        author: author,
        cover: cover,
        intro: intro,
        status: status,
        latest: book.latest,
      ),
      chapters: chapters,
      nextChaptersUrl: nextPageUrl(doc, url),
    );
  }

  // ---------- 正文 ----------

  @override
  List<String> contentOf(Document doc, String pageUrl) => parasFrom(
        doc,
        '.reader-content p',
        skip: (e) => e.classes.contains('reader-updated'),
      );

  /// 章内翻页是 `/novel/{id}/{chapterId}/2.html`；
  /// 「下一章」是 `/novel/{id}/{chapterId}`，不是本章子页，禁止跟随。
  @override
  bool allowFollow(String currentUrl, String nextUrl) {
    final cur = Uri.parse(currentUrl).path;
    final nxt = Uri.parse(nextUrl).path;
    if (_chapterRe.hasMatch(nxt) && _chapterRe.hasMatch(cur)) return false;
    return true;
  }
}
