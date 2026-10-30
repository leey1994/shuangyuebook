// 在线聚合：多源并发搜索（超时 / 错误隔离 / 限流 / 结果归一化）。
//
// 搜索数据流：
//   关键词 → 每源 searchUrl 模板渲染 → HTTP 请求（可 POST）
//          → AnalyzeRule(响应) + SearchRule 解析 → [SearchBook]
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;

import 'analyze_rule.dart';
import 'analyze_url.dart';
import 'cookie_jar.dart';
import 'http_client.dart';
import 'js_engine.dart';
import 'models.dart';
import 'online_book_service.dart';
import 'parse_worker.dart';
import 'source_store.dart';
import 'source_vars.dart';
import 'webview_engine.dart';

/// 单源搜索的结果（或错误）。
class SourceSearchResult {
  SourceSearchResult({
    required this.source,
    this.books = const [],
    this.error,
    this.elapsedMs = 0,
  });

  final BookSource source;
  final List<SearchBook> books;
  final String? error;
  final int elapsedMs;

  bool get ok => error == null;
}

/// 归一化搜索文本（去空白 / 全角空格，小写）。
String normalizeSearchText(String? s) =>
    (s ?? '').trim().replaceAll(RegExp(r'[\s\u3000]+'), '').toLowerCase();

/// 多源搜索结果合并键：书名 + 作者（去空白、忽略常见装饰后缀）。
///
/// 同键的书视为「同一本书的不同来源」，在搜索页合并为一条，
/// 详情页可在各来源间切换。
String bookMergeKey(SearchBook b) {
  var name = normalizeSearchText(b.name);
  // 去掉结尾的装饰括号（如「（大结局）」「【完结】」），增强跨源匹配
  name = name.replaceAll(RegExp(r'[（(【\[][^（(【\[]*[）)】\]]$'), '');
  return '$name|${normalizeSearchText(b.author)}';
}

/// 搜索相关性分数（越高越相关）——用于搜索结果与换源候选排序。
///
/// 规则：书名完全一致 > 书名前缀（与关键词越接近越前）> 书名包含 >
/// 作者匹配 > 无关（保底 100 分，让完全不沾边的书沉底）。
int bookRelevanceScore(SearchBook b, String key) {
  final k = normalizeSearchText(key);
  if (k.isEmpty) return 0;
  final name = normalizeSearchText(b.name);
  final author = normalizeSearchText(b.author);
  var score = 0;
  if (name.isNotEmpty) {
    if (name == k) {
      score = 1000;
    } else if (name.startsWith(k)) {
      score = 820 - (name.length - k.length).clamp(0, 200).toInt();
    } else if (name.contains(k)) {
      final pos = name.indexOf(k);
      score = 650 - pos.clamp(0, 60).toInt();
    }
  }
  if (author.isNotEmpty) {
    if (author == k && score < 560) {
      score = 560;
    } else if (author.contains(k) && score < 480) {
      score = 480;
    }
  }
  if (score == 0) score = 100;
  return score;
}

/// 发现页的一个分类（书源 exploreUrl 的一行）。
class ExploreCategory {
  const ExploreCategory({required this.title, required this.url});

  /// 分类名（如「玄幻」「排行榜」）。
  final String title;

  /// 该分类的地址（已渲染模板变量）。
  final String url;
}

/// 单源「发现页」抓取结果。
class SourceExploreResult {
  const SourceExploreResult({
    required this.source,
    this.books = const [],
    this.error,
    this.elapsedMs = 0,
  });

  final BookSource source;
  final List<SearchBook> books;
  final String? error;
  final int elapsedMs;
}

/// 书源「发现页」：解析 exploreUrl 分类并抓取分类下的书单。
///
/// 用户反馈（社区最期待的功能之一）：希望有「发现页」直接逛书，
/// 而不是每次都先想好关键词去搜。这里实现 Legado 的 `exploreUrl` 规则：
///
/// ```
/// 玄幻::https://site/list/xuanhuan/{{page}}.html
/// 排行::https://site/rank/all/{{page}}.html   // 可用 {{page}} 占位
/// ```
///
/// 多分类之间用换行分隔；标题与地址用 `::` 分隔（也兼容 `,`）。
///
/// 搜索结果解析明细：把「静默 0 结果」变成可解释的失败原因。
class SearchParseResult {
  const SearchParseResult(
    this.books, {
    this.rows = 0,
    this.noName = 0,
    this.noUrl = 0,
  });

  final List<SearchBook> books;

  /// bookList 规则命中的行数。
  final int rows;

  /// 书名规则解析失败被跳过的行数。
  final int noName;

  /// 书籍页链接规则解析失败被跳过的行数（多数是依赖 JS 的 bookUrl）。
  final int noUrl;
}

/// 多源搜索聚合器。
class OnlineRepo {
  OnlineRepo({
    required this.store,
    SourceHttpClient? client,
    this.concurrency = 8,
    this.requestTimeout = const Duration(seconds: 15),
    this.perSourceTimeout = const Duration(seconds: 60),
    bool? offthreadParse,
  })  : _client = client ?? SourceHttpClient(),
        _injectedClient = client != null,
        offthreadParse = offthreadParse ?? (client == null);

  final SourceStore store;
  final SourceHttpClient _client;

  /// 外部注入的 mock / 定制客户端：不可能跨 isolate 传，这类仓库一律主线程解析。
  final bool _injectedClient;

  /// 是否把「取页 + 规则解析 + JS」丢给 [ParseWorkerPool] 分身。
  /// 默认开；分身内部构造仓库时必须传 false（否则会递归起孙分身）。
  final bool offthreadParse;

  /// 全局并发上限。
  final int concurrency;

  /// 单次 HTTP 请求超时（含挂起补网的 ajax）。
  final Duration requestTimeout;

  /// 单源总预算：聚合成百上千次 `java.ajax` 的源（墨阅聚合、大灰狼聚合）
  /// 需要更长时间；超预算后放弃该源，不阻塞其他源。
  final Duration perSourceTimeout;

  final Map<String, RateGate> _gates = {};

  RateGate _gateFor(BookSource s) =>
      _gates.putIfAbsent(s.bookSourceUrl, () => RateGate(s.concurrentRate));

  // ---------- 离线分身（后台 isolate）分流 ----------

  /// 这次能不能丢给分身：注入了 mock 客户端（不可跨 isolate）、源需要
  /// 隐藏 WebView、或分身已禁用 / 起不来的，一律留在主线程。
  bool _useOffthread(BookSource s) =>
      offthreadParse &&
      !_injectedClient &&
      !sourceNeedsMainParse(s) &&
      !ParseWorkerPool.I.disabled;

