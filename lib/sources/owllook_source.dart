// owllook 内置书源：把 https://www.owllook.top/ 包装成爽阅的 [NovelSource]。
//
// 为什么值得内置：owllook 自带榜单、聚合搜索、目录与在线正文解析，
// 全部是服务端渲染的 HTML，纯 HTTP 就能跑，不依赖 QuickJS / WebView。
// 用户「导入书源」之前就有一个能搜、能看、能上榜的源。
//
// 链路（2026-11 实测）：
//   /search?wd=<书名>              → 聚合结果，链接文字「站点--书名--作者」
//   /chapter?url=<源站目录>&novels_name=… → 目录页（hidden #url / #novels_name /
//                                  #content_url + div.book_list li a）
//   /owllook_content?url=…&name=…&chapter_url=…&novels_name=… → 正文
//                                  （div.show-content > div#htmlContent，<br> 分段）
//
// 榜单/首页只给书名 → Book.url 用 /search?wd=<书名>，打开详情时先解析搜索页
// 拿到第一个匹配条目再进目录页（多一跳，但榜单页不用为每本书单独发请求）。
library;

import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'source.dart';

/// owllook 站内地址（书源 id 与展示名分开，便于书源管理里识别）。
const String kOwllookBase = 'https://www.owllook.top';

class OwllookSource extends NovelSource {
  OwllookSource();

  static const String sourceId = 'owllook';

  @override
  String get id => sourceId;

  @override
  String get name => 'owllook';

  @override
  String get baseUrl => kOwllookBase;

  /// 站内搜索页本身就是「按书名定位」，热榜匹配不必真发一次搜索。
  @override
  bool get resolvesByTitle => true;

  @override
  Book? bookFromTitle(String title, {String? author}) {
    final t = title.trim();
    if (t.isEmpty) return null;
    final url = '$kOwllookBase/search?wd=${Uri.encodeQueryComponent(t)}';
    return Book(
      sourceId: sourceId,
      id: url,
      url: url,
      title: t,
      author: author,
    );
  }

  // ---------------------------------------------------------------- 搜索

