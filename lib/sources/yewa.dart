import 'dart:convert';

import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'source.dart';

/// 顶点小说 m.yewa.cc
///
/// 搜索走 `/user/search.html` 页面内联 JS 变量签名 + POST `/api/search`，
/// 这里复刻 common.js 中 `book.search()` 的行为：
/// 1) GET 搜索页提取 `var xx="..."` 全部参数与 sign；
/// 2) search_before()：若页面可见 cookie 非空，bgt 去掉最后一位；
/// 3) POST 表单到 /api/search，解析 JSON data.search。
class YewaSource extends NovelSource {
  @override
  String get id => 'yewa';
  @override
  String get name => '顶点小说';
  @override
  String get baseUrl => 'https://m.yewa.cc';

  static final _bookRe = RegExp(r'/xiaoshuo/\d+/\d+');

  // ---------- 首页 / 排行 ----------

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return parseBookList(doc, baseUrl);
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async {
    final doc = await fetchDoc('$baseUrl/top/weekvisit/');
    final seen = <String>{};
    final tabs = <RankTab>[];
    for (final a in doc.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      if (!href.contains('/top/')) continue;
      final url = absUrl(baseUrl, href);
      if (!seen.add(url)) continue;
      final title = cleanText(a.text);
      if (title.isEmpty) continue;
      tabs.add(RankTab(title: title, url: url));
    }
    if (tabs.isEmpty) {
      tabs.add(const RankTab(title: '周点击榜', url: 'https://m.yewa.cc/top/weekvisit/'));
    }
    return tabs;
  }

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final doc = await fetchDoc(nextUrl ?? tab.url);
    final next = nextPageUrl(doc, nextUrl ?? tab.url);
    return Paged(items: parseBookList(doc, nextUrl ?? tab.url), nextUrl: next);
  }

  /// 首页/榜单共用的 `article` 列表解析。
  static List<Book> parseBookList(Document doc, String pageUrl) {
    final out = <Book>[];
    final nodes = doc.querySelectorAll('#list article, article');
    final seen = <String>{};
    for (final art in nodes) {
      String? url;
      for (final a in art.querySelectorAll('a')) {
        final href = a.attributes['href'] ?? '';
        if (_bookRe.hasMatch(href)) {
          url = absUrl(pageUrl, href);
          break;
        }
      }
      if (url == null || !seen.add(url)) continue;

      final h2 = art.querySelector('h2, h3, .title');
      final title = textOf(h2).isNotEmpty
          ? textOf(h2)
          : cleanText(art.querySelector('a')?.attributes['title'] ?? '');

      String? author;
      String? intro;
      for (final p in art.querySelectorAll('p')) {
        final t = textOf(p);
        if (t.startsWith('作者')) {
          author = t.replaceFirst(RegExp(r'^作者\s*[：:]?\s*'), '');
        } else if (t.startsWith('简介')) {
          intro = t.replaceFirst(RegExp(r'^简介\s*[：:]?\s*'), '');
        }
      }
      final img = art.querySelector('img');
      final cover = absUrl(pageUrl, img?.attributes['src']);
      final m = _bookRe.firstMatch(url)!;
      out.add(Book(
        sourceId: 'yewa',
        id: m.group(0)!,
        url: url,
        title: title.isEmpty ? (art.querySelector('img')?.attributes['alt'] ?? '') : title,
        author: author,
        cover: cover,
        intro: intro,
      ));
    }
    return out;
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
    final pageUrl = '$baseUrl/user/search.html?q=${Uri.encodeQueryComponent(query)}';
    final r = await Net.get(pageUrl);
    if (r.status != 200) return [];

    // 提取内联脚本里的 var NAME="VALUE";
    final vars = <String, String>{};
    final re = RegExp(r'var\s+([A-Za-z_]\w*)\s*=\s*"([^"]*)"');
    for (final m in re.allMatches(r.body)) {
      vars[m.group(1)!] = m.group(2)!;
    }
    final sign = vars['sign'];
    if (sign == null || sign.isEmpty || vars['vw'] == null) return [];

    // search_before(): document.cookie 非空时 bgt 去尾字符
    if (Net.hasCookiesFor(pageUrl) && (vars['bgt'] ?? '').isNotEmpty) {
      final bgt = vars['bgt']!;
      vars['bgt'] = bgt.substring(0, bgt.length - 1);
    }

    final body = <String, String>{'q': query, ...vars};
    final resp = await Net.postForm('$baseUrl/api/search', body,
        referer: pageUrl);
    if (resp.status != 200) return [];
    try {
      final j = jsonDecode(resp.body) as Map<String, dynamic>;
      if (j['code'] != 0) return [];
      final data = j['data'] as Map<String, dynamic>? ?? {};
      final list = data['search'] as List<dynamic>? ?? [];
      final out = <Book>[];
      for (final it in list.cast<Map<String, dynamic>>()) {
        final raw = it['book_list_url'];
        if (raw is! String || raw.isEmpty) continue;
        final url = absUrl(baseUrl, raw);
        if (url.isEmpty || url == baseUrl) continue;
        final m = _bookRe.firstMatch(url);
        out.add(Book(
          sourceId: 'yewa',
          id: m?.group(0) ?? url,
          url: url,
          title: (it['title'] ?? it['book_name'] ?? '') as String,
          author: (it['author'] ?? '') as String?,
          cover: absUrl(baseUrl, (it['cover'] ?? '') as String?),
          intro: (it['intro'] ?? '') as String?,
        ));
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  // ---------- 详情 / 正文 ----------

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final url = nextUrl ?? book.url;
    final doc = await fetchDoc(url, referer: book.url);
    final title = metaContent(doc, 'og:novel:book_name') ??
        metaContent(doc, 'og:title') ??
        book.title;
    final author = metaContent(doc, 'og:novel:author') ?? book.author;
    final cover = metaContent(doc, 'og:image') ?? book.cover;
    final intro = metaContent(doc, 'og:description') ??
        book.intro ??
        cleanText(doc.querySelector('.introbar')?.text ?? '');
    final status = metaContent(doc, 'og:novel:status');

    final chapters = <Chapter>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('ul.chapter li a, #list li a')) {
      final href = a.attributes['href'];
      if (href == null || href.isEmpty) continue;
      final cu = absUrl(url, href);
      if (!seen.add(cu)) continue;
      final t = textOf(a);
      if (t.isEmpty) continue;
      chapters.add(Chapter(title: t, url: cu));
    }
    final next = nextPageUrl(doc, url);
    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: title,
        author: author,
        cover: cover,
        intro: intro,
        status: status ?? book.status,
        latest: book.latest,
      ),
      chapters: chapters,
      nextChaptersUrl: next,
    );
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) =>
      parasFrom(doc, 'div#text p, #text p');
}
