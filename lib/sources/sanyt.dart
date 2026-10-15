import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'source.dart';

/// 若雨中文 www.3yt.info（老 ASP 站；站点无有效 https，全程走 http）
///
/// - 搜索：GET `/book/search.aspx?searchkey=&SeaButton=`，表格结果行
///   （分类 / 书名 / 最新章节 / 更新时间 / 作者 / 状态）；
/// - 首页：`/Book/<id>/index.html` 书链；
/// - 详情：`h3 em.f30` 书名 / `book/author` 作者 / 写作进程 / `ul.bd p` 简介；
/// - 目录：详情页「全文阅读」→ `/Html/Book/…/Index.shtml`，`#BookText ul li a`；
/// - 正文：`#BookText`（`<br/>` 分段）；「正在手打中」占位章抛错不缓存；
/// - 章内分页：只跟随 `245331_2.shtml` 形态（避免把「下一页」当下一章）。
class SanytSource extends NovelSource {
  @override
  String get id => 'sanyt';
  @override
  String get name => '若雨中文';
  @override
  String get baseUrl => 'http://www.3yt.info';

  static final _bookHrefRe =
      RegExp(r'/Book/\d+/index\.html$', caseSensitive: false);

  @override
  Future<List<Book>> search(String query) async {
    final r = await Net.get(
      '$baseUrl/book/search.aspx'
      '?searchkey=${Uri.encodeQueryComponent(query)}&SeaButton=',
      referer: '$baseUrl/',
    );
    if (r.status != 200) return [];
    final doc = parseHtml(r.body);
    final out = <Book>[];
    final seen = <String>{};
    for (final tr in doc.querySelectorAll('tr')) {
      final tds = tr.querySelectorAll('td');
      if (tds.length < 6) continue;
      final a = tds[1].querySelector('a[href]');
      final href = a?.attributes['href'];
      if (a == null || href == null || !_bookHrefRe.hasMatch(href)) continue;
      final url = absUrl(r.url, href);
      if (!seen.add(url)) continue;
      final author = textOf(tds[4]);
      final status = textOf(tds[5]);
      out.add(Book(
        sourceId: id,
        id: url,
        url: url,
        title: textOf(a),
        author: author.isEmpty ? null : author,
        latest: textOf(tds[2]),
        status: status.isEmpty ? null : status,
      ));
    }
    return out;
  }

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    final out = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href']!;
      if (!_bookHrefRe.hasMatch(href)) continue;
      final title = textOf(a);
      if (title.isEmpty) continue;
      final url = absUrl(baseUrl, href);
      if (!seen.add(url)) continue;
      out.add(Book(sourceId: id, id: url, url: url, title: title));
      if (out.length >= 40) break;
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
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final doc = await fetchDoc(book.url);
    final img = doc.querySelector('.img img, div.img img');
    final alt = (img?.attributes['alt'] ?? '').trim();
    final name = textOf(doc.querySelector('h3 em.f30'));

    var author = '';
    final authorA = doc.querySelector('a[href*="book/author"]');
    if (authorA != null) {
      author = textOf(authorA).replaceFirst('作品集', '').trim();
    }
    String? status;
    for (final li in doc.querySelectorAll('li')) {
      final t = textOf(li);
      if (t.startsWith('写作进程：')) {
        status = t.substring(5).trim();
        break;
      }
    }
    final introParas = <String>[
      for (final p in doc.querySelectorAll('ul.bd p'))
        if (textOf(p).isNotEmpty) textOf(p),
    ];

    // 目录在单独的「全文阅读」页
    final chapters = <Chapter>[];
    final tocHref = findLinkByText(doc, '全文阅读');
    if (tocHref != null) {
      final tocUrl = absUrl(book.url, tocHref);
      final tocDoc = await fetchDoc(tocUrl, referer: book.url);
      chapters.addAll(chapterLinks(tocDoc,
          r'#BookText ul li a, #BookText a[href$=".shtml"]', tocUrl));
    }

    final coverSrc = img?.attributes['src'];
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: name.isNotEmpty ? name : (alt.isEmpty ? book.title : alt),
        author: author.isEmpty ? book.author : author,
        cover: (coverSrc == null || coverSrc.isEmpty)
            ? book.cover
            : absUrl(book.url, coverSrc),
        intro: introParas.isEmpty ? book.intro : introParas.join('\n'),
        status: status ?? book.status,
        latest: chapters.isNotEmpty ? chapters.last.title : book.latest,
      ),
      chapters: chapters,
    );
  }

  static const _junk = [
    '最新网址', '正在手打中', '请稍等片刻', '内容更新后', '请重新刷新',
    '若雨中文', '百度搜索', '书友群',
  ];

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final raw = parasInContainer(doc.querySelector('#BookText'));
    final out = [
      for (final t in raw)
        if (!_junk.any(t.contains)) t,
    ];
    // 「正在手打中」占位章：抛错让用户稍后重试，绝不把占位文本写进缓存
    if (out.join().length < 80 && raw.any((t) => t.contains('正在手打中'))) {
      throw Exception('$name：本章尚未放出（站点手打中），稍后再试');
    }
    return out;
  }

  @override
  String? pageNextUrl(Document doc, String currentUrl) {
    final next = nextPageUrl(doc, currentUrl);
    if (next == null) return null;
    final cur = currentUrl.split('/').last;
    final nxt = next.split('/').last;
    if (!cur.endsWith('.shtml') || !nxt.endsWith('.shtml')) return null;
    final stem = cur.substring(0, cur.length - 6);
    return nxt.startsWith('${stem}_') ? next : null;
  }
}
