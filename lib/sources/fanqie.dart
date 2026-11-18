// 番茄小说 fanqienovel.com 内置书源（纯 HTTP，不用 WebView）。
//
// 可用的链路（2026-11 实测，全部不需要登录 / 签名）：
//   · 首页推荐   GET /                                   → __INITIAL_STATE__.home
//   · 详情 + 目录 GET /page/<bookId>                      → .page（书名 / 作者 / 简介 /
//                                                          封面 / 章节表 / 总章数）
//   · 全量目录   GET /api/reader/directory/detail?bookId= → data.allItemIds +
//                                                          data.chapterListWithVolume
//   · 正文       GET /reader/<itemId>                     → .reader.chapterData.content
//
// 正文、书名、章名都不是明文：站点把常用字替换成 PUA 私有区码位（U+E3E8 起），
// 再下发 woff2 字体让浏览器画回真字。字体是全局固定的一份
// （dc027189e0ba4cd.woff2），映射内联在 fanqie_font.dart，纯 HTTP 也能读全文。
//
// 搜索不可用：站内搜索接口 /api/author/search/search_book/v1 要 msToken + a_bogus
// 签名，非浏览器请求一律返回 200 + 空响应体（响应头带 Bdturing-Verify，滑块人机
// 验证）。纯 HTTP 绕不过，所以 search() 明确抛错，让用户看到「需要人机验证」，
// 而不是静默返回空结果、误以为站里没这本书。
library;

import 'dart:convert';

import '../dom.dart';
import '../models.dart';
import 'fanqie_font.dart';
import 'source.dart';

const String kFanqieBase = 'https://fanqienovel.com';

class FanqieSource extends NovelSource {
  static const String sourceId = 'fanqie';

  @override
  String get id => sourceId;

  @override
  String get name => '番茄小说';

  @override
  String get baseUrl => kFanqieBase;

  // ---------------------------------------------------------------- 首页推荐

  @override
  Future<List<Book>> fetchHome() async {
    final r = await getOk('$kFanqieBase/', referer: '$kFanqieBase/');
    final home = initialState(r.body)?['home'];
    if (home is! Map) return const [];
    final out = <Book>[];
    final seen = <String>{};
    for (final key in const ['boyList', 'girlList', 'editorList', 'weekList']) {
      final list = home[key];
      if (list is! List) continue;
      for (final e in list) {
        if (e is! Map) continue;
        final b = _bookFromJson(e);
        if (b == null) continue;
        if (!seen.add(b.id)) continue;
        out.add(b);
      }
    }
    return out;
  }

  /// 首页卡片 / 榜单条目：bookId / bookName / author / abstract / thumbUri。
  Book? _bookFromJson(Map e) => _bookOf(
        e['bookId'],
        e['bookName'],
        author: e['author'],
        cover: e['thumbUrl'] ?? e['thumbUri'],
        intro: e['abstract'],
      );

  Book? _bookOf(Object? bookId, Object? name,
      {Object? author, Object? cover, Object? intro, Object? latest}) {
    final id = (bookId?.toString() ?? '').trim();
    final title = decodeFanqieText((name?.toString() ?? '').trim());
    if (id.isEmpty || title.isEmpty) return null;
    return Book(
      sourceId: sourceId,
      id: id,
      url: '$kFanqieBase/page/$id',
      title: title,
      author: _strOrNull(decodeFanqieText(author?.toString() ?? '')),
      cover: _strOrNull(cover?.toString() ?? ''),
      intro: _strOrNull(decodeFanqieText(intro?.toString() ?? '')),
      latest: _strOrNull(decodeFanqieText(latest?.toString() ?? '')),
    );
  }

  static String? _strOrNull(String s) => s.trim().isEmpty ? null : s.trim();

  // ---------------------------------------------------------------- 搜索