  @override
  Future<List<Book>> search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final r = await Net.get(
        '$kOwllookBase/search?wd=${Uri.encodeQueryComponent(q)}',
        referer: '$kOwllookBase/');
    if (r.status != 200) throw Exception('owllook 搜索失败（HTTP ${r.status}）');
    return parseOwllookSearch(r.body, q);
  }

  /// 解析 owllook 聚合搜索页（静态纯函数，可离线单测）。
  ///
  /// 结果链接形如 `/chapter?url=…&novels_name=…`，文字是
  /// `站点--书名--作者`（也可能只有两段）。同人/衍生书很多，优先书名段
  /// 与查询词完全一致，其次是包含关系；最多返回 20 条。
  static List<Book> parseOwllookSearch(String html, String query) {
    final exact = <Book>[];
    final fuzzy = <Book>[];
    final seen = <String>{};
    final q = _norm(query);
    // owllook 搜索结果页有 100~250KB，整页 parseHtml 在主 isolate 要上百毫秒
    // —— 搜索是打字热路径，这里只用正则扫 /chapter 链接，零 DOM 构建。
    final re = RegExp(r'''<a[^>]+href="(/chapter\?[^"]+)"[^>]*>([^<]+)</a>''');
    for (final m in re.allMatches(html)) {
      final href = m.group(1)!.replaceAll('&amp;', '&');
      final label =
          m.group(2)!.replaceAll('&amp;', '&').replaceAll('&quot;', '"').trim();
      final parts = label.split('--').map((e) => e.trim()).toList();
      final title = parts.length >= 2 ? parts[1] : parts.first;
      final author = parts.length >= 3 ? parts[2] : null;
      final site = parts.isNotEmpty ? parts.first : '';
      if (title.isEmpty) continue;
      final chapterUrl = '$kOwllookBase$href';
      if (!seen.add(chapterUrl)) continue;
      final b = Book(
        sourceId: sourceId,
        id: chapterUrl,
        url: chapterUrl,
        title: title,
        author: (author == null || author.isEmpty) ? null : author,
        intro: site.isEmpty ? null : '来自 $site',
      );
      final t = _norm(title);
      if (t == q) {
        exact.add(b);
      } else if (q.isNotEmpty && (t.contains(q) || q.contains(t))) {
        fuzzy.add(b);
      }
    }
    return [...exact, ...fuzzy].take(20).toList();
  }

  static String _norm(String s) => s
      .toLowerCase()
      .replaceAll(RegExp(r'[\s·・,，。！!？?、:：;；"“”‘’《》<>【】\[\]()（）\-—_…~～]'), '');

  // ---------------------------------------------------------------- 榜单 / 首页

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [
        RankTab(title: '热门起点榜', url: '$kOwllookBase/md/qidian'),
        RankTab(title: '热门纵横榜', url: '$kOwllookBase/md/zongheng'),
        RankTab(title: '热门搜索榜', url: '$kOwllookBase/md/'),
      ];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final r = await Net.get(tab.url, referer: '$kOwllookBase/');
    if (r.status != 200) throw Exception('owllook 榜单取不到（HTTP ${r.status}）');
    return Paged(items: parseOwllookRank(r.body));
  }

  @override
  Future<List<Book>> fetchHome() async {
    final r = await Net.get('$kOwllookBase/md/', referer: '$kOwllookBase/');
    if (r.status != 200) return const [];
    return parseOwllookRank(r.body).take(8).toList();
  }

  /// 榜单页 → 书名列表（与 hot_board 的解析口径一致：多表合并去重）。
  /// Book.url 指向站内搜索页，详情阶段再解析出真正的目录地址。
  static List<Book> parseOwllookRank(String html) {
    final doc = parseHtml(html);
    final out = <Book>[];
    final seen = <String>{};
    for (final table in doc.querySelectorAll('table.mdui-table')) {
      for (final tr in table.querySelectorAll('tbody tr')) {
        final tds = tr.querySelectorAll('td');
        if (tds.length < 2) continue;
        final a = tds[1].querySelector('a');
        final title = textOf(a).replaceFirst(RegExp(r'\s*(\.{2,}|…+)\s*$'), '').trim();
        if (title.isEmpty || !seen.add(title)) continue;
        final url =
            '$kOwllookBase/search?wd=${Uri.encodeQueryComponent(title)}';
        out.add(Book(
          sourceId: sourceId,
          id: url,
          url: url,
          title: title,
        ));
      }
    }
    return out;
  }

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  // ---------------------------------------------------------------- 详情 / 目录

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final chapterUrl = await _resolveChapterUrl(book);
    final r = await Net.get(chapterUrl, referer: '$kOwllookBase/');
    if (r.status != 200) throw Exception('owllook 目录取不到（HTTP ${r.status}）');
    final parsed = parseOwllookChapters(r.body);
    if (parsed.chapters.isEmpty) throw Exception('owllook 未解析到章节');
    final merged = Book(
      sourceId: sourceId,
      id: chapterUrl,
      url: chapterUrl,
      title: parsed.novelsName.isNotEmpty ? parsed.novelsName : book.title,
      author: book.author,
      cover: book.cover,
      intro: book.intro,
    );
    return BookDetail(book: merged, chapters: parsed.chapters);
  }

  /// 榜单/首页来的书 url 是搜索页：先取第一个匹配条目拿 /chapter 地址。
  Future<String> _resolveChapterUrl(Book book) async {
    final u = book.url;
    if (u.contains('/chapter?')) return u;
    if (u.contains('/search?wd=')) {
      final r = await Net.get(u, referer: '$kOwllookBase/');
      if (r.status == 200) {
        final hits = parseOwllookSearch(r.body, book.title);
        if (hits.isNotEmpty) return hits.first.url;
      }
    }
    throw Exception('owllook 找不到《${book.title}》的目录地址');
  }

  /// 目录页 → 章节列表（静态纯函数，可离线单测）。
  ///
  /// owllook 按源站不同会输出两种目录容器：`div.book_list ul li a`
  /// （相对文件名如 `63431642.html`）或 `div.all-chapter ul.info li a`
  /// （站内绝对路径如 `/chapter/65301/772271.html`）。
  ///
  /// 按 static/novels/js/list.js 的规则拼正文地址：
  /// `#content_url` 为 0/-1 → 用 `#url` 作前缀；为 1 → 不拼接；
  /// 其它值（常见于源站给了绝对 base，如 `https://www.biquge365.net`）→
  /// 该值本身就是前缀。
  static ({String novelsName, List<Chapter> chapters}) parseOwllookChapters(
      String html) {
    final doc = parseHtml(html);
    String val(String id) => doc.getElementById(id)?.attributes['value'] ?? '';
    final chapterUrl = val('url');
    final novelsName = val('novels_name');
    final flag = val('content_url');
    final prefix = flag == '1'
        ? ''
        : (flag == '0' || flag == '-1' || flag.isEmpty)
            ? chapterUrl
            : flag; // 绝对 base（源站自带）
    final chapters = <Chapter>[];
    final seen = <String>{};
    final anchors = <Element>[
      ...doc.querySelectorAll('div.all-chapter a[href]'),
      ...doc.querySelectorAll('div.book_list a[href]'),
      ...doc.querySelectorAll('ul.info a[href]'),
    ];
    for (final a in anchors) {
      final href = a.attributes['href'] ?? '';
      final title = textOf(a);
      if (href.isEmpty || title.isEmpty) continue;
      if (href.startsWith('javascript') || href.startsWith('#')) continue;
      // 只收章节链接：带 title 属性或标题含「第/章/卷/节」，
      // 排除「查看源网址 / 登录 / 我的书架」等导航链接。
      final looksChapter = a.attributes['title'] != null ||
          title.contains('章') ||
          title.contains('卷') ||
          title.contains('节') ||
          RegExp(r'^\d').hasMatch(title);
      if (!looksChapter) continue;
      final target = href.startsWith('http') ? href : prefix + href;
      final contentUrl = '$kOwllookBase/owllook_content?'
          'url=${Uri.encodeQueryComponent(target)}'
          '&name=${Uri.encodeQueryComponent(title)}'
          '&chapter_url=${Uri.encodeQueryComponent(chapterUrl)}'
          '&novels_name=${Uri.encodeQueryComponent(novelsName)}';
      if (!seen.add(contentUrl)) continue;
      chapters.add(Chapter(title: title, url: contentUrl));
    }
    return (novelsName: novelsName, chapters: chapters);
  }

  // ---------------------------------------------------------------- 正文

  /// 正文页 → 段落列表（静态纯函数，可离线单测）。
  static List<String> parseOwllookContent(String html) {
    final doc = parseHtml(html);
    // 两种正文布局：`div#htmlContent`（AMP/采集版）、
    // `div.show-content > div#txt`（标准版，真机第142章实测是这种）。
    final box = doc.querySelector('div#htmlContent') ??
        doc.querySelector('div#txt') ??
        doc.querySelector('div.show-content');
    if (box == null) return const [];
    var s = box.innerHtml;
    s = s.replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n');
    s = s.replaceAll(RegExp(r'</(?:p|div|li|h[1-6])>', caseSensitive: false), '\n');
    final text = parseHtml(s).body?.text ?? '';
    final out = <String>[];
    for (final line in text.split('\n')) {
      final t = line
          .replaceAll('\u3000', ' ')
          .replaceAll('\xa0', ' ')
          .trim();
      if (t.isEmpty) continue;
      // 站点导航/分页按钮文案
      if (t == '上一页' || t == '下一页' || t.startsWith('正文卷')) continue;
      out.add(t);
    }
    return out;
  }

  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    // Net.get 内部为「浏览器检查」页会自动重试多轮（每轮 20s），
    // owllook_content 偶尔会卡在其中一轮 —— 不给阅读器一个硬截止，
    // 用户看到的就是一直转圈。这里 15s 截断，交给阅读器的错误页重试。
    final r = await Net.get(chapter.url, referer: '$kOwllookBase/').timeout(
      const Duration(seconds: 15),
      onTimeout: () => throw Exception('owllook 正文请求超时，点重试再试一次'),
    );
    if (r.status != 200) throw Exception('owllook 正文取不到（HTTP ${r.status}）');
    final paras = parseOwllookContent(r.body);
    if (paras.isEmpty) throw Exception('owllook 正文为空（站点可能改版）');
    return paras;
  }

  /// 基类 fetchChapter 的钩子 —— 本类已整体覆盖，走不到这里。
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  /// owllook 正文页的「下一页」其实是下一章，禁止基类跟随。
  @override
  String? pageNextUrl(Document doc, String currentUrl) => null;

  @override
  bool allowFollow(String currentUrl, String nextUrl) => false;
}