  /// 搜索丢分身。返回 null = 没走成分身，调用方落回主线程原路。
  Future<SourceSearchResult?> offthreadSearch(
    BookSource source,
    String key, {
    int page = 1,
    bool brief = false,
  }) async {
    final r = await _submitSearch(source, key, page: page, brief: brief);
    if (r == null) return null;
    if (r['status'] == 'defer') {
      // 真机诊断点：分身里 QuickJS 起不来而这源的搜索依赖 JS → 主线程复探
      debugPrint('[书源分身]「${source.bookSourceName}」JS 仅主线程可用 → 主线程复探');
      return null;
    }
    applyOffthreadSideEffects(r, source.bookSourceUrl);
    return SourceSearchResult(
      source: source,
      books: [
        for (final b in (r['books'] as List? ?? const []))
          if (b is Map) SearchBook.fromJson(Map<String, dynamic>.from(b)),
      ],
      error: r['status'] == 'err' ? (r['error'] as String? ?? '搜索失败') : null,
      elapsedMs: (r['ms'] as num?)?.toInt() ?? 0,
    );
  }

  /// 体检用：只要结论（活没活、为什么），不把书目搬回主 isolate。
  /// 返回 null = 交回主线程探测（分身不可用，或这源的 JS 只有主线程起得来）。
  Future<Map<String, dynamic>?> offthreadProbe(
      BookSource source, String key) async {
    final r = await _submitSearch(source, key, brief: true);
    if (r == null) return null;
    if (r['status'] == 'defer') {
      debugPrint('[书源分身]「${source.bookSourceName}」JS 仅主线程可用 → 主线程复探');
      return null;
    }
    applyOffthreadSideEffects(r, source.bookSourceUrl);
    return r;
  }

  Future<Map<String, dynamic>?> _submitSearch(
    BookSource source,
    String key, {
    int page = 1,
    bool brief = false,
  }) async {
    final dirs = await workerAppDirs();
    if (dirs == null) return null;
    return ParseWorkerPool.I.submit({
      'kind': 'search',
      'source': source.toJson(),
      'key': key,
      'page': page,
      'brief': brief,
      'files': dirs.files,
      'cache': dirs.cache,
      'timeoutSecs': perSourceTimeout.inSeconds,
    });
  }

  /// 发现页书单丢分身（排行页 / 首页推荐聚合的热路径）。
  Future<SourceExploreResult?> offthreadExplore(
    BookSource source,
    ExploreCategory category, {
    int page = 1,
  }) async {
    final dirs = await workerAppDirs();
    if (dirs == null) return null;
    final r = await ParseWorkerPool.I.submit({
      'kind': 'explore',
      'source': source.toJson(),
      'catTitle': category.title,
      'catUrl': category.url,
      'page': page,
      'files': dirs.files,
      'cache': dirs.cache,
      'timeoutSecs': perSourceTimeout.inSeconds,
    });
    if (r == null || r['status'] == 'defer') return null;
    applyOffthreadSideEffects(r, source.bookSourceUrl);
    return SourceExploreResult(
      source: source,
      books: [
        for (final b in (r['books'] as List? ?? const []))
          if (b is Map) SearchBook.fromJson(Map<String, dynamic>.from(b)),
      ],
      error: r['status'] == 'err' ? (r['error'] as String? ?? '发现页抓取失败') : null,
      elapsedMs: (r['ms'] as num?)?.toInt() ?? 0,
    );
  }

  /// 发现页分类表（`exploreUrl` 是 JS 脚本的那种）丢分身：跑脚本 + 补网取页
  /// 都是主线程上的同步砖头。返回 null = 交回主线程。
  Future<List<ExploreCategory>?> offthreadCategories(BookSource source) async {
    final dirs = await workerAppDirs();
    if (dirs == null) return null;
    final r = await ParseWorkerPool.I.submit({
      'kind': 'categories',
      'source': source.toJson(),
      'files': dirs.files,
      'cache': dirs.cache,
      'timeoutSecs': 25,
    });
    if (r == null || r['status'] == 'defer') return null;
    final cats = r['cats'];
    if (cats is! List) return const [];
    return [
      for (final c in cats)
        if (c is Map)
          ExploreCategory(title: '${c['title']}', url: '${c['url']}'),
    ];
  }

  /// P0：书源 JS 环境（同一次搜索/发现操作共享 [session]）。
  static JsEnv jsEnvFor(BookSource source, JsSession session) => JsEnv(
        scopeKey: source.bookSourceUrl,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        sourceHeader: source.header,
        sourceJson: source.jsSourceFields,
        jsLib: source.jsLib,
        session: session,
        // legado：java.getCookie(url[, key]) 读 Cookie 仓库（登录态/会话跨请求）
        getCookie: (tag, key) => LegadoCookieJar.I.getFor(tag, key),
      );

  /// 挂起补网：抓取目标写入会话缓存后重跑脚本。
  Future<void> _resolveSuspend(
    BookSource source,
    JsSession session,
    JsSuspendException e,
  ) async {
    if (e.kind == 'webview') {
      // legado `java.webView(url)` = WebView 打开后返回渲染 HTML。
      // 探索/搜索脚本（七猫聚合、起点、智能书库…）都靠它拿 JS 生成的内容。
      var html = '';
      try {
        html = await WebViewEngine.instance.fetchRenderedHtml(url: e.target);
      } catch (_) {
        html = '';
      }
      if (html.trim().isEmpty && WebViewEngine.supported) {
        try {
          final resp = await _client.get(
            e.target,
            headers: _mergeHeaders(source, e.headers),
            timeout: requestTimeout,
            retries: 0,
          ).timeout(const Duration(seconds: 6));
          if (resp.ok) html = resp.body;
        } catch (_) {
          html = '';
        }
      }
      session.webViewCache[e.target] = html;
      return;
    }
    final key = JsBridge.ajaxKey(e.method, e.target, e.body);
    try {
      final headers = _mergeHeaders(source, e.headers);
      final resp = e.method == 'GET'
          ? await _client.get(
              e.target,
              headers: headers,
              timeout: requestTimeout,
              retries: 0,
            )
          : await _client.post(
              e.target,
              headers: headers,
              body: e.body,
              timeout: requestTimeout,
              retries: 0,
            );
      session.ajaxCache[key] = resp.ok ? resp.body : '';
      session.ajaxMeta[key] = {
        'code': resp.statusCode,
        'url': resp.finalUrl.isEmpty ? e.target : resp.finalUrl,
        'headers': resp.headers,
      };
    } catch (_) {
      session.ajaxCache[key] = '';
    }
  }