  /// 番茄站内搜索需要滑块人机验证，纯 HTTP 拿不到结果。
  ///
  /// 抛错而不是返回空：聚合搜索 / 热榜匹配里单源失败是被 catch 掉的，
  /// 用户会看到「番茄小说：…」这种带原因的提示，而不是「没搜到」。
  @override
  Future<List<Book>> search(String query) async {
    throw Exception('番茄站内搜索需要人机验证（Bdturing 滑块），纯 HTTP 不可用；'
        '请从番茄首页推荐或书页进入');
  }

  // ---------------------------------------------------------------- 榜单

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
    final r = await getOk(book.url, referer: '$kFanqieBase/');
    final detail = parseDetail(r.body, book);
    if (detail.chapters.isNotEmpty) return detail;
    // 详情页偶尔只给前 N 章（chapterList 为空但有 chapterTotal）：
    // 走目录接口拿全量，失败就沿用详情页已有的部分。
    try {
      final all = await _fetchAllChapters(book.id);
      if (all.isNotEmpty) {
        return BookDetail(book: detail.book, chapters: all);
      }
    } catch (_) {}
    return detail;
  }

  /// 解析详情页（纯函数，可离线单测）。
  static BookDetail parseDetail(String html, Book book) {
    final st = initialState(html);
    final page = st?['page'];
    if (page is! Map) throw Exception('番茄详情页解析失败（结构已变）');

    final chapters = chaptersFromState(st!);

    final creation = (page['creationStatus']?.toString() ?? '').trim();
    final status = switch (creation) {
      '0' => '连载',
      '1' => '完结',
      _ => null,
    };

    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: _strOrNull(decodeFanqieText(page['bookName']?.toString() ?? '')) ??
            book.title,
        author: _strOrNull(decodeFanqieText(page['author']?.toString() ?? '')) ??
            book.author,
        cover: _strOrNull(page['thumbUrl']?.toString() ??
                page['thumbUri']?.toString() ??
                '') ??
            book.cover,
        intro: _strOrNull(decodeFanqieText(page['abstract']?.toString() ?? '')) ??
            book.intro,
        status: status ?? book.status,
        latest: _strOrNull(
                decodeFanqieText(page['lastChapterTitle']?.toString() ?? '')) ??
            book.latest,
      ),
      chapters: chapters,
      nextChaptersUrl: null,
    );
  }

  /// .page.chapterListWithVolume：`[[{itemId,title}, …], …]` 按卷分组。
  ///
  /// 卷不单独成条（在线源目录是平铺的），卷名丢掉即可 —— 章名里本来就有
  /// 「第 N 章」，用户按顺序读不受影响。
  static List<Chapter> chaptersFromState(Map st) {
    final out = <Chapter>[];
    final seen = <String>{};
    final vols = st['page']?['chapterListWithVolume'];
    if (vols is! List) return out;
    for (final vol in vols) {
      if (vol is! List) continue;
      for (final c in vol) {
        if (c is! Map) continue;
        final itemId = (c['itemId']?.toString() ?? '').trim();
        if (itemId.isEmpty || !seen.add(itemId)) continue;
        final title = decodeFanqieText((c['title']?.toString() ?? '').trim());
        out.add(Chapter(
          title: title.isEmpty ? itemId : title,
          url: '$kFanqieBase/reader/$itemId',
        ));
      }
    }
    return out;
  }

  /// 目录接口：allItemIds 只有 id，章名在 chapterListWithVolume 里。
  Future<List<Chapter>> _fetchAllChapters(String bookId) async {
    final r = await getOk(
      '$kFanqieBase/api/reader/directory/detail?bookId=$bookId',
      referer: '$kFanqieBase/page/$bookId',
    );
    if (r.status != 200 || r.body.trim().isEmpty) return const [];
    final root = jsonDecode(r.body);
    if (root is! Map) return const [];
    final data = root['data'];
    if (data is! Map) return const [];

    // 章名按 id 归档：两个字段的遍历顺序不一定一致，按 id 对齐最稳。
    final names = <String, String>{};
    final vols = data['chapterListWithVolume'];
    if (vols is List) {
      for (final vol in vols) {
        if (vol is! List) continue;
        for (final c in vol) {
          if (c is! Map) continue;
          final id = (c['itemId']?.toString() ?? '').trim();
          if (id.isEmpty) continue;
          names[id] = decodeFanqieText((c['title']?.toString() ?? '').trim());
        }
      }
    }

    final ids = data['allItemIds'];
    if (ids is! List) return const [];
    final out = <Chapter>[];
    for (final raw in ids) {
      final id = (raw?.toString() ?? '').trim();
      if (id.isEmpty) continue;
      final title = names[id];
      out.add(Chapter(
        title: (title == null || title.isEmpty) ? id : title,
        url: '$kFanqieBase/reader/$id',
      ));
    }
    return out;
  }

  /// 基类的 HTML 正文抓取不走（正文在 __INITIAL_STATE__ 里），这里给空实现。
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  // ---------------------------------------------------------------- 正文

  /// 正文在 .reader.chapterData.content 里，是 `<p>` 分段 + PUA 码位的 HTML。
  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    final r = await getOk(chapter.url, referer: detail.book.url);
    return parseChapterBody(r.body);
  }

  /// 解析正文页（纯函数，可离线单测）。
  static List<String> parseChapterBody(String page) {
    final st = initialState(page);
    final data = st?['reader']?['chapterData'];
    if (data is! Map) throw Exception('番茄正文解析失败（结构已变）');
    final html = data['content']?.toString() ?? '';
    if (html.trim().isEmpty) {
      throw Exception('番茄正文为空（该章可能已下架或需要登录）');
    }
    final paras = parseChapterContent(html);
    if (paras.isEmpty) throw Exception('番茄正文解析失败（无段落）');
    return cleanParas(paras);
  }

  static List<String> parseChapterContent(String html) {
    final doc = parseHtml('<div id="fanqie-body">$html</div>');
    final root = doc.querySelector('#fanqie-body');
    final out = <String>[];
    if (root == null) return out;
    for (final p in root.querySelectorAll('p')) {
      final t = decodeFanqieText(textOf(p));
      if (t.trim().isNotEmpty) out.add(t);
    }
    if (out.isEmpty) {
      final t = decodeFanqieText(textOf(root));
      if (t.trim().isNotEmpty) out.add(t);
    }
    return out;
  }

  // ---------------------------------------------------------------- 页面状态

  /// `window.__INITIAL_STATE__={…}` 不是严格 JSON：对象后还跟着 `;` 和包装代码，
  /// 值里偶有裸 `undefined`。这里按括号配对截出对象再修补。
  static Map<String, dynamic>? initialState(String html) {
    const marker = '__INITIAL_STATE__=';
    final i = html.indexOf(marker);
    if (i < 0) return null;
    final start = html.indexOf('{', i);
    if (start < 0) return null;
    final end = _matchBraces(html, start);
    if (end < 0) return null;
    var raw = html.substring(start, end);
    // 裸 undefined 一律换 null（不是删掉：`[1,undefined]` 删了会少一个元素）。
    // 前后有引号/标识符字符的不动，避免误伤字符串内容。
    raw = raw.replaceAll(RegExp(r'(?<![\w$"])undefined\b'), 'null');
    try {
      final o = jsonDecode(raw);
      return o is Map<String, dynamic> ? o : null;
    } catch (_) {
      return null;
    }
  }

  /// 字符串感知的括号配对：返回配平的 `}` 之后的下标（不含），失败 -1。
  static int _matchBraces(String s, int open) {
    var depth = 0;
    var inStr = false;
    var quote = '';
    for (var i = open; i < s.length; i++) {
      final c = s[i];
      if (inStr) {
        if (c == '\\') {
          i++;
          continue;
        }
        if (c == quote) inStr = false;
        continue;
      }
      if (c == '"' || c == "'") {
        inStr = true;
        quote = c;
        continue;
      }
      if (c == '{') {
        depth++;
      } else if (c == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
    }
    return -1;
  }
}
