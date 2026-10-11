import '../dom.dart';
import '../models.dart';
import 'source.dart';

/// 速读谷 www.suduguu.com
///
/// 列表统一为 `div.item`；章节内分页 `下一页` -> `{chapter}-2.html`；
/// 搜索 `/i/sor.aspx?key=`。
class SuduGuuSource extends NovelSource {
  @override
  String get id => 'suduguu';
  @override
  String get name => '速读谷';
  @override
  String get baseUrl => 'https://www.suduguu.com';

  static final _bookRe = RegExp(r'^https?://[^/]+/\d+/?$');

  // ---------- 列表解析 ----------

  static List<Book> parseItemList(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final item in doc.querySelectorAll('div.item, .item')) {
      String? url;
      for (final a in item.querySelectorAll('a[href]')) {
        final u = absUrl(pageUrl, a.attributes['href']);
        if (_bookRe.hasMatch(u)) {
          url = u;
          break;
        }
      }
      if (url == null || !seen.add(url)) continue;

      final titleA = item.querySelector('h3 a, h2 a, h1 a');
      final title = textOf(titleA).isNotEmpty
          ? textOf(titleA)
          : (item.querySelector('img')?.attributes['alt'] ?? '');

      String? author;
      String? status;
      String? category;
      String? latest;
      for (final p in item.querySelectorAll('p')) {
        final t = textOf(p);
        if (t.startsWith('作者')) {
          author = t.replaceFirst(RegExp(r'^作者\s*[：:]?\s*'), '');
        } else if (p.querySelector('span') != null) {
          final spans = p.querySelectorAll('span').map(textOf).toList();
          if (spans.isNotEmpty) status = spans[0];
          if (spans.length > 1) category = spans[1];
        }
      }
      final firstCh = item.querySelector('ul li a');
      if (firstCh != null) latest = textOf(firstCh);

      final img = item.querySelector('img');
      final statusText = category == null
          ? (status ?? '')
          : '${status ?? ''} · $category';
      out.add(Book(
        sourceId: 'suduguu',
        id: url,
        url: url,
        title: title,
        author: author,
        cover: absUrl(pageUrl, img?.attributes['src']),
        intro: null,
        status: statusText.trim().isEmpty ? null : statusText.trim(),
        latest: latest,
      ));
    }
    return out;
  }

  // ---------- 首页 / 排行 ----------

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return parseItemList(doc, baseUrl);
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '排行榜', url: 'https://www.suduguu.com/paihang/'),
        RankTab(title: '完结小说', url: 'https://www.suduguu.com/wanjie/'),
        RankTab(title: '最新更新', url: 'https://www.suduguu.com/zuixin/'),
      ];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final url = nextUrl ?? tab.url;
    final doc = await fetchDoc(url);
    return Paged(
      items: parseItemList(doc, url),
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
        '$baseUrl/i/sor.aspx?key=${Uri.encodeQueryComponent(query)}');
    return parseItemList(doc, '$baseUrl/i/sor.aspx');
  }

  // ---------- 详情 ----------

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final url = nextUrl ?? book.url;
    final doc = await fetchDoc(url, referer: book.url);

    var title = textOf(doc.querySelector('h1'));
    // h1 内含 i 标签（字数），去掉
    final i = doc.querySelector('h1 i');
    if (i != null) {
      title = title.replaceAll(textOf(i), '');
    }
    title = cleanText(title);
    if (title.isEmpty) title = book.title;

    String? author = book.author;
    for (final a in doc.querySelectorAll('a[href]')) {
      final t = textOf(a);
      if (t.startsWith('作者')) {
        author = t.replaceFirst(RegExp(r'^作者\s*[：:]?\s*'), '');
        break;
      }
    }

    final intro = textOf(doc.querySelector('.des, .intro, #intro'));
    final img = doc.querySelector('img[src*="cover"]');

    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('#list ul li a, #list a')) {
      final href = a.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final cu = absUrl(url, href);
      if (cu == url || !seen.add(cu)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      chapters.add(Chapter(title: t, url: cu));
    }

    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title,
        author: author,
        cover: img == null ? book.cover : absUrl(url, img.attributes['src']),
        intro: intro.isNotEmpty ? intro : book.intro,
        status: book.status,
        latest: book.latest,
      ),
      chapters: chapters,
      nextChaptersUrl: nextPageUrl(doc, url),
    );
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) =>
      parasFrom(doc, 'div.con p, .con p');

  /// page2+ 的正文不在 HTML 里：`.con` 中是
  /// `<script src="/i/a.aspx?id=..&p=..&bid=..">`，响应为 document.write 注入，
  /// 解析器必须补拉该脚本才能拿到后半章（否则每章只剩第一页）。
  @override
  List<String> contentScriptUrls(Document doc, String pageUrl) {
    final out = <String>[];
    for (final s in doc.querySelectorAll('.con script[src]')) {
      final src = s.attributes['src'];
      if (src != null && src.isNotEmpty) out.add(absUrl(pageUrl, src));
    }
    return out;
  }
}