  /// 对所有启用的书源并发搜索。
  ///
  /// 每个源完成（成功或失败）时回调 [onSourceDone]；返回按书源顺序排列的完整结果。
  Future<List<SourceSearchResult>> searchAll(
    String key, {
    int page = 1,
    void Function(SourceSearchResult r)? onSourceDone,
  }) async {
    final sources = store.enabled;
    final results = <SourceSearchResult>[];
    if (sources.isEmpty) return results;

    var next = 0;
    final total = sources.length;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= total) return;
        final r = await searchOne(sources[i], key, page: page);
        results.add(r);
        onSourceDone?.call(r);
      }
    }

    final n = concurrency.clamp(1, total);
    await Future.wait(List.generate(n, (_) => worker()));

    final order = <String, int>{
      for (var i = 0; i < sources.length; i++) sources[i].bookSourceUrl: i,
    };
    results.sort(
      (a, b) => (order[a.source.bookSourceUrl] ?? 0).compareTo(
        order[b.source.bookSourceUrl] ?? 0,
      ),
    );
    return results;
  }

  /// 单源搜索（错误隔离在内部消化；P0：JS 挂起自动补网重跑）。
  ///
  /// 默认整条链在后台分身里跑（见 [ParseWorkerPool]）：几十个源同时回结果时，
  /// 主 isolate 不再被一块块几十毫秒的 HTML→XML→规则→QuickJS 砖头拍住。
  /// [brief] 只要「有没有结果」的计数（体检用），不往回搬书目数据。
  Future<SourceSearchResult> searchOne(
    BookSource source,
    String key, {
    int page = 1,
    bool brief = false,
  }) async {
    if (_useOffthread(source)) {
      final r =
          await offthreadSearch(source, key, page: page, brief: brief);
      if (r != null) return r;
      // 分身不可用 / 这源的脚本只有主线程起得来：继续走下面的原路
    }
    final session = JsSession();
    final env = jsEnvFor(source, session);
    try {
      return await runWithJsSession(
        session,
        () =>
            _searchOneInner(source, key, page: page, js: env, session: session),
        (e) => _resolveSuspend(source, session, e),
      ).timeout(perSourceTimeout);
    } on TimeoutException {
      return SourceSearchResult(
        source: source,
        error: '超时：单源超过 ${perSourceTimeout.inSeconds}s',
        elapsedMs: perSourceTimeout.inMilliseconds,
      );
    }
  }

  /// 单源搜索主体（供挂起重跑整体重放）。
  Future<SourceSearchResult> _searchOneInner(
    BookSource source,
    String key, {
    required int page,
    required JsEnv js,
    required JsSession session,
  }) async {
    final started = DateTime.now();
    int elapsed() => DateTime.now().difference(started).inMilliseconds;
    try {
      final rawUrl = source.searchUrl;
      if (rawUrl == null || rawUrl.trim().isEmpty) {
        throw const FormatException('未配置搜索地址（searchUrl）');
      }
      final req = buildRequest(rawUrl, source.bookSourceUrl, {
        'key': key,
        'page': page,
      }, js: js);
      // 纯 JS 构建的搜索入口且引擎不可用：明确报错，而不是拿一段脚本文本去请求。
      final lowUrl = req.url.toLowerCase();
      if ((lowUrl.contains('<js') || lowUrl.contains('@js:')) &&
          !JsBridge.available) {
        throw const FormatException('搜索入口由 JS 脚本构建（JS 引擎不可用，可手动替换搜索地址）');
      }
      if (req.url.trim().isEmpty) {
        final err = JsBridge.lastError;
        throw FormatException('搜索地址渲染为空（searchUrl 可能由 JS 表达式构建）'
            '${err == null || err.isEmpty ? '' : '：$err'}');
      }
      final headers = _mergeHeaders(source, req.options);
      final method = (req.options['method']?.toString() ?? 'GET').toUpperCase();
      final charset = req.options['charset']?.toString();

      await _gateFor(source).waitSlot();

      await _runPreRequests(source, headers, key, page);

      SourceResponse resp;
      if (method == 'POST') {
        final bodyRaw = req.options['body'];
        final body = bodyRaw == null
            ? ''
            : (bodyRaw is String ? bodyRaw : jsonEncode(bodyRaw));
        resp = await _client.post(
          req.url,
          headers: headers,
          body: body,
          charset: charset,
          timeout: requestTimeout,
        );
      } else {
        resp = await _client.get(
          req.url,
          headers: headers,
          charset: charset,
          timeout: requestTimeout,
        );
      }
      if (!resp.ok) {
        throw SourceHttpException('HTTP ${resp.statusCode}');
      }
      final parsed = parseSearchPageDetailed(source, resp.body,
          js: js,
          // 用最终地址（可能经历 30x）作为相对链接的解析基准
          pageUrl: resp.finalUrl.isEmpty ? req.url : resp.finalUrl);
      if (parsed.books.isEmpty && parsed.rows > 0) {
        final reason = parsed.noUrl > 0
            ? '${parsed.noUrl} 条结果无法解析书籍链接（bookUrl 规则可能依赖 JS 脚本）'
            : '${parsed.rows} 条结果无法解析书名（规则与页面不匹配）';
        return SourceSearchResult(
          source: source,
          error: reason,
          elapsedMs: elapsed(),
        );
      }
      return SourceSearchResult(
        source: source,
        books: parsed.books,
        elapsedMs: elapsed(),
      );
    } on SourceHttpException catch (e) {
      return SourceSearchResult(
        source: source,
        error: e.message,
        elapsedMs: elapsed(),
      );
    } on TimeoutException {
      return SourceSearchResult(
        source: source,
        error: '超时',
        elapsedMs: elapsed(),
      );
    } catch (e) {
      if (e is JsSuspendException) rethrow; // 交给外层补网重跑
      return SourceSearchResult(
        source: source,
        error: '解析失败：$e',
        elapsedMs: elapsed(),
      );
    }
  }

  /// 解析搜索结果页 → [SearchBook] 列表（旧签名，明细见 [parseSearchPageDetailed]）。
  List<SearchBook> parseSearchPage(BookSource source, String body) =>
      parseSearchPageDetailed(source, body).books;

  /// 解析搜索结果页，同时给出被跳过条目的计数（用于失败归因）。
  SearchParseResult parseSearchPageDetailed(BookSource source, String body,
      {JsEnv? js, String? pageUrl}) {
    final rule = source.searchRule;
    if (rule == null) return const SearchParseResult([]);
    final listRule = (rule.bookList ?? '').trim();
    if (listRule.isEmpty) return const SearchParseResult([]);

    final engine = AnalyzeRule(body,
        baseUrl: pageUrl ?? source.bookSourceUrl, js: js);
    final items = engine.getRawList(listRule);
    final books = <SearchBook>[];
    var rows = 0;
    var noName = 0;
    var noUrl = 0;
    for (final item in items) {
      // 只处理可继续求值的上下文：DOM 元素 / XML 节点 / JSON 对象 /
      // JSON 串条目（JS 列表规则返回 `JSON.stringify` 数组时，legado 保证
      // content 是字符串：JsonPath 字段规则自行 parse，JS 字段规则拿到原串）。
      if (!(item is dom.Element ||
          item is xml.XmlElement ||
          item is Map ||
          item is String)) {
        continue;
      }
      rows++;
      // bookUrl 放到最后求值：部分源的链接模板依赖其它字段（如 `{{book.kind}}`），
      // 先把已解析字段累积进 `book` 变量，再解析链接（对齐阅读的行为）。
      final bookVars = <String, dynamic>{};
      engine.vars['book'] = bookVars;
      final name = _field(engine, rule.name, item);
      if (name == null || name.isEmpty) {
        noName++;
        continue;
      }
      bookVars['name'] = name;
      final author = _field(engine, rule.author, item);
      final kind = _field(engine, rule.kind, item);
      final intro = _field(engine, rule.intro, item);
      final lastChapter = _field(engine, rule.lastChapter, item);
      final updateTime = _field(engine, rule.updateTime, item);
      final wordCount = _field(engine, rule.wordCount, item);
      if (author != null) bookVars['author'] = author;
      if (kind != null) bookVars['kind'] = kind;
      if (intro != null) bookVars['intro'] = intro;
      final coverRaw = _field(engine, rule.coverUrl, item);

      // 没有书籍页地址的条目点开必炸（JS-only 规则在非 Android 端解析不出地址）——直接丢弃，
      // 但计数用于把「0 结果」解释成「N 条结果链接解析失败（bookUrl 依赖 JS）」。
      final bookUrlRaw = _field(engine, rule.bookUrl, item, isUrl: true);
      final bookUrl = bookUrlRaw == null
          ? ''
          : resolveUrl(bookUrlRaw, source.bookSourceUrl);
      if (bookUrl.isEmpty) {
        noUrl++;
        continue;
      }
      // 跨阶段变量快照（legado book.variableMap）：搜索条目 `@put:{k:rule}`
      // 的产出挂在书级，详情阶段 `@get:{k}` 读回（17k: `@put:{book:id}`）。
      final sv = js?.session?.vars;
      if (sv != null && sv.isNotEmpty) {
        OnlineBookService.cacheItemVars(source.bookSourceUrl, bookUrl, sv);
      }
      books.add(
        SearchBook(
          origin: source.bookSourceUrl,
          originName: source.bookSourceName,
          name: name,
          author: author,
          kind: kind,
          intro: intro,
          coverUrl: coverRaw == null
              ? null
              : resolveUrl(coverRaw, source.bookSourceUrl),
          bookUrl: bookUrl,
          latestChapterTitle: lastChapter,
          time: updateTime,
          wordCount: wordCount,
        ),
      );
    }
    return SearchParseResult(books, rows: rows, noName: noName, noUrl: noUrl);
  }

  String? _field(AnalyzeRule engine, String? rule, Object item,
      {bool isUrl = false}) {
    final r = rule?.trim();
    if (r == null || r.isEmpty) return null;
    final v = engine.getString(r, ctx: item, isUrl: isUrl);
    return (v == null || v.isEmpty) ? null : v;
  }

  // ==================== 发现页（exploreUrl / ruleExplore） ====================

  /// 解析书源的 exploreUrl → 分类列表。
  ///
  /// 实测（用户 1093 个真实书源）三种写法并存，必须都支持：
  ///
  /// 1. **行格式**（316 个）：
  ///    ```
  ///    玄幻::https://site/list/xuanhuan/{{page}}.html
  ///    排行::https://site/rank/all/{{page}}.html
  ///    ```
  /// 2. **JSON 数组**（318 个，Legado 主流写法）：
  ///    ```json
  ///    [{"title":"男生","url":""},{"title":"都市","url":"https://..."}]
  ///    ```
  /// 3. **JS 脚本**（168 个，`@js:` 开头）：需要 JS 引擎动态生成，
  ///    静态解析无法支持 —— 返回空列表，由 UI 明确提示（不静默失败）。
  ///
  /// 「标题::地址」也兼容 `标题,地址`；无标题时取 URL 末段。
  ///
  /// P1-8：纯函数（只依赖 exploreUrl 文本），按文本缓存。列表页每次渲染
  /// 都会为每个源调一遍，318 个 JSON 源逐个 jsonDecode 是纯浪费。
  static final Map<String, List<ExploreCategory>> _catCache = {};

  /// 测试用：清空发现分类缓存。
  @visibleForTesting
  static void debugClearCategoryCache() => _catCache.clear();

  static void _rememberCategories(String raw, List<ExploreCategory> cats) {
    if (_catCache.length >= 64) _catCache.remove(_catCache.keys.first);
    _catCache[raw] = cats;
  }

  static List<ExploreCategory> parseExploreCategories(BookSource source) {
    final raw = source.exploreUrl?.trim();
    if (raw == null || raw.isEmpty) return const [];
    final hit = _catCache[raw];
    if (hit != null) return hit;
    final res = _parseExploreCategoriesUncached(source, raw);
    _rememberCategories(raw, res);
    return res;
  }

  static List<ExploreCategory> _parseExploreCategoriesUncached(
    BookSource source,
    String raw,
  ) {
    // JS 脚本（`@js:` / `<js>`）：跑一遍引擎拿 JSON —— 分类表本来就是源数据
    // 拼出来的，不需要网络。脚本内部若真要 `java.ajax`（魔丸小说那种），
    // 这里没有会话可补网，会挂起失败 → 退回空列表。
    final js = _exploreJsBody(raw);
    if (js != null) {
      final byJs = _categoriesFromJs(source, js);
      if (byJs.isNotEmpty) return byJs;
      // 求值失败且正文里带明显静态 JSON：尽力解析（少数源把 JSON 写在 JS 尾部）
      final i = raw.indexOf('[');
      if (i >= 0) return _parseJsonCategories(raw.substring(i));
      return byJs;
    }

    // JSON 数组格式
    if (raw.startsWith('[')) {
      return _parseJsonCategories(raw);
    }

    // 行格式
    return _parseLineCategories(raw);
  }

  /// 取出 JS 形态 exploreUrl 的脚本体；非 JS 返回 null。
  static String? _exploreJsBody(String raw) {
    final low = raw.toLowerCase();
    if (low.startsWith('@js:')) return raw.substring(4);
    if (low.startsWith('<js>') && low.endsWith('</js>')) {
      return raw.substring(4, raw.length - 5);
    }
    return null;
  }

  /// 求值 JS 形态的 exploreUrl，返回 `[{title, url, style?}]`。
  ///
  /// legado 里这段脚本的 `this` 是书源对象（`QMA_DISC.explore.call(this, …)`），
  /// 所以用 `source` 全局对象当 `this` 绑定；结果统一 JSON.stringify 后解析。
  ///
  /// 现代写法（legado 3.x）的发现页脚本还会：
  /// - push `{type:"select", chars:[…], default:"男生", action:"java.refreshExplore()"}`
  ///   这类**分栏选择器**（不是可抓取分类，UI 无芯片时只取默认值）；
  /// - 读 `infoMap["频道"]`、写 `infoMap.save()` 保存用户选择。
  /// 我们按「首次打开」处理：infoMap 先取已存值，缺项用选择器的 `default` 补，
  /// 补到新值就再跑一遍脚本，等价于原版用默认选项渲染的首屏。
  static List<ExploreCategory> _categoriesFromJs(
      BookSource source, String code, {JsEnv? env}) {
    if (!JsBridge.available) return const [];
    final stored = _loadExploreInfo(source);
    var tabs = _evalExploreTabs(source, code, stored, env: env);
    if (tabs.isEmpty) return const [];
    final defaults = <String, String>{};
    for (final t in tabs) {
      if ('${t['type']}'.toLowerCase() != 'select') continue;
      final title = '${t['title'] ?? ''}'.trim();
      final def = t['default'];
      if (title.isNotEmpty && def != null && !stored.containsKey(title)) {
        defaults[title] = '$def';
      }
    }
    if (defaults.isNotEmpty) {
      final merged = {...stored, ...defaults};
      final again = _evalExploreTabs(source, code, merged, env: env);
      if (again.isNotEmpty) {
        tabs = again;
        _saveExploreInfo(source, merged);
      }
    }
    return _tabsToCategories(tabs);
  }

  /// 异步补全发现分类：脚本里要联网（`java.ajax`、`source.getVariable()` 里再请求）
  /// 才算得出 tab 的源，同步路径只能拿到空列表。
  ///
  /// 抛出的挂起交给 [runWithJsSession] 补网重放，和搜索/正文完全同一条链路。
  Future<List<ExploreCategory>> exploreCategoriesAsync(BookSource source) async {
    final sync = parseExploreCategories(source);
    if (sync.isNotEmpty) return sync;
    final raw = (source.exploreUrl ?? '').trim();
    final body = _exploreJsBody(raw);
    if (body == null) return sync;
    if (_useOffthread(source)) {
      final off = await offthreadCategories(source);
      if (off != null) {
        if (off.isNotEmpty) _rememberCategories(raw, off);
        return off;
      }
    }
    final session = JsSession();
    final env = jsEnvFor(source, session);
    try {
      final cats = await runWithJsSession(
        session,
        () async => _categoriesFromJs(source, body, env: env),
        (e) => _resolveSuspend(source, session, e),
      ).timeout(const Duration(seconds: 25));
      if (cats.isNotEmpty) _rememberCategories(raw, cats);
      return cats;
    } catch (_) {
      return sync;
    }
  }

  /// 跑一遍发现页脚本，拿到**原始 tab 数组**（含选择器项）。
  static List<Map> _evalExploreTabs(
    BookSource source,
    String code,
    Map<String, String> info, {
    JsEnv? env,
  }) {
    try {
      env ??= JsEnv(
        scopeKey: source.bookSourceUrl,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        sourceHeader: source.header,
        sourceJson: source.jsSourceFields,
        jsLib: source.jsLib,
      );
      // 用 direct eval 保留「最后一条语句的值」语义（legado 的 `<js>` 就是这样
      // 取值的；`var out=[]; …; out` 结尾的脚本拿不到显式 return）。
      // `this` 由外层 `.call(source)` 提供，eval 直接继承。
      final literal = jsonEncode(code);
      final infoJson = jsonEncode(jsonEncode(info));
      final wrapped = 'JSON.stringify((function(){'
          // infoMap：既支持取值/赋值，也支持源脚本常用的 save()/get()/put()
          ' var __raw = JSON.parse($infoJson);'
          ' var infoMap = {};'
          ' for (var __k in __raw) infoMap[__k] = __raw[__k];'
          ' infoMap.get = function (k) { return this[k]; };'
          ' infoMap.put = function (k, v) { this[k] = v; return v; };'
          ' infoMap.has = function (k) { return Object.prototype.hasOwnProperty.call(this, k); };'
          ' infoMap.save = function () { return undefined; };'
          ' var __r = eval($literal);'
          ' if (__r !== undefined) {'
          '   try { return JSON.parse(JSON.stringify(__r)); } catch (e) { return __r; }'
          ' }'
          ' try { return eval(\'typeof result === "undefined" ? undefined : result\'); }'
          ' catch (e) { return undefined; }'
          ' }).call((typeof source === \'object\' && source) ? source : globalThis))';
      final out = JsBridge.evalCode(wrapped, env: env);
      if (out == null) return const [];
      var txt = out;
      if (txt.startsWith('"')) {
        // 脚本自己已经 stringify 过：多包了一层
        final d = jsonDecode(txt);
        if (d is String) txt = d;
      }
      final t = txt.trim();
      final rawList = t.startsWith('[')
          ? jsonDecode(t)
          : (t.startsWith('{') ? jsonDecode('[$t]') : null);
      if (rawList is! List) {
        debugPrint('[explore] 脚本输出非数组：'
            '${t.length > 120 ? t.substring(0, 120) : t}');
        return const [];
      }
      return [
        for (final e in rawList)
          if (e is Map) Map<String, dynamic>.from(e),
      ];
    } on JsSuspendException {
      rethrow; // 脚本要联网：交给 runWithJsSession 补网重跑
    } catch (_) {
      return const [];
    }
  }

  /// 原始 tab 数组 → 可抓取分类（选择器/纯标题项跳过）。
  static List<ExploreCategory> _tabsToCategories(List<Map> tabs) {
    final out = <ExploreCategory>[];
    for (final t in tabs) {
      final type = '${t['type'] ?? ''}'.toLowerCase();
      if (type == 'select' || type == 'button' || type == 'refresh') continue;
      final title = '${t['title'] ?? ''}'.trim();
      final url = '${t['url'] ?? ''}'.trim();
      if (title.isEmpty || url.isEmpty) continue;
      out.add(ExploreCategory(title: title, url: url));
    }
    return out;
  }

  /// 发现页选择器状态（`infoMap`）持久化：`@exploreInfo` 一条 JSON。
  static Map<String, String> _loadExploreInfo(BookSource source) {
    try {
      final raw = SourceVars.I.get(source.bookSourceUrl, '@exploreInfo');
      if (raw.isEmpty) return const {};
      final d = jsonDecode(raw);
      if (d is! Map) return const {};
      return {
        for (final e in d.entries) '${e.key}': '${e.value}',
      };
    } catch (_) {
      return const {};
    }
  }

  static void _saveExploreInfo(BookSource source, Map<String, String> info) {
    try {
      SourceVars.I.set(source.bookSourceUrl, '@exploreInfo', jsonEncode(info));
    } catch (_) {
      // 存不下不影响本次渲染
    }
  }

  /// 解析 JSON 数组格式的 exploreUrl。
  ///
  /// 每项形如 `{"title":"男生","url":"https://..."}`；
  /// `url` 为空的项是**分组标题**（Legado 用它做分栏），跳过不生成分类。
  static List<ExploreCategory> _parseJsonCategories(String raw) {
    List<dynamic> decoded;
    try {
      final d = jsonDecode(raw);
      if (d is! List) return const [];
      decoded = d;
    } catch (_) {
      // 严格 JSON 失败 → 按 Gson 的宽松模式再试一次（legado 用 Gson，晋江系
      // 写的是 JS 对象字面量：单引号、无引号键、尾逗号）。仍失败才放弃。
      final loose = _lenientJson(raw);
      if (loose == null) return const [];
      try {
        final d = jsonDecode(loose);
        if (d is! List) return const [];
        decoded = d;
      } catch (_) {
        return const [];
      }
    }
    final out = <ExploreCategory>[];
    for (final item in decoded) {
      if (item is! Map) continue;
      final title = (item['title'] ?? '').toString().trim();
      final url = (item['url'] ?? '').toString().trim();
      // 分组标题（无地址）跳过：它没有可抓取的目标
      if (url.isEmpty) continue;
      if (title.isEmpty) continue;
      out.add(ExploreCategory(title: title, url: url));
    }
    return out;
  }

  /// 测试用：暴露宽松 JSON 归一化。
  @visibleForTesting
  static String? debugLenientJson(String src) => _lenientJson(src);

  /// 宽松 JSON（对齐 Gson 的 lenient 模式）：单引号字符串、无引号键、
  /// 尾逗号、`//` 与 `/* */` 注释。返回可被 `jsonDecode` 吃下的文本，
  /// 失败返回 null。
  static String? _lenientJson(String src) {
    final b = StringBuffer();
    var i = 0;
    final n = src.length;
    // 上一个有意义的字符，用于判定「这里该出现键了」
    var expectKey = false;
    while (i < n) {
      final c = src[i];
      // 注释
      if (c == '/' && i + 1 < n) {
        if (src[i + 1] == '/') {
          while (i < n && src[i] != '\n') {
            i++;
          }
          continue;
        }
        if (src[i + 1] == '*') {
          i += 2;
          while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/')) {
            i++;
          }
          i = (i + 1 < n) ? i + 2 : n;
          continue;
        }
      }
      // 字符串
      if (c == '"' || c == "'") {
        final q = c;
        i++;
        b.write('"');
        while (i < n) {
          final ch = src[i];
          if (ch == '\\' && i + 1 < n) {
            final nx = src[i + 1];
            // `\'` 在双引号里是非法转义，其余原样
            b.write(nx == "'" ? "'" : '$ch$nx');
            i += 2;
            continue;
          }
          if (ch == q) {
            i++;
            break;
          }
          if (ch == '"') {
            b.write(r'\"');
            i++;
            continue;
          }
          if (ch == '\n' || ch == '\r' || ch == '\t') {
            // JSON 字符串里不允许裸控制字符（源里手写的多行标题）
            b.write(ch == '\n'
                ? r'\n'
                : ch == '\r'
                    ? r'\r'
                    : r'\t');
            i++;
            continue;
          }
          b.write(ch);
          i++;
        }
        b.write('"');
        expectKey = false;
        continue;
      }
      // 键：`{` 或 `,` 之后紧跟标识符 + `:`（前瞻，不动游标）
      if (expectKey && RegExp(r'[A-Za-z_$]').hasMatch(c)) {
        var j = i + 1;
        while (j < n && RegExp(r'[A-Za-z0-9_$]').hasMatch(src[j])) {
          j++;
        }
        var k = j;
        while (k < n && _isJsonWs(src[k])) {
          k++;
        }
        if (k < n && src[k] == ':') {
          b.write('"${src.substring(i, j)}"');
          expectKey = false;
          i = j;
          continue;
        }
      }
      if (c == ',') {
        // 尾逗号：`,` 后面（忽略空白）直接是 `]`/`}` → 丢掉
        var j = i + 1;
        while (j < n && _isJsonWs(src[j])) {
          j++;
        }
        if (j < n && (src[j] == ']' || src[j] == '}')) {
          i++;
          continue;
        }
        b.write(',');
        expectKey = true;
        i++;
        continue;
      }
      if (c == '{') {
        b.write(c);
        expectKey = true;
        i++;
        continue;
      }
      if (_isJsonWs(c)) {
        b.write(c);
        i++;
        continue;
      }
      b.write(c);
      expectKey = false;
      i++;
    }
    return b.toString();
  }

  static bool _isJsonWs(String c) =>
      c == ' ' || c == '\t' || c == '\n' || c == '\r';

  /// 解析行格式（`标题::地址` / `标题,地址` / 纯地址）。
  static List<ExploreCategory> _parseLineCategories(String raw) {
    final out = <ExploreCategory>[];
    for (final line in raw.split('\n')) {
      final item = line.trim();
      if (item.isEmpty || item.startsWith('#')) continue;
      var title = '';
      var url = '';
      final sepIdx = item.indexOf('::');
      if (sepIdx >= 0) {
        title = item.substring(0, sepIdx).trim();
        url = item.substring(sepIdx + 2).trim();
      } else {
        final comma = item.indexOf(',');
        if (comma >= 0) {
          title = item.substring(0, comma).trim();
          url = item.substring(comma + 1).trim();
        } else {
          url = item;
        }
      }
      if (url.isEmpty) continue;
      if (title.isEmpty) {
        final seg = url.split('/').where((s) => s.isNotEmpty).toList();
        title = seg.isEmpty ? '分类' : seg.last;
      }
      out.add(ExploreCategory(title: title, url: url));
    }
    return out;
  }

  /// 该书源的 exploreUrl 是否为 JS 脚本（发现页无法支持）。
  static bool hasJsExplore(BookSource source) {
    final raw = source.exploreUrl?.trim() ?? '';
    return raw.startsWith('@js:') ||
        raw.startsWith('<js>') ||
        raw.startsWith('@JS:');
  }

  /// 抓取某个分类的一页书单（复用搜索页解析规则 [ExploreRule]）。
  Future<List<SearchBook>> exploreOne(
    BookSource source,
    ExploreCategory category, {
    int page = 1,
  }) async {
    final session = JsSession();
    final env = jsEnvFor(source, session);
    try {
      return await runWithJsSession(
        session,
        () => _exploreOneInner(source, category, page: page, js: env),
        (e) => _resolveSuspend(source, session, e),
      ).timeout(perSourceTimeout);
    } on TimeoutException {
      throw SourceHttpException('超时：单源超过 ${perSourceTimeout.inSeconds}s');
    }
  }

  Future<List<SearchBook>> _exploreOneInner(
    BookSource source,
    ExploreCategory category, {
    required int page,
    required JsEnv js,
  }) async {
    final url =
        renderExploreUrl(category.url, source.bookSourceUrl, page, js: js);
    final headers = _mergeHeaders(source, const {});
    await _gateFor(source).waitSlot();
    final resp = await _client.get(
      url,
      headers: headers,
      timeout: requestTimeout,
    );
    if (!resp.ok) throw SourceHttpException('HTTP ${resp.statusCode}');
    return parseExplorePage(source, resp.body, js: js, pageUrl: url);
  }

  /// 把分类地址渲染为可请求的绝对地址（补全相对路径 + `{{page}}` / `{page}` 占位）。
  @visibleForTesting
  static String renderExploreUrl(String raw, String base, int page,
      {JsEnv? js}) {
    var s = raw.trim();
    // 先渲染 {{page}}（模板引擎，含算术），再回落旧式单花括号 {page}：
    // 顺序不能反——先替换 `{page}` 会把 `{{page}}` 破坏成 `{N}`。
    s = renderUrlTemplate(s, {'page': page}, js: js);
    s = s.replaceAll('{page}', '$page');
    return resolveUrl(s, base);
  }

  /// 解析发现页书单。
  ///
  /// 规则选择（实测踩坑）：不能简单用 `exploreRule ?? searchRule`——
  /// 大量书源的 `ruleExplore` 是**空对象 `{}`**（非 null），`??` 不会回退，
  /// 于是 bookList 取不到 → 解析出 0 本书（用户反馈「发现页什么都没有」）。
  /// 这里改为「exploreRule 有 bookList 才用它，否则回退 searchRule」。
  List<SearchBook> parseExplorePage(BookSource source, String body,
      {JsEnv? js, String? pageUrl}) {
    final rule = _pickExploreRule(source);
    // ExploreRule 与 SearchRule 字段同名，这里统一取字段
    final listRule = _exploreField(rule, 'bookList');
    if (listRule == null || listRule.trim().isEmpty) return const [];

    final engine = AnalyzeRule(body,
        baseUrl: pageUrl ?? source.bookSourceUrl, js: js);
    final items = engine.getRawList(listRule);
    final books = <SearchBook>[];
    for (final item in items) {
      if (!(item is dom.Element || item is xml.XmlElement || item is Map)) {
        continue;
      }
      final name = _field(engine, _exploreField(rule, 'name'), item);
      if (name == null || name.isEmpty) continue;
      final bookVars = <String, dynamic>{'name': name};
      engine.vars['book'] = bookVars;
      final author = _field(engine, _exploreField(rule, 'author'), item);
      final kind = _field(engine, _exploreField(rule, 'kind'), item);
      final intro = _field(engine, _exploreField(rule, 'intro'), item);
      final lastChapter = _field(engine, _exploreField(rule, 'lastChapter'), item);
      final updateTime = _field(engine, _exploreField(rule, 'updateTime'), item);
      final wordCount = _field(engine, _exploreField(rule, 'wordCount'), item);
      if (author != null) bookVars['author'] = author;
      if (kind != null) bookVars['kind'] = kind;
      final coverRaw = _field(engine, _exploreField(rule, 'coverUrl'), item);
      // 同上：解析不出书籍页地址的条目一律不进榜（否则点开就是「无效的地址」）。
      // bookUrl 最后求值，便于模板引用已解析字段（{{book.kind}} 等）。
      final bookUrlRaw =
          _field(engine, _exploreField(rule, 'bookUrl'), item, isUrl: true);
      final bookUrl = bookUrlRaw == null
          ? ''
          : resolveUrl(bookUrlRaw, source.bookSourceUrl);
      if (bookUrl.isEmpty) continue;
      books.add(
        SearchBook(
          origin: source.bookSourceUrl,
          originName: source.bookSourceName,
          name: name,
          author: author,
          kind: kind,
          intro: intro,
          coverUrl: coverRaw == null
              ? null
              : resolveUrl(coverRaw, source.bookSourceUrl),
          bookUrl: bookUrl,
          latestChapterTitle: lastChapter,
          time: updateTime,
          wordCount: wordCount,
        ),
      );
    }
    return books;
  }

  /// 选择用于发现页解析的规则。
  ///
  /// 实测（用户 1093 个真实书源）：
  /// - 511 个源有 `ruleExplore`，其中不少 bookList 直接用 `<js>` 或指向搜索规则；
  /// - 291 个源的 `ruleExplore` 是**空对象 `{}`**（非 null），
  ///   此时必须回退到 `ruleSearch`（Legado 里发现页与搜索页列表结构常一致）。
  Object? _pickExploreRule(BookSource source) {
    final er = source.exploreRule;
    if (er != null) {
      final list = er.bookList?.trim();
      // 有可用的 bookList 才认它（空对象 / 空字段一律回退）
      if (list != null && list.isNotEmpty) return er;
    }
    return source.searchRule;
  }

  /// 从 ExploreRule / SearchRule 取同名字段（两者字段名一致）。
  String? _exploreField(Object? rule, String key) {
    if (rule is ExploreRule) {
      return switch (key) {
        'bookList' => rule.bookList,
        'name' => rule.name,
        'author' => rule.author,
        'intro' => rule.intro,
        'kind' => rule.kind,
        'lastChapter' => rule.lastChapter,
        'updateTime' => rule.updateTime,
        'bookUrl' => rule.bookUrl,
        'coverUrl' => rule.coverUrl,
        'wordCount' => rule.wordCount,
        _ => null,
      };
    }
    if (rule is SearchRule) {
      return switch (key) {
        'bookList' => rule.bookList,
        'name' => rule.name,
        'author' => rule.author,
        'intro' => rule.intro,
        'kind' => rule.kind,
        'lastChapter' => rule.lastChapter,
        'updateTime' => rule.updateTime,
        'bookUrl' => rule.bookUrl,
        'coverUrl' => rule.coverUrl,
        'wordCount' => rule.wordCount,
        _ => null,
      };
    }
    return null;
  }

  /// 对**单个书源**抓取其某个分类的一页书单。
  Future<SourceExploreResult> exploreSource(
    BookSource source,
    ExploreCategory category, {
    int page = 1,
  }) async {
    if (_useOffthread(source)) {
      final off = await offthreadExplore(source, category, page: page);
      if (off != null) return off;
    }
    final started = DateTime.now();
    try {
      final books = await exploreOne(source, category, page: page);
      return SourceExploreResult(
        source: source,
        books: books,
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
      );
    } catch (e) {
      return SourceExploreResult(
        source: source,
        error: '$e',
        elapsedMs: DateTime.now().difference(started).inMilliseconds,
      );
    }
  }

  /// 在所有**支持发现页**的书源中，并发抓取「各自第一个分类」。
  ///
  /// 用途：发现页首屏「随便逛逛」——每个源出一个分类的最新书单，
  /// 用户不必先挑书源。分类由各源自己的 exploreUrl 决定。
  Future<List<SourceExploreResult>> exploreFirstOfEach({
    int page = 1,
    int maxSources = 12,
  }) async {
    final tasks = <(BookSource, ExploreCategory)>[];
    for (final s in store.enabled) {
      final cats = parseExploreCategories(s);
      if (cats.isEmpty) continue;
      tasks.add((s, cats.first));
      if (tasks.length >= maxSources) break;
    }
    if (tasks.isEmpty) return const [];
    return _runExploreTasks(tasks, page: page);
  }

  /// 并发执行一批「源 + 分类」抓取任务（结果顺序与任务顺序一致）。
  Future<List<SourceExploreResult>> _runExploreTasks(
    List<(BookSource, ExploreCategory)> tasks, {
    int page = 1,
  }) async {
    final results = List<SourceExploreResult?>.filled(tasks.length, null);
    var next = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= tasks.length) return;
        final (source, category) = tasks[i];
        results[i] = await exploreSource(source, category, page: page);
      }
    }

    final n = concurrency.clamp(1, tasks.length);
    await Future.wait(List.generate(n, (_) => worker()));
    return [
      for (final r in results)
        if (r != null) r
    ];
  }

  /// 所有支持发现页的书源（按名称排序），供发现页顶部选择。
  List<BookSource> exploreCapableSources() {
    final out = <BookSource>[];
    for (final s in store.enabled) {
      if (parseExploreCategories(s).isNotEmpty) out.add(s);
    }
    out.sort((a, b) => a.bookSourceName.compareTo(b.bookSourceName));
    return out;
  }

  /// 统计：支持发现页的源数 / 启用总数 / JS 脚本源数（UI 提示用）。
  ({int capable, int total, int jsOnly}) exploreStats() {
    var capable = 0;
    var jsOnly = 0;
    final enabled = store.enabled;
    for (final s in enabled) {
      if (parseExploreCategories(s).isNotEmpty) {
        capable++;
      } else if (hasJsExplore(s)) {
        jsOnly++;
      }
    }
    return (capable: capable, total: enabled.length, jsOnly: jsOnly);
  }

  /// 汇总所有启用书源的发现分类（同名合并，保留出现顺序）。
  ///
  /// 注意：不同书源的同名分类**地址不同**，所以这只用于「跨源联合搜索」
  /// 场景；发现页按书源浏览时请用 [parseExploreCategories]。
  List<ExploreCategory> allExploreCategories() {
    final seen = <String>{};
    final out = <ExploreCategory>[];
    for (final s in store.enabled) {
      for (final c in parseExploreCategories(s)) {
        if (seen.add(c.title)) out.add(c);
      }
    }
    return out;
  }

  /// 预热请求（旧版扩展字段 `preRequest`：字符串数组）。
  ///
  /// 用途：部分站点要求先访问一个“令牌页”（在响应里写 Cookie）后
  /// 才能调用搜索接口（如 /user/hm.html）。预热与主请求共享 Cookie 容器；
  /// 单个预热失败不阻断主流程。
  Future<void> _runPreRequests(
    BookSource source,
    Map<String, String> headers,
    String key,
    int page,
  ) async {
    final pre = source.extra['preRequest'];
    if (pre is! List) return;
    for (final t in pre) {
      final tmpl = t.toString().trim();
      if (tmpl.isEmpty) continue;
      try {
        final url = buildRequest(tmpl, source.bookSourceUrl, {
          'key': key,
          'page': page,
        }).url;
        await _client.get(
          url,
          headers: headers,
          timeout: requestTimeout,
          retries: 0,
        );
      } catch (_) {
        // 忽略预热失败（主请求仍会继续）
      }
    }
  }

  /// 合并请求头（源的 header JSON 字符串 + 请求选项里的 headers）。
  Map<String, String> _mergeHeaders(
    BookSource source,
    Map<String, dynamic> options,
  ) {
    final out = Map<String, String>.from(OnlineBookService.headerMap(source));
    final opts = options['headers'];
    if (opts is Map) {
      opts.forEach((k, v) => out[k.toString()] = v.toString());
    }
    return out;
  }
}
