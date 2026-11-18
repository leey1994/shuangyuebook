// 起点中文网 m.qidian.com 内置书源（纯 HTTP，不用 WebView）。
//
// 为什么走移动站：www.qidian.com 挂了 WAF（返回 202 + probe.js 挑战页，需要
// 浏览器算指纹），纯 HTTP 拿不到正文；m.qidian.com 是服务端渲染，桌面 UA
// 也照常返回整页 HTML（2026-11 实测）。
//
// 可用链路：
//   · 首页推荐 GET /                                  → 各分类书单 li 卡片
//   · 搜索     GET /soushu/<词>.html                  → 结果卡片（书名带 <mark>）
//   · 详情     GET /book/<bookId>/                    → JSON-LD（书名/作者/分类/
//                                                       简介/状态/最新章节/封面）
//   · 目录     GET /book/<bookId>/catalog/            → 全量章节（单页，1MB 级）
//   · 正文     GET /chapter/<bookId>/<cid>/           → <main> 里的 <p> 段落
//
// ⚠️ 只送免费章节：VIP 章服务端只给前 200 字，正文容器带 `lock-mask`，页面上
// 写「登录订阅本章: N点」。这里据实抛错（提示需要订阅），绝不把截断的半截
// 正文当全文交给读者 —— 那会写进离线缓存，变成永久缺文。
//
// 正文没有字体反爬（m 站页面里无 font-face / PUA 码位）；若哪天出现 PUA，
// 解析时直接抛错而不是静默吐乱码。
library;

import 'dart:convert';

import '../dom.dart';
import '../models.dart';
import 'source.dart';

const String kQidianBase = 'https://m.qidian.com';

/// 起点移动站只认移动 UA：桌面 UA 会被 WAF 拦成「跳回 www」的挑战页。
const String kQidianUa =
    'Mozilla/5.0 (Linux; Android 13; Pixel 6) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/126.0.0.0 Mobile Safari/537.36';

class QidianSource extends NovelSource {
  static const String sourceId = 'qidian';

  @override
  String get id => sourceId;

  @override
  String get name => '起点中文网';

  @override
  String get baseUrl => kQidianBase;

  static Book _book(String id, String title,
          {String? author, String? cover, String? intro, String? status}) =>
      Book(
        sourceId: sourceId,
        id: id,
        url: '$kQidianBase/book/$id/',
        title: title,
        author: author,
        cover: cover,
        intro: intro,
        status: status,
      );

  /// `//bookcover.yuewen.com/...` → `https:`；空串当没有。
  static String? _https(String? u) {
    final s = (u ?? '').trim();
    if (s.isEmpty) return null;
    if (s.startsWith('//')) return 'https:$s';
    return s;
  }

  static String? _nil(String s) => s.trim().isEmpty ? null : s.trim();

  // ---------------------------------------------------------------- 首页推荐

  @override
  Future<List<Book>> fetchHome() async {
    final r = await getOk('$kQidianBase/', referer: '$kQidianBase/', userAgent: kQidianUa);
    return parseBookCards(r.body);
  }

