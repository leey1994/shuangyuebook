import '../dom.dart';
import '../models.dart';
import '../net.dart';

/// 各站点适配器的统一接口。
abstract class NovelSource {
  String get id;
  String get name;
  String get baseUrl;

  /// 站点首页推荐（无推荐内容的站返回空列表）。
  Future<List<Book>> fetchHome();

  /// 排行榜分榜标签。
  Future<List<RankTab>> fetchRankTabs();

  /// 排行榜列表；nextUrl 来自上一页的 Paged.nextUrl。
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl});

  /// 书单中心列表（多数站没有书单，返回空）。
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl});

  /// 书单详情。
  Future<Booklist> fetchBooklist(BooklistEntry entry);

  /// 搜索。
  Future<List<Book>> search(String query);

  /// 书籍详情 + 目录；nextUrl 用于加载目录后续页。
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl});

  /// 抓取章节正文：自动拼接「下一页」分页；正文若由外部脚本注入则一并拉取。
  /// 任一请求失败重试 2 次后抛错——宁可报错让用户重试，也不返回半截正文
  ///（半截结果一旦写缓存就是永久缺文）。
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    final out = <String>[];
    final seen = <String>{};
    String? url = chapter.url;
    var guard = 0;
    while (url != null && guard < 100 && seen.add(url)) {
      guard++;
      final r = await getOk(url, referer: detail.book.url);
      final doc = parseHtml(r.body);
      out.addAll(contentOf(doc, url));
      // 正文容器引用外部正文脚本时（速读谷 page2+），拉取并解出段落
      for (final su in contentScriptUrls(doc, url)) {
        final sr = await getOk(su, referer: url);
        out.addAll(parasFromDocWrite(sr.body));
      }
      final next = nextPageUrl(doc, url);
      url = (next != null && allowFollow(url, next)) ? next : null;
    }
    return cleanParas(out);
  }

  /// GET 并要求 200；失败短暂等待后重试，共 3 次机会，仍失败抛错。
  Future<Resp> getOk(String url, {String? referer}) async {
    Object? last;
    for (var i = 0; i < 3; i++) {
      try {
        final r = await Net.get(url, referer: referer);
        if (r.status == 200) return r;
        last = 'HTTP ${r.status}';
      } catch (e) {
        last = e;
      }
      if (i < 2) await Future.delayed(Duration(milliseconds: 400 * (i + 1)));
    }
    throw Exception('$name 抓取失败($last) $url');
  }

  /// 正文容器引用的外部正文脚本地址（默认无；速读谷 page2+ 经此注入正文）。
  List<String> contentScriptUrls(Document doc, String pageUrl) => [];

  /// 正文段落提取（子类实现）。
  List<String> contentOf(Document doc, String pageUrl);

  /// 是否允许跟随「下一页」链接（子类可过滤误判为翻页的下一章链接）。
  bool allowFollow(String currentUrl, String nextUrl) => true;

  /// 便捷：请求 + 解析。
  Future<Document> fetchDoc(String url, {String? referer}) async {
    final r = await Net.get(url, referer: referer);
    if (r.status != 200) {
      throw Exception('$name: HTTP ${r.status} $url');
    }
    return parseHtml(r.body);
  }
}

/// 按选择器提取段落文本，[skip] 可过滤个别元素。
List<String> parasFrom(
  Document doc,
  String selector, {
  bool Function(Element e)? skip,
}) {
  final raw = <String>[];
  for (final e in doc.querySelectorAll(selector)) {
    if (skip != null && skip(e)) continue;
    raw.add(e.text);
  }
  return raw;
}
