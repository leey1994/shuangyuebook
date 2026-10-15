import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'shuku_cms.dart';
import 'source.dart';

/// 鬼吹灯 www.gdbzkz.com（.com 会 302 到 .la，同一套页面；站点无有效 https，
/// 全程走 http）。
///
/// - 搜索：GET `/s.php?ie=utf-8&q=`（站内搜索页），结果 `div.bookbox` 卡片；
/// - 首页：`div.hot .item`（封面 + 作者/书名/简介）；
/// - 详情：og:novel 系列 meta；目录 `div.listmain dl dd a`（最新章节在前，
///   由 [chapterLinks] 校正为升序）；
/// - 正文：`#content`（`<br/>` 分段），滤掉站名广告行；
/// - 章内分页：数字茎护栏（只有 `123_2.html` 这类分页才跟随）。
class GdbzkzSource extends NovelSource {
  @override
  String get id => 'gdbzkz';
  @override
  String get name => '鬼吹灯';
  @override
  String get baseUrl => 'http://www.gdbzkz.com';

  static String _afterLabel(String s, String label) {
    final t = cleanText(s);
    return t.startsWith(label) ? t.substring(label.length).trim() : t;
  }

  String? _img(Element? img, String pageUrl) {
    if (img == null) return null;
    final src = img.attributes['src'] ?? img.attributes['data-src'];
    return (src == null || src.isEmpty) ? null : absUrl(pageUrl, src);
  }

  /// 搜索结果卡片：书名/作者/分类/最新章节/封面。
  List<Book> _boxes(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final box in doc.querySelectorAll('div.bookbox')) {
      final a = box.querySelector('.bookname a, h4 a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final author = _afterLabel(textOf(box.querySelector('.author')), '作者：');
      out.add(Book(
        sourceId: id,
        id: url,
        url: url,
        title: textOf(a),
        author: author.isEmpty ? null : author,
        cover: _img(box.querySelector('.bookimg img'), pageUrl),
        latest: textOf(box.querySelector('.update a')),
      ));
    }
    return out;
  }

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    final out = <Book>[];
    final seen = <String>{};
    for (final item in doc.querySelectorAll('div.hot .item')) {
      final a = item.querySelector('dl dt a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      final url = absUrl(baseUrl, href);
      if (!seen.add(url)) continue;
      out.add(Book(
        sourceId: id,
        id: url,
        url: url,
        title: textOf(a),
        author: textOf(item.querySelector('dl dt span')),
        cover: _img(item.querySelector('.image img'), baseUrl),
        intro: textOf(item.querySelector('dd')),
      ));
    }
    return out;
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  @override
  Future<List<Book>> search(String query) async {
    final r = await Net.get(
      '$baseUrl/s.php?ie=utf-8&q=${Uri.encodeQueryComponent(query)}',
      referer: '$baseUrl/',
    );
    if (r.status != 200) return [];
    return _boxes(parseHtml(r.body), r.url);
  }

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final doc = await fetchDoc(book.url);
    final chapters =
        chapterLinks(doc, '.listmain dl dd a, .listmain dd a', book.url);
    final name = metaContent(doc, 'og:novel:book_name');
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: name ?? book.title,
        author: metaContent(doc, 'og:novel:author') ?? book.author,
        cover: metaContent(doc, 'og:image') ?? book.cover,
        intro: metaContent(doc, 'og:description') ?? book.intro,
        status: book.status,
        latest: chapters.isNotEmpty ? chapters.last.title : book.latest,
      ),
      chapters: chapters,
    );
  }

  static const _junk = [
    '一秒记住', '无弹窗', '请记住本站', '最新网址', '天才一秒', '爱尚小说',
  ];

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final box = doc.querySelector('#content, .showtxt');
    return [
      for (final t in parasInContainer(box))
        if (!_junk.any(t.contains)) t,
    ];
  }

  @override
  bool allowFollow(String currentUrl, String nextUrl) =>
      ShukuCmsSource.sameStem(ShukuCmsSource.stem(currentUrl), nextUrl);
}