  /// 解析 m 站任意一页的书卡（首页书单 / 搜索结果的 `<a data-bid>`）。
  ///
  /// 统一按 `data-bid` + `/book/<id>/` 或 `/chapter/<id>/0/` 定位，标题优先
  /// 取卡内 `h2`（搜索页的 h2 带 `<mark>` 高亮，textOf 自然拼回原名）。
  static List<Book> parseBookCards(String html) {
    final doc = parseHtml(html);
    final out = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[data-bid]')) {
      final id = (a.attributes['data-bid'] ?? '').trim();
      if (id.isEmpty || !seen.add(id)) continue;
      final href = a.attributes['href'] ?? '';
      if (!href.contains('/book/$id') && !href.contains('/chapter/$id/')) {
        continue;
      }
      final h2 = a.querySelector('h2');
      var title = textOf(h2);
      if (title.isEmpty) {
        title = (a.attributes['title'] ?? '').replaceAll('在线阅读', '').trim();
      }
      if (title.isEmpty) continue;
      final img = a.querySelector('img');
      final authorP = a.querySelector('p[class*="Author"]') ??
          a.parent?.querySelector('p');
      final descP = a.querySelector('p[class*="Desc"]');
      out.add(_book(
        id,
        title,
        author: _nil(textOf(authorP)),
        cover: _https(img?.attributes['data-src'] ?? img?.attributes['src']),
        intro: _nil(textOf(descP)),
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------- 搜索

  @override
  Future<List<Book>> search(String query) async {
    final kw = Uri.encodeComponent(query.trim());
    if (kw.isEmpty) return const [];
    final r = await getOk('$kQidianBase/soushu/$kw.html',
        referer: '$kQidianBase/', userAgent: kQidianUa);
    return parseSearch(r.body);
  }

  /// 搜索结果卡片。与首页书卡同构，但多一个简介（p[class*=searchBookDesc]）。
  static List<Book> parseSearch(String html) {
    final doc = parseHtml(html);
    final out = <Book>[];
    final seen = <String>{};
    for (final a in doc.querySelectorAll('a[data-bid]')) {
      final id = (a.attributes['data-bid'] ?? '').trim();
      if (id.isEmpty ||
          !(a.attributes['href'] ?? '').contains('/chapter/$id/0/') ||
          !seen.add(id)) {
        continue;
      }
      final title = textOf(a.querySelector('h2'));
      if (title.isEmpty) continue;
      final tags = [
        for (final p in a.querySelectorAll('div[class*="tags"] p')) textOf(p)
      ].where((s) => s.trim().isNotEmpty).toList();
      final img = a.querySelector('img');
      out.add(_book(
        id,
        title,
        author: _nil(textOf(a.querySelector('p[class*="Author"]'))),
        cover: _https(img?.attributes['data-src'] ?? img?.attributes['src']),
        intro: _nil(textOf(a.querySelector('p[class*="Desc"]'))),
        // 分类 / 完结 / 字数挤在一行，只认前两项里的「完结 / 连载」
        status: tags.where((t) => t == '完结' || t == '连载').firstOrNull,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------- 榜单

  /// 起点官方榜在热榜（HotBoard）里，这里不给书源站内榜。
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
      Booklist(title: entry.title, paragraphs: const [], books: const []);

  // ---------------------------------------------------------------- 详情 + 目录

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final r = await getOk(book.url, referer: '$kQidianBase/', userAgent: kQidianUa);
    final info = parseDetailInfo(r.body, book);
    final cat = await getOk('$kQidianBase/book/${book.id}/catalog/',
        referer: book.url, userAgent: kQidianUa);
    return BookDetail(
      book: info,
      chapters: parseCatalog(cat.body, book.id),
      nextChaptersUrl: null,
    );
  }

  /// 详情页信息：优先 JSON-LD（结构稳定、字段齐全），缺失再回落到 DOM。
  static Book parseDetailInfo(String html, Book fallback) {
    final doc = parseHtml(html);
    Map<String, dynamic>? ld;
    for (final s in doc.querySelectorAll('script[type="application/ld+json"]')) {
      try {
        final o = jsonDecode(s.text);
        final graph = (o is Map && o['@graph'] is List) ? o['@graph'] : null;
        if (graph is List) {
          for (final g in graph) {
            if (g is Map && g['@type'] == 'Book') {
              ld = g.cast<String, dynamic>();
              break;
            }
          }
        } else if (o is Map && o['@type'] == 'Book') {
          ld = o.cast<String, dynamic>();
        }
        if (ld != null) break;
      } catch (_) {
        // 不是 JSON 就跳过，别让一个坏脚本拖死整页
      }
    }

    String ldStr(String k) => (ld?[k]?.toString() ?? '').trim();
    String prop(String name) {
      final list = ld?['additionalProperty'];
      if (list is! List) return '';
      for (final e in list) {
        if (e is Map && e['name'] == name) return '${e['value']}'.trim();
      }
      return '';
    }

    final author = ld?['author'];
    final title = ldStr('name');
    final domTitle =
        textOf(doc.querySelector('h1[class*="header-detail__title"]'));
    final status = prop('连载状态');
    final latest = prop('最新章节');
    return Book(
      sourceId: fallback.sourceId,
      id: fallback.id,
      url: fallback.url,
      title: title.isNotEmpty ? title : (domTitle.isNotEmpty ? domTitle : fallback.title),
      author: _nil(author is Map ? '${author['name'] ?? ''}' : '') ??
          fallback.author,
      cover: _https(ldStr('image')) ?? fallback.cover,
      intro: _nil(ldStr('description')) ?? fallback.intro,
      status: _nil(status) ?? fallback.status,
      latest: _nil(latest) ?? fallback.latest,
    );
  }

  /// 目录页：`<a class="_chapterItem_..." href="//m.qidian.com/chapter/<bid>/<cid>/">`
  /// 内 `<h2>` 是章名；`/chapter/<bid>/0/` 那种「最新章节」条目不收录。
  static List<Chapter> parseCatalog(String html, String bookId) {
    final doc = parseHtml(html);
    final out = <Chapter>[];
    final seen = <String>{};
    final re = RegExp('/chapter/$bookId/' r'(\d+)/');
    for (final a in doc.querySelectorAll('a[data-cid]')) {
      // 只认章节条目：页面顶部的「最新章节」是同一章的快捷入口，
      // 先收到它会把整个目录倒序（首章变最新章节）。
      if (!(a.attributes['class'] ?? '').contains('_chapterItem')) continue;
      final href = a.attributes['href'] ?? '';
      final m = re.firstMatch(href);
      if (m == null) continue;
      final cid = m.group(1)!;
      if (cid == '0' || !seen.add(cid)) continue;
      var title = textOf(a.querySelector('h2'));
      if (title.isEmpty) {
        title = (a.attributes['title'] ?? '')
            .replaceAll('在线阅读', '')
            .replaceFirst(RegExp('^\\s*${RegExp.escape(bookId)}\\s*'), '')
            .trim();
      }
      if (title.isEmpty) title = '第 $cid 章';
      out.add(Chapter(
        title: title,
        url: '$kQidianBase/chapter/$bookId/$cid/',
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------- 正文

  /// 基类的 HTML 正文抓取不走（正文取法见 [fetchChapter]），给空实现。
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    final r = await getOk(chapter.url, referer: detail.book.url, userAgent: kQidianUa);
    return parseChapter(r.body);
  }

  /// 正文页：`<main class="... [lock-mask]">` 里每段一个 `<p>`。
  ///
  /// `lock-mask` = VIP 章被截断（服务端只给开头几百字），抛错而不是返回半截。
  static List<String> parseChapter(String html) {
    final doc = parseHtml(html);
    final main = doc.querySelector('main');
    if (main == null) throw Exception('起点正文解析失败（结构已变）');

    final cls = main.attributes['class'] ?? '';
    final text = textOf(main);
    if (cls.contains('lock-mask') || text.contains('登录订阅本章')) {
      throw Exception('起点这章是 VIP 章节，需要登录订阅；免费章节可以直接读');
    }

    final paras = <String>[];
    for (final p in main.querySelectorAll('p')) {
      final t = textOf(p).replaceAll('\u3000', '').trim();
      if (t.isNotEmpty) paras.add(t);
    }
    if (paras.isEmpty) {
      final t = text.replaceAll('\u3000', '').trim();
      if (t.isNotEmpty) paras.add(t);
    }
    if (paras.isEmpty) throw Exception('起点正文为空（该章可能已下架）');

    // 站点若改用字体反爬，说明映射对我们未知 —— 宁可报错也不吐乱码。
    for (final p in paras) {
      if (p.runes.any((r) => r >= 0xE000 && r <= 0xF8FF)) {
        throw Exception('起点正文出现字体反爬码位，当前版本还不认识这套字体');
      }
    }
    return cleanParas(paras);
  }
}
