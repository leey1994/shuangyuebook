import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'shuku_cms.dart';
import 'source.dart';

/// 抖音小说 www.douyinxs.com（笔趣阁模板）
///
/// - 搜索：POST `/search/` 表单 `searchkey`，`.novelslist2 ul li` 结果行；
/// - 首页：`a[href^=/bqg/…]` 书链（去重取前 40）；
/// - 详情：og:novel meta + `#info`/`#intro`；目录 `#list dd a`
///   （最新章节在前，由 [chapterLinks] 校正为升序）；
/// - 正文：`#content` 的 `<p>`（首段是章节标题，去掉）；
/// - 章内分页：数字茎护栏。
class DouyinxsSource extends NovelSource {
  @override
  String get id => 'douyinxs';
  @override
  String get name => '抖音小说';
  @override
  String get baseUrl => 'https://www.douyinxs.com';

  static String? _nn(String s) => s.isEmpty ? null : s;

  List<Book> _rows(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final li in doc.querySelectorAll('.novelslist2 ul li')) {
      final a = li.querySelector('.s2 a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) continue;
      final author = textOf(li.querySelector('.s4'));
      out.add(Book(
        sourceId: id,
        id: url,
        url: url,
        title: textOf(a),
        author: author.isEmpty ? null : author,
        latest: textOf(li.querySelector('.s3 a')),
      ));
    }
    return out;
  }

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    final out = <Book>[];
    final seen = <String>{};
    final re = RegExp(r'^/bqg/\d+/?$');
    for (final a in doc.querySelectorAll('a[href]')) {
      final href = a.attributes['href']!;
      if (!re.hasMatch(href)) continue;
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
  Future<List<Book>> search(String query) async {
    final r = await Net.postForm(
      '$baseUrl/search/',
      {'searchkey': query},
      referer: '$baseUrl/',
    );
    if (r.status != 200) return [];
    return _rows(parseHtml(r.body), r.url);
  }

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final doc = await fetchDoc(book.url);
    final chapters = chapterLinks(doc, '#list dd a', book.url);
    String? infoP(String label) {
      for (final p in doc.querySelectorAll('#info p')) {
        final t = cleanText(p.text).replaceAll(' ', '');
        if (t.startsWith(label)) {
          return t.replaceFirst(RegExp('^$label[：:]'), '').trim();
        }
      }
      return null;
    }

    final intro = _nn(textOf(doc.querySelector('#intro'))) ??
        metaContent(doc, 'og:description');
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: metaContent(doc, 'og:novel:book_name') ??
            _nn(textOf(doc.querySelector('#info h1'))) ??
            book.title,
        author:
            metaContent(doc, 'og:novel:author') ?? infoP('作者') ?? book.author,
        cover: metaContent(doc, 'og:image') ?? book.cover,
        intro: intro ?? book.intro,
        status: book.status,
        latest: chapters.isNotEmpty ? chapters.last.title : book.latest,
      ),
      chapters: chapters,
    );
  }

  static const _junk = [
    '一秒记住', '无弹窗', '请记住本站', '最新网址', '天才一秒', '加入书签',
  ];

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final raw = parasFrom(doc, '#content p');
    final out = <String>[];
    for (var i = 0; i < raw.length; i++) {
      final t = cleanText(raw[i]);
      if (t.isEmpty) continue;
      // 站点把章节标题也放进正文容器，首段丢掉
      if (i == 0 && t.length < 30 && RegExp(r'第.{1,12}[章节回]').hasMatch(t)) {
        continue;
      }
      if (_junk.any(t.contains)) continue;
      out.add(t);
    }
    // 少数章节是裸文本（<br/> 分段）
    if (out.isEmpty) {
      return parasInContainer(doc.querySelector('#content'));
    }
    return out;
  }

  @override
  bool allowFollow(String currentUrl, String nextUrl) =>
      ShukuCmsSource.sameStem(ShukuCmsSource.stem(currentUrl), nextUrl);
}
