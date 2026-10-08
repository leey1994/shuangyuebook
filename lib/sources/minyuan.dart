import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'shuku_cms.dart';

/// 小原文学 www.min-yuan.com（同款 CMS）
///
/// - 搜索：覆写 POST `/search/` 表单 `{searchkey}`；
/// - 卡片：`div.item`（title 属性 + data-original 封面 + dd 简介），
///   兜底裸 `a[href^=/txt/…/]` 带 title；
/// - 详情：h1 书名 + 正文区 `作者：`/`状态：` 正则；目录 = `#list`
///   `^/txt/<slug>/<n>.html$` 按数字升序去重（页首「最新 N 章」降序重复）；
/// - 排行：8 分榜 `/xuanhuan/` 等，分页根前缀 + 页码递增；
/// - 正文：base64 写入型 + 章内茎护栏（继承基类）。
class MinyuanSource extends ShukuCmsSource {
  @override
  String get id => 'minyuan';
  @override
  String get name => '小原文学';
  @override
  String get baseUrl => 'https://www.min-yuan.com';

  static final _bookRe = RegExp(r'^/txt/[a-z0-9_]+/$');
  static final _chapRe = RegExp(r'^/txt/[a-z0-9_]+/(\d+)\.html$');
  static final _authorRe =
      RegExp(r'作者\s*[：:]\s*(\S{1,15}?)(?=$|\s|状态|分类|更新)');
  static final _statusRe =
      RegExp(r'状态\s*[：:]\s*(\S{1,15}?)(?=$|\s|状态|分类|更新)');

  @override
  Future<List<Book>> search(String query) async {
    final r = await Net.postForm(
      '$baseUrl/search/',
      {'searchkey': query},
      referer: '$baseUrl/',
    );
    if (r.status != 200) return [];
    return parseCards(parseHtml(r.body), r.url);
  }

  @override
  List<Book> parseCards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};

    void add(String href, String title, {String? cover, String? intro}) {
      if (!_bookRe.hasMatch(href) || title.isEmpty) return;
      final url = absUrl(pageUrl, href);
      if (!seen.add(url)) return;
      final segs = href.split('/').where((s) => s.isNotEmpty).toList();
      out.add(Book(
        sourceId: id,
        id: segs.isNotEmpty ? segs.last : href,
        url: url,
        title: title,
        cover: cover,
        intro: intro,
      ));
    }

    // 形态一：div.item（title 属性 + data-original 封面 + dd 简介）
    for (final item in doc.querySelectorAll('div.item')) {
      Element? a;
      for (final x in item.querySelectorAll('a[href]')) {
        if (_bookRe.hasMatch(x.attributes['href'] ?? '')) {
          a = x;
          break;
        }
      }
      if (a == null) continue;
      final img = item.querySelector('img');
      final src = img?.attributes['data-original'] ?? img?.attributes['src'];
      final dd = textOf(item.querySelector('dd'));
      add(
        a.attributes['href'] ?? '',
        cleanText(a.attributes['title'] ?? textOf(a)),
        cover: (src == null || src.isEmpty) ? null : absUrl(pageUrl, src),
        intro: dd.isEmpty ? null : dd,
      );
    }

    // 形态二兜底：裸书链接带 title 属性
    if (out.isEmpty) {
      for (final a in doc.querySelectorAll('a[href]')) {
        final href = a.attributes['href'] ?? '';
        if (!_bookRe.hasMatch(href)) continue;
        final t = cleanText(a.attributes['title'] ?? '');
        if (t.isEmpty) continue;
        add(href, t);
      }
    }
    return out;
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '玄幻', url: '/xuanhuan/'),
        RankTab(title: '武侠', url: '/wuxia/'),
        RankTab(title: '都市', url: '/dushi/'),
        RankTab(title: '历史', url: '/lishi/'),
        RankTab(title: '科幻', url: '/kehuan/'),
        RankTab(title: '游戏', url: '/youxi/'),
        RankTab(title: '女生', url: '/nvsheng/'),
        RankTab(title: '其他', url: '/qita/'),
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
    final doc = await fetchDoc(book.url);
    final segs = book.url.split('/').where((s) => s.isNotEmpty).toList();
    final slug = segs.isNotEmpty ? segs.last : book.id;
    final title = textOf(doc.querySelector('h1'));
    final body = textOf(doc.body);
    final am = _authorRe.firstMatch(body);
    final sm = _statusRe.firstMatch(body);
    final latest = textOf(doc.querySelector('a[rel="chapter"]'));
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title.isEmpty ? book.title : title,
        author: am?.group(1) ?? book.author,
        cover: book.cover ?? '$baseUrl/images/$slug.jpg',
        intro: book.intro,
        status: sm?.group(1) ?? book.status,
        latest: latest.isEmpty ? null : latest,
      ),
      chapters: _chapters(doc, book.url),
      nextChaptersUrl: null, // #list 一次给全（页首「最新 12 章」降序重复已去重）
    );
  }

  /// `#list` 内 `/txt/<slug>/<n>.html` 章链接，按数字升序去重。
  List<Chapter> _chapters(Document doc, String pageUrl) {
    final byNum = <int, Chapter>{};
    for (final a in doc.querySelectorAll('#list a[href]')) {
      final href = a.attributes['href'] ?? '';
      final m = _chapRe.firstMatch(href);
      if (m == null) continue;
      final n = int.tryParse(m.group(1)!);
      final t = textOf(a);
      if (n == null || t.isEmpty) continue;
      byNum[n] = Chapter(title: t, url: absUrl(pageUrl, href));
    }
    final nums = byNum.keys.toList()..sort();
    return [for (final n in nums) byNum[n]!];
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final b64 = parasFromB64Writes(doc.documentElement?.innerHtml ?? '');
    if (b64.isNotEmpty) return b64;
    return parasInContainer(doc.querySelector('.box_par, .box_con'));
  }
}
