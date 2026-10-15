import '../dom.dart';
import '../models.dart';
import 'shuku_cms.dart';

/// 神文小说 www.shenwen.org（同款 CMS）
///
/// - 搜索：继承基类 POST /search.html（未登录 302 → 返回 `[]`）；
/// - 卡片：通用 `a[href^=/book/\d+/?$]`，标题 = img alt ?? title「书名 / 作者」?? 链接文本；
/// - 详情：og:novel:* 元信息；目录 = 详情页 href 章 ∪「章节目录」(a1)
///   `read_tz(cid)` 章，按 cid 升序合并去重；
/// - 排行：9 分榜 `/shuku/<n>/1.html`，分页根前缀 + 页码递增；
/// - 正文：base64 写入型 + 章内茎护栏（继承基类）。
class ShenwenSource extends ShukuCmsSource {
  @override
  String get id => 'shenwen';
  @override
  String get name => '神文小说';
  @override
  String get baseUrl => 'https://www.shenwen.org';

  static final _bookRe = RegExp(r'^/book/\d+/?$');
  static final _chapRe = RegExp(r'^/book/(\d+)/(\d+)\.html$');
  static final _readTzRe = RegExp(
      r'<a[^>]*onclick="read_tz\((\d+)\);?"[^>]*>([^<]*)</a>');

  @override
  List<Book> parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_bookRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final img = a.querySelector('img');
      var title = cleanText(img?.attributes['alt'] ?? '');
      String? author;
      final ta = a.attributes['title'];
      if (ta != null && ta.contains(' / ')) {
        final p = ta.split(' / ');
        if (title.isEmpty) title = cleanText(p[0]);
        if (p.length > 1) author = cleanText(p[1]);
      }
      if (title.isEmpty) title = textOf(a);
      if (title.isEmpty) continue;
      String? intro;
      if (img != null) {
        Element? box = img.parent;
        while (box != null && !box.classes.contains('item_img')) {
          box = box.parent;
        }
        if (box != null) {
          var t = textOf(box).replaceFirst(title, '').trim();
          if (t.length >= 6) intro = t;
        }
      }
      out.add(Book(
        sourceId: id,
        id: url.split('/').where((s) => s.isNotEmpty).last,
        url: url,
        title: title,
        author: author,
        cover: img == null
            ? null
            : absUrl(
                pageUrl, img.attributes['src'] ?? img.attributes['data-src']),
        intro: intro,
      ));
    }
    return out;
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '玄幻修真', url: '/shuku/1/1.html'),
        RankTab(title: '重生穿越', url: '/shuku/2/1.html'),
        RankTab(title: '都市小说', url: '/shuku/3/1.html'),
        RankTab(title: '军史小说', url: '/shuku/4/1.html'),
        RankTab(title: '网游小说', url: '/shuku/5/1.html'),
        RankTab(title: '科幻小说', url: '/shuku/6/1.html'),
        RankTab(title: '灵异小说', url: '/shuku/7/1.html'),
        RankTab(title: '言情小说', url: '/shuku/8/1.html'),
        RankTab(title: '其他小说', url: '/shuku/9/1.html'),
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
    final bookId = book.url.split('/').where((s) => s.isNotEmpty).last;
    if (nextUrl != null) {
      final doc = await fetchDoc(nextUrl, referer: book.url);
      return BookDetail(
        book: book,
        chapters: _readTz(doc, bookId),
        nextChaptersUrl: _tocNext(doc, nextUrl),
      );
    }
    final doc = await fetchDoc(book.url);
    final t = doc.querySelector('title')?.text ?? '';
    final parts = t.split('_');
    final title = metaContent(doc, 'og:novel:book_name') ??
        (parts.isNotEmpty ? cleanText(parts[0]) : book.title);
    final author = metaContent(doc, 'og:novel:author') ??
        (parts.length > 1 ? cleanText(parts[1]) : null);
    final cover = metaContent(doc, 'og:image');
    final status = metaContent(doc, 'og:novel:status');
    final latest = metaContent(doc, 'og:novel:latest_chapter_name');
    // 目录合并：详情页 href 章 ∪「章节目录」a1 页 read_tz 章，cid 升序
    final byCid = <int, Chapter>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final m = _chapRe.firstMatch(a.attributes['href'] ?? '');
      if (m == null || m.group(1) != bookId) continue;
      final name = textOf(a);
      final cid = int.tryParse(m.group(2)!);
      if (name.isEmpty || cid == null) continue;
      byCid[cid] = Chapter(title: name, url: '$baseUrl/book/$bookId/$cid.html');
    }
    String? nextToc;
    var tocHref = findLinkByText(doc, '章节目录', contains: true);
    tocHref ??= findLinkByText(doc, '查看更多章节', contains: true);
    if (tocHref != null) {
      final tocUrl = absUrl(book.url, tocHref);
      final tm = RegExp(r'^/book/(\d+)/a\d+\.html$')
          .firstMatch(Uri.parse(tocUrl).path);
      if (tm != null && tm.group(1) == bookId) {
        final tdoc = await fetchDoc(tocUrl, referer: book.url);
        for (final c in _readTz(tdoc, bookId)) {
          byCid[int.parse(_chapRe.firstMatch(Uri.parse(c.url).path)!.group(2)!)] =
              c; // read_tz 标题优先（后写覆盖）
        }
        nextToc = _tocNext(tdoc, tocUrl);
      }
    }
    final cids = byCid.keys.toList()..sort();
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title,
        author: author,
        cover: cover == null ? book.cover : absUrl(book.url, cover),
        intro: book.intro,
        status: status ?? book.status,
        latest: latest ?? book.latest,
      ),
      chapters: [for (final c in cids) byCid[c]!],
      nextChaptersUrl: nextToc,
    );
  }

  /// read_tz(cid) 章 → cid 升序。
  List<Chapter> _readTz(Document doc, String bookId) {
    final byCid = <int, Chapter>{};
    final raw = doc.documentElement?.innerHtml ?? '';
    for (final m in _readTzRe.allMatches(raw)) {
      final cid = int.tryParse(m.group(1)!);
      final name = cleanText(m.group(2)!);
      if (cid == null || name.isEmpty) continue;
      byCid[cid] = Chapter(title: name, url: '$baseUrl/book/$bookId/$cid.html');
    }
    final cids = byCid.keys.toList()..sort();
    return [for (final c in cids) byCid[c]!];
  }

  /// 目录翻页护栏：aN → a(N+1)，其余（上一页/回首页）拒。
  String? _tocNext(Document doc, String currentUrl) {
    final next = nextPageUrl(doc, currentUrl, contains: true);
    if (next == null) return null;
    final re = RegExp(r'^/book/(\d+)/a(\d+)\.html$');
    final cm = re.firstMatch(Uri.parse(currentUrl).path);
    final nm = re.firstMatch(Uri.parse(next).path);
    if (cm == null || nm == null || cm.group(1) != nm.group(1)) return null;
    final c = int.tryParse(cm.group(2) ?? '');
    final n = int.tryParse(nm.group(2) ?? '');
    if (c == null || n == null || n != c + 1) return null;
    return next;
  }
}
