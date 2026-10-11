import '../dom.dart';
import '../models.dart';
import 'shuku_cms.dart';

/// 篱笆好文学 m.libahao2.com（同款 CMS）
///
/// - 搜索：覆写 GET `/sou?wd=`；
/// - 卡片：通用 `a[href^=/book/\d+_\d+/$]`，标题 = h3 ?? title ?? img alt 去「封面」；
/// - 详情：h1 书名；目录 = 页面 `<ol>` 章链接（DOM 升序，首/尾数字判向防御）；
/// - 排行：10 分榜，分页根前缀 + 页码递增；
/// - 正文：`#readerSurface, .mr-surface` 容器；章内下一页 = 同茎跟随。
class LibahaoSource extends ShukuCmsSource {
  @override
  String get id => 'libahao';
  @override
  String get name => '篱笆好文学';
  @override
  String get baseUrl => 'https://m.libahao2.com';

  static final _bookRe = RegExp(r'^/book/\d+_\d+/$');
  static final _chapRe = RegExp(r'^/book/\d+_\d+/(\d+)\.html$');

  @override
  Future<List<Book>> search(String query) async {
    final doc = await fetchDoc(
      '$baseUrl/sou?wd=${Uri.encodeQueryComponent(query)}',
      referer: '$baseUrl/',
    );
    return parseCards(doc, '$baseUrl/sou?wd=$query');
  }

  @override
  List<Book> parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_bookRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final segs = href.split('/').where((s) => s.isNotEmpty).toList();
      final fullId = segs.isNotEmpty ? segs.last : '';
      final id2 = fullId.contains('_') ? fullId.split('_').last : fullId;
      var title = textOf(a.querySelector('h3'));
      if (title.isEmpty) title = cleanText(a.attributes['title'] ?? '');
      if (title.isEmpty) {
        final alt = a.querySelector('img')?.attributes['alt'] ?? '';
        title = cleanText(alt.replaceFirst(RegExp(r'封面$'), ''));
      }
      if (title.isEmpty) continue;
      final img = a.querySelector('img');
      final meta = textOf(a.querySelector('p.m-book-meta'));
      final desc = textOf(a.querySelector('p.m-book-description'));
      out.add(Book(
        sourceId: id,
        id: fullId,
        url: url,
        title: title,
        author: meta.isEmpty ? null : cleanText(meta.split('·').first),
        cover: img != null && (img.attributes['src'] ?? '').isNotEmpty
            ? absUrl(pageUrl, img.attributes['src'])
            : '$baseUrl/data/image/$id2.jpg',
        intro: desc.isEmpty ? null : desc,
      ));
    }
    return out;
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '排行榜', url: '/paihangbang/'),
        RankTab(title: '玄幻魔法', url: '/xuanhuan/'),
        RankTab(title: '武侠修真', url: '/xiuzhen/'),
        RankTab(title: '都市言情', url: '/dushi/'),
        RankTab(title: '历史军事', url: '/lishi/'),
        RankTab(title: '游戏竞技', url: '/wangyou/'),
        RankTab(title: '科幻灵异', url: '/kehuan/'),
        RankTab(title: '女生言情', url: '/nvpin/'),
        RankTab(title: '其他小说', url: '/qita/'),
        RankTab(title: '完本专区', url: '/quanben/'),
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
          book: book, chapters: _chapters(doc, nextUrl), nextChaptersUrl: null);
    }
    final doc = await fetchDoc(book.url);
    final segs = book.url.split('/').where((s) => s.isNotEmpty).toList();
    final fullId = segs.isNotEmpty ? segs.last : book.id;
    final id2 = fullId.contains('_') ? fullId.split('_').last : fullId;
    final title = textOf(doc.querySelector('h1#book-title'));
    // 作者：<title> split('|').last → split(' - ').first → 去「作者」前缀
    var author = book.author;
    final tt = doc.querySelector('title')?.text ?? '';
    final last = tt.split('|').last;
    var s = last.split(' - ').first;
    s = s.replaceFirst(RegExp(r'^\s*作者\s*'), '').trim();
    if (s.isNotEmpty) author = s;
    return BookDetail(
      book: Book(
        sourceId: book.sourceId, id: book.id, url: book.url,
        title: title.isEmpty ? book.title : title,
        author: author, cover: book.cover ?? '$baseUrl/data/image/$id2.jpg',
        intro: book.intro, status: book.status, latest: book.latest,
      ),
      chapters: _chapters(doc, book.url),
      nextChaptersUrl: null,
    );
  }

  /// `<ol>` 内 `/book/<id>/<n>.html` 章链接，DOM 序；首/尾数字判向防御。
  List<Chapter> _chapters(Document doc, String pageUrl) {
    final out = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('ol a[href]')) {
      final href = a.attributes['href'] ?? '';
      if (!_chapRe.hasMatch(href)) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      out.add(Chapter(title: t, url: url));
    }
    if (out.length > 1) {
      final f = int.tryParse(_chapRe.firstMatch(Uri.parse(out.first.url).path)!.group(1)!);
      final l = int.tryParse(_chapRe.firstMatch(Uri.parse(out.last.url).path)!.group(1)!);
      if (f != null && l != null && f > l) return out.reversed.toList();
    }
    return out;
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) =>
      parasInContainer(doc.querySelector('#readerSurface, .mr-surface'));

  @override
  String? pageNextUrl(Document doc, String currentUrl) {
    final next = nextPageUrl(doc, currentUrl, contains: true);
    if (next == null) return null;
    return ShukuCmsSource.sameStem(ShukuCmsSource.stem(currentUrl), next)
        ? next
        : null;
  }
}
