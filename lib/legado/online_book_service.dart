// 在线书籍服务：详情 / 目录 / 正文的获取与解析。
//
// 数据流（对应内置「笔趣阁家族」源）：
//   搜索（HTTP，M2 已有）
//   → 详情页 HTTP 抓取 + ruleBookInfo 解析（OG meta 等）
//   → 目录：与详情页同页解析（ruleToc），或按 tocUrl 规则单独请求
//   → 正文：隐藏 WebView 渲染（令牌墙 / SPA / 加密接口全部由页面 JS 完成）
//     - 支持 `gatewayPath` 扩展：章节链接先改写到网关（如 /userverify/book/...），
//       由站点服务端 301 到真正的阅读页。
//
// 本文件不依赖 UI；WebView 引擎仅在「取正文」时被调用。
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../models.dart';
import 'analyze_rule.dart';
import 'analyze_url.dart';
import 'cookie_jar.dart';
import 'http_client.dart';
import 'js_engine.dart';
import 'models.dart';
import 'rule_analyzer.dart';
import 'webview_engine.dart';

/// 详情页解析结果。
class OnlineBookInfo {
  const OnlineBookInfo({
    this.name,
    this.author,
    this.intro,
    this.coverUrl,
    this.kind,
    this.lastChapter,
    this.updateTime,
    this.chapters = const [],
  });

  final String? name;
  final String? author;
  final String? intro;
  final String? coverUrl;
  final String? kind;
  final String? lastChapter;
  final String? updateTime;
  final List<Chapter> chapters;
}

/// 在线书籍服务。
class OnlineBookService {
  OnlineBookService({SourceHttpClient? client})
      : _client = client ?? SourceHttpClient();

  final SourceHttpClient _client;

  static const Duration _httpTimeout = Duration(seconds: 20);

  /// P0：书源 JS 环境（同一次操作共享 [session]；jsLib/header/来源绑定齐备）。
  static JsEnv jsEnvFor(
    BookSource source,
    JsSession session, {
    Map<String, dynamic>? book,
    String? title,
    String? nextChapterUrl,
    String? baseUrl,
  }) =>
      JsEnv(
        scopeKey: source.bookSourceUrl,
        sourceUrl: source.bookSourceUrl,
        sourceName: source.bookSourceName,
        sourceHeader: source.header,
        sourceJson: source.jsSourceFields,
        jsLib: source.jsLib,
        session: session,
        book: book,
        title: title,
        nextChapterUrl: nextChapterUrl,
        // legado：脚本里的 baseUrl 是「当前解析页地址」，不是书源地址。
        baseUrl: baseUrl,
        getCookie: (tag, key) => LegadoCookieJar.I.getFor(tag, key),
      );

  /// 挂起补网：抓取目标写入会话缓存后重跑脚本。
  Future<void> _resolveSuspend(
    BookSource source,
    JsSession session,
    JsSuspendException e,
  ) async {
    if (e.kind == 'webview') {
      // legado `java.webView(url)` = 「用 WebView 打开并返回渲染后的 HTML」。
      // Android 有 WebView 内核时真渲染；桌面端（或渲染为空）退回 HTTP 抓取，
      // 至少让不依赖 JS 的站点还能出内容，而不是直接空串。
      var html = '';
      try {
        html = await WebViewEngine.instance.fetchRenderedHtml(url: e.target);
      } catch (_) {
        html = '';
      }
      if (html.trim().isEmpty && WebViewEngine.supported) {
        try {
          // 仅在「有 WebView 内核但渲染失败」时降级抓取：桌面端没有内核，
          // 抓也是壳页/超时，反而把书源整体拖到平台超时之外。
          html = await _getHtml(source, e.target)
              .timeout(const Duration(seconds: 6));
        } catch (_) {
          html = '';
        }
      }
      session.webViewCache[e.target] = html;
      return;
    }
    final key = JsBridge.ajaxKey(e.method, e.target, e.body);
    try {
      session.ajaxCache[key] = await _getHtml(source, e.target);
      session.ajaxMeta[key] = {'code': 200, 'url': e.target, 'headers': const {}};
    } catch (_) {
      session.ajaxCache[key] = '';
    }
  }

  // ---------- 详情 / 目录 ----------

  /// 抓取详情页并解析（含目录；目录为空且有 tocUrl 规则时单独请求）。
  Future<OnlineBookInfo> fetchInfo(BookSource source, String bookUrl) async {
    final session = JsSession();
    return runWithJsSession(
      session,
      () => _fetchInfoInner(source, bookUrl, session),
      (e) => _resolveSuspend(source, session, e),
    );
  }

  Future<OnlineBookInfo> _fetchInfoInner(
    BookSource source,
    String bookUrl,
    JsSession session,
  ) async {
    // legado book.variableMap：搜索阶段 `@put:{k:rule}` 写入的变量在此读回，
    // 供 init/字段/tocUrl 模板的 `@get:{k}`（17k: `@get:{book}` → 书籍 id）。
    session.vars.addAll(itemVars(source.bookSourceUrl, bookUrl));
    final resp = await _fetch(source, bookUrl);
    final html = resp.body;
    // 经历 30x 后按最终地址解析（相对链接/脚本里的 baseUrl 都以它为准）
    final pageUrl = resp.finalUrl.isEmpty ? bookUrl : resp.finalUrl;
    final engine = AnalyzeRule(html,
        baseUrl: pageUrl, js: jsEnvFor(source, session, baseUrl: pageUrl));
    final info = source.bookInfoRule;

    String? g(String? rule) {
      final r = rule?.trim();
      if (r == null || r.isEmpty) return null;
      final v = engine.getString(r);
      return (v == null || v.isEmpty) ? null : v;
    }

    // bookInfo.init 常做变量预置（`@put:{...}`），或整体切换后续解析根
    // （legado BookInfo：`analyzeRule.setContent(analyzeRule.getElement(init))`
    // ——如 `$.data` / `$.data.bookInfo`，之后的字段规则与 tocUrl 模板都在
    // init 结果上求值）。
    final init = info?.init?.trim();
    if (init != null && init.isNotEmpty) {
      final initResult = engine.getRawElement(init);
      if (initResult != null) engine.setContentObject(initResult);
    }

    final bookVars = <String, dynamic>{'bookUrl': bookUrl};
    engine.vars['book'] = bookVars;

    final name = g(info?.name);
    if (name != null) {
      bookVars['name'] = name;
      bookVars['title'] = name;
    }
    final author = g(info?.author);
    if (author != null) bookVars['author'] = author;
    final intro = g(info?.intro);
    final kind = g(info?.kind);
    if (kind != null) bookVars['kind'] = kind;
    final lastChapter = g(info?.lastChapter);
    final updateTime = g(info?.updateTime);
    final coverUrl = g(info?.coverUrl);

    // 目录：先试详情页同页解析；空则按 tocUrl 规则（最后求值，模板可引用上面变量）
    var chapters = <Chapter>[];
    var tocEngine = engine;
    var tocPageUrl = bookUrl;
    final tocRule = source.tocRule;
    if (tocRule != null) {
      chapters = parseChapters(engine, tocRule, bookUrl);
      if (chapters.isEmpty) {
        // 对齐 legado BookInfo：tocUrl 用 isUrl 语义（取首匹配，不拼接），
        // 且相对地址按「详情页地址」解析（baseUrl = 书页，而非书源地址）。
        final tocUrlR = info?.tocUrl?.trim() ?? '';
        final tocUrlRule = tocUrlR.isEmpty
            ? null
            : engine.getString(tocUrlR, isUrl: true);
        if (tocUrlRule != null && tocUrlRule.isNotEmpty && tocUrlRule != bookUrl) {
          final resolved = resolveUrl(tocUrlRule, pageUrl);
          if (resolved.isNotEmpty) {
            try {
              final tocHtml = await _getHtml(source, resolved);
              tocEngine = AnalyzeRule(
                tocHtml,
                baseUrl: resolved,
                vars: {'book': bookVars},
                js: jsEnvFor(source, session, book: bookVars, baseUrl: resolved),
              );
              tocPageUrl = resolved;
              chapters = parseChapters(tocEngine, tocRule, resolved);
            } on JsSuspendException {
              rethrow;
            } catch (_) {
              // 目录页抓取失败：保留详情页已解析结果（可能为空）
            }
          }
        }
      }
      // 目录分页（nextTocUrl）：逐页追加（最多 10 页，防死循环）
      if (chapters.isNotEmpty) {
        chapters = await _followNextToc(
          source,
          tocEngine,
          tocRule,
          initial: chapters,
          firstPageUrl: tocPageUrl,
          session: session,
        );
      }
    }

    return OnlineBookInfo(
      name: name,
      author: author,
      intro: intro,
      coverUrl: coverUrl,
      kind: kind,
      lastChapter: lastChapter,
      updateTime: updateTime,
      chapters: chapters,
    );
  }

  /// 跟随 `nextTocUrl` 抓取后续目录页并追加章节（按 URL 去重）。
  Future<List<Chapter>> _followNextToc(
    BookSource source,
    AnalyzeRule engine,
    TocRule rule, {
    required List<Chapter> initial,
    required String firstPageUrl,
    required JsSession session,
  }) async {
    final nextRule = rule.nextTocUrl?.trim() ?? '';
    if (nextRule.isEmpty) return initial;
    final out = List<Chapter>.from(initial);
    final seen = out.map((c) => c.url).toSet();
    final visited = <String>{firstPageUrl};
    var pageBase = firstPageUrl;
    var curEngine = engine;
    for (var page = 0; page < 10; page++) {
      List<String> nexts;
      try {
        nexts = curEngine
            .getStrings(nextRule)
            .map((u) => u.trim())
            .where((u) => u.isNotEmpty)
            .toList();
      } on JsSuspendException {
        rethrow;
      } catch (_) {
        break;
      }
      if (nexts.isEmpty) break;
      // 按顺序挑第一个「没去过」的候选：下拉框式目录页（一个 select 里列出
      // 全部分页地址、首页同时也是当前页）第一项往往是当前页/已访问页，
      // 直接取 nexts.first 会在第二页原地打转。
      var next = '';
      for (final u in nexts) {
        final r = resolveUrl(u, pageBase);
        if (r.isNotEmpty && !visited.contains(r)) {
          next = r;
          break;
        }
      }
      if (next.isEmpty) break;
      visited.add(next);
      String html;
      try {
        html = await _getHtml(source, next);
      } on JsSuspendException {
        rethrow;
      } catch (_) {
        break;
      }
      final nextEngine = AnalyzeRule(html,
          baseUrl: next, js: jsEnvFor(source, session, baseUrl: next));
      final more = parseChapters(nextEngine, rule, next);
      var added = 0;
      for (final c in more) {
        if (seen.add(c.url)) {
          out.add(c);
          added++;
        }
      }
      if (added == 0) break;
      pageBase = next;
      curEngine = nextEngine;
    }
    return out;
  }

  /// 解析目录：chapterList 产出「条目」，逐条取章节名 / 章节链接。
  ///
  /// 支持一个条目里取到多个章节名（如 chapterList 直接选 `<dl>` 的站点），
  /// 也支持一条一个章节（如 `dl.1@tag.dd` 的笔趣阁模板）；按链接去重。
  static List<Chapter> parseChapters(
    AnalyzeRule engine,
    TocRule rule,
    String baseUrl,
  ) {
    var listRule = rule.chapterList?.trim() ?? '';
    if (listRule.isEmpty) return const [];
    // legado BookChapterList：`-` 前缀 = 倒序，`+` 前缀 = 保留正序（仅剥前缀）。
    var reverse = false;
    if (listRule.startsWith('-')) {
      reverse = true;
      listRule = listRule.substring(1);
    }
    if (listRule.startsWith('+')) {
      listRule = listRule.substring(1);
    }
    final nameRule = rule.chapterName?.trim() ?? '';
    final urlRule = (rule.chapterUrl?.trim().isNotEmpty ?? false)
        ? rule.chapterUrl!.trim()
        : 'tag.a@href';
    final volumeRule = rule.isVolume?.trim() ?? '';
    final vipRule = rule.isVip?.trim() ?? '';
    final payRule = rule.isPay?.trim() ?? '';

    // 规则求值 → 是否命中。空白 / `0` / `false` 都算否（legado 同口径）。
    bool flag(String r, Object ctx) {
      if (r.isEmpty) return false;
      try {
        final v = engine.getString(r, ctx: ctx)?.trim().toLowerCase() ?? '';
        return v.isNotEmpty && v != '0' && v != 'false' && v != 'null';
      } catch (_) {
        return false;
      }
    }

    final out = <Chapter>[];
    final seen = <String>{};
    final seenVolumes = <String>{};
    for (final item in engine.getRawList(listRule)) {
      final titles = nameRule.isEmpty
          ? const <String>[]
          : engine.getStrings(nameRule, ctx: item);
      // 对齐 legado：逐项把当前章节挂到 chapter 绑定，chapterUrl 脚本可读 chapter.title
      engine.vars['chapter'] = <String, dynamic>{
        'title': titles.isEmpty ? '' : titles.first.trim(),
      };
      // 卷标题行：没有章节链接，只做分组（<dl> 站点的 <dt>）
      if (volumeRule.isNotEmpty && flag(volumeRule, item)) {
        final t = titles.isEmpty ? '' : titles.first.trim();
        if (t.isNotEmpty && seenVolumes.add(t)) {
          out.add(Chapter(title: t, url: '', isVolume: true));
        }
        continue;
      }
      final hrefs = engine.getStrings(urlRule, ctx: item);
      final n = titles.length < hrefs.length ? titles.length : hrefs.length;
      final isVip = flag(vipRule, item);
      final isPay = flag(payRule, item);
      for (var i = 0; i < n; i++) {
        final title = titles[i].trim();
        final rawHref = hrefs[i].trim();
        if (title.isEmpty || rawHref.isEmpty) continue;
        // 跳过「展开全部章节」等 JS 伪链接
        final lower = rawHref.toLowerCase();
        if (lower.startsWith('javascript:') ||
            lower.startsWith('mailto:') ||
            lower.startsWith('tel:')) {
          continue;
        }
        final (target, suffix) = splitUrlSuffix(rawHref);
        final href = resolveUrl(target, baseUrl) + suffix;
        if (href.isEmpty) continue;
        if (!seen.add(href)) continue;
        out.add(Chapter(
          title: title,
          url: href,
          isVip: isVip,
          isPay: isPay,
        ));
      }
    }
    return reverse ? out.reversed.toList() : out;
  }

  // ---------- 正文 ----------

  /// 取章节正文。
  ///
  /// 书源 `webView=true` 时走隐藏 WebView（可配 `gatewayPath` 网关重写）；
  /// 否则直接 HTTP 抓取 + ruleContent 解析（普通静态站点）。
  ///
  /// [book] 为可选的上下文变量（`{'name': …, 'author': …, 'durChapterTitle': …}`），
  /// 供 `{{book.name}}` 模板与 `replaceRegex` 净化规则使用。
  ///
  /// 隐藏 WebView 只在 Android 存在：Windows 端没有 webview_flutter 的
  /// Windows 实现，这里直接降级为普通 HTTP 抓取（能拿到多少算多少），
  /// 而不是抛「平台不支持」把整本书打不开。
  Future<String> fetchChapterText(
    BookSource source,
    String chapterUrl, {
    Map<String, dynamic>? book,
  }) async {
    final session = JsSession();
    return runWithJsSession(
      session,
      () => _fetchChapterTextInner(source, chapterUrl, book, session),
      (e) => _resolveSuspend(source, session, e),
    );
  }

  Future<String> _fetchChapterTextInner(
    BookSource source,
    String chapterUrl,
    Map<String, dynamic>? book,
    JsSession session,
  ) async {
    final vars = <String, dynamic>{
      if (book != null) 'book': book,
    };
    // java.getString/getElement：晋江系正文脚本在 `<js>` 内回读规则
    // （`java.getElement("$.content")` / `java.getString("$.sayBody")`）。
    late AnalyzeRule engine;
    final env =
        jsEnvFor(source, session, book: book, baseUrl: chapterUrl).copyWith(getString: (r) {
      try {
        return engine.getString(r);
      } catch (_) {
        return null;
      }
    });
    if (_flag(source.extra['webView']) && WebViewEngine.supported) {
      // 章网址可能带请求选项尾缀（塔读 `,{"webView":true}`）——WebView 只能加纯地址。
      final target = webViewChapterUrl(source, splitUrlSuffix(chapterUrl).$1);
      final text = await WebViewEngine.instance.fetchRenderedText(
        url: target,
        cssSelectors: contentSelectors(source),
      );
      return _applyReplace(source, cleanChapterText(text), vars, js: env);
    }

    final raw = source.contentRule?.content ?? '';
    if (raw.trim().isEmpty) return '';

    // 章网址尾缀里的请求选项（塔读 `,{"webView":true}`）同样要开渲染：
    // 这类站点的正文由页面 JS 注入，静态抓只能拿到壳页。
    final (plainUrl, suffix) = splitUrlSuffix(chapterUrl);
    final suffixWebView = suffix.contains('webView');
    String? rendered;
    if (suffixWebView && !(_flag(source.extra['webView']) && WebViewEngine.supported)) {
      try {
        rendered = await WebViewEngine.instance.fetchRenderedHtml(
          url: webViewChapterUrl(source, plainUrl),
        );
      } catch (_) {
        rendered = null;
      }
    }

    final html = (rendered != null && rendered.trim().isNotEmpty)
        ? rendered
        : await _getHtml(source, suffixWebView ? plainUrl : chapterUrl);
    final pageUrl = suffixWebView ? plainUrl : chapterUrl;
    engine =
        AnalyzeRule(html, baseUrl: pageUrl, vars: vars, js: env);
    // 正文通常是多段：取规则命中的**全部**结果并按段拼回（getString 只会取第一段）
    var text = cleanChapterText(engine.getStrings(raw).join('\n'));

    // 正文分页（nextContentUrl）：追加后续页（最多 10 页，防死循环）。
    final nextRule = source.contentRule?.nextContentUrl?.trim() ?? '';
    if (nextRule.isNotEmpty && text.isNotEmpty) {
      final visited = <String>{chapterUrl};
      for (var i = 0; i < 10; i++) {
        final nexts = engine
            .getStrings(nextRule)
            .map((u) => u.trim())
            .where((u) => u.isNotEmpty)
            .toList();
        if (nexts.isEmpty) break;
        final next = resolveUrl(nexts.first, chapterUrl);
        if (next.isEmpty || !visited.add(next)) break;
        String nextHtml;
        try {
          nextHtml = await _getHtml(source, next);
        } catch (_) {
          break;
        }
        engine = AnalyzeRule(nextHtml,
            baseUrl: next, vars: vars, js: env);
        final more = cleanChapterText(engine.getStrings(raw).join('\n'));
        if (more.isEmpty) break;
        text = '$text\n$more';
      }
    }

    return _applyReplace(source, text, vars);
  }

  /// 应用 `ruleContent.replaceRegex` 净化（模板先按上下文变量渲染）。
  String _applyReplace(
    BookSource source,
    String text,
    Map<String, dynamic> vars, {
    JsEnv? js,
  }) {
    final rr = source.contentRule?.replaceRegex;
    if (rr == null || rr.trim().isEmpty || text.isEmpty) return text;
    final engine =
        AnalyzeRule(null, baseUrl: source.bookSourceUrl, vars: vars, js: js);
    return engine.applyReplaceRegex(text, rr);
  }

  /// 章节页在隐藏 WebView 中打开的地址（应用 gatewayPath 网关重写）。
  ///
  /// 例：`https://www.hkmtxt.cc/book/126/2079.html` + gatewayPath `/userverify`
  ///   → `https://www.hkmtxt.cc/userverify/book/126/2079.html`
  ///   （服务端 301 到真正的阅读页）
  static String webViewChapterUrl(BookSource source, String chapterUrl) {
    final gateway = source.extra['gatewayPath']?.toString().trim() ?? '';
    if (gateway.isEmpty) return chapterUrl;
    try {
      final uri = Uri.parse(chapterUrl);
      if (uri.path.startsWith('$gateway/') || uri.path == gateway) {
        return chapterUrl;
      }
      return uri.replace(path: '$gateway${uri.path}').toString();
    } catch (_) {
      return chapterUrl;
    }
  }

  /// 从 ruleContent.content 规则串提取 WebView 可用的 CSS 选择器列表。
  ///
  /// 兼容规则写法：`id.chaptercontent@text || class.content@text`
  ///   → `['#chaptercontent', '.content']`
  static List<String> contentSelectors(BookSource source) {
    final raw = source.contentRule?.content ?? '';
    final out = <String>[];
    for (final alt in raw.split('||')) {
      var seg = alt.trim();
      if (seg.isEmpty) continue;
      seg = seg.split('@').first.trim();
      if (seg.isEmpty || seg.startsWith('@')) continue;
      if (seg.startsWith('tag.')) {
        seg = seg.substring(4);
      } else if (seg.startsWith('class.')) {
        seg = '.${seg.substring(6)}';
      } else if (seg.startsWith('id.')) {
        seg = '#${seg.substring(3)}';
      }
      if (seg.isNotEmpty) out.add(seg);
    }
    return out;
  }

  // ---------- 正文清洗 ----------

  /// 去掉站点水印 / 导航等噪音行。
  static final List<String> _junkMarkers = [
    '请收藏本站',
    '手机版：',
    '手机版:',
    '『点此报错』',
    '『加入书签』',
    '点此报错',
    '加入书签',
    '添加书签',
    '推荐给朋友',
    '最新章节',
    // 站点转载声明（常见于抓取失败的整页文本里）
    '转载作品',
    '网友上传',
    '请记住本书',
    '首发域名',
  ];

  static final RegExp _junkExact = RegExp(
    r'^[　\s]*(上一章|下一章|返回目录|目录|加入书签|章节报错|举报|书页|书架)[\s　]*$',
  );

  /// 「导航短行」特征：≤12 字、且**全是**汉字/字母/数字（无标点、无空格）——
  /// 站点菜单项都是干净短语，而正文句子几乎必然带标点。
  static final RegExp _navLikeLine = RegExp(
    r'^[\u4e00-\u9fa5A-Za-z0-9]{1,12}$',
  );

  /// 判断是否是站点导航残留（短行 + 命中栏目词）。
  static bool _isNavResidue(String line) =>
      _navLikeLine.hasMatch(line) && _navWords.any(line.contains);

  /// 站点栏目词（命中即视为导航残留，仅对「导航短行」生效）。
  static const List<String> _navWords = [
    '首页',
    '书架',
    '排行榜',
    '排行',
    '分类',
    '玄幻',
    '武侠',
    '都市',
    '历史',
    '网游',
    '科幻',
    '女生',
    '完本',
    '全部小说',
    '最近更新',
    '登录',
    '注册',
    '护眼',
    '关灯',
    '大中小',
    '手机版',
    '字体',
  ];

  static final RegExp _domainWatermark = RegExp(
    r'([a-z0-9-]+\.)*(bqg\d*|biquge|biqg|qbtr|hkmtxt|shw\d*|ddtxt\d*|qbxs\d*|22biqu)\.[a-z]+',
    caseSensitive: false,
  );

  static final RegExp _trailingCode = RegExp(r'\s*\d{1,3}w\d{1,3}-\d{1,6}\s*$');

  /// 整行只有一条 URL（站点尾巴水印）。
  static final RegExp _urlOnlyLine = RegExp(r'^https?://\S+$');

  /// 清洗：去空行 / 水印行 / 导航行 / 行尾编号，保留段首全角缩进。
  ///
  /// 输入可能是 `@html` 规则吐出的整段 HTML（段落用 `<br>` 分隔、实体未解码、
  /// 水印和正文常在同一行）——先做 HTML 归一化再按行过滤，否则水印词会把
  /// 整段正文一起连坐丢弃（唐三中文等站点即此坑）。
  static String cleanChapterText(String raw) {
    if (raw.isEmpty) return '';
    var text = raw.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    if (text.contains('<')) {
      // 段落标记 → 换行；其余标签摘除；常见实体解码（先摘标签再解实体，
      // 避免把 `&lt;script&gt;` 变成真标签再被摘掉）。
      text = text
          .replaceAll(RegExp(r'<br\s*/?>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'</p\s*>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'</div\s*>', caseSensitive: false), '\n')
          .replaceAll(RegExp(r'<[^<>]{1,200}>'), '')
          .replaceAll('&nbsp;', ' ')
          .replaceAll('&lt;', '<')
          .replaceAll('&gt;', '>')
          .replaceAll('&quot;', '"')
          .replaceAll('&#39;', "'")
          .replaceAll('&ldquo;', '“')
          .replaceAll('&rdquo;', '”')
          .replaceAll('&hellip;', '…')
          .replaceAll('&mdash;', '—')
          .replaceAll('&amp;', '&');
      text = text.replaceAllMapped(
        RegExp(r'&#(\d{2,6});'),
        (m) => String.fromCharCode(int.tryParse(m.group(1)!) ?? 32),
      );
    }
    final out = <String>[];
    for (final line in text.split('\n')) {
      var l = line.trimRight();
      l = l.replaceFirst(RegExp(r'^[ \t\u00A0]+'), '');
      if (l.trim().isEmpty) continue;
      var skip = false;
      for (final marker in _junkMarkers) {
        if (l.contains(marker)) {
          skip = true;
          break;
        }
      }
      if (skip) continue;
      if (_junkExact.hasMatch(l)) continue;
      if (l.length < 160 && _urlOnlyLine.hasMatch(l)) continue;
      // 站点阅读器的工具条（“字体：大 中 小 护眼 关灯”）——整行特征明显
      if (l.contains('护眼') && l.contains('关灯')) continue;
      // 导航短行兜底：短、无标点、且命中栏目词 → 视为菜单残留
      if (_isNavResidue(l.trim())) continue;
      if (l.length < 60 && _domainWatermark.hasMatch(l)) continue;
      l = l.replaceAll(_trailingCode, '').trimRight();
      if (l.trim().isEmpty) continue;
      out.add(l);
    }
    return out.join('\n');
  }

  // ---------- 内部工具 ----------

  /// 拆 `url,{...}` 请求选项尾缀（保留原文，选项语义如 webView 为 P2）。
  static (String, String) splitUrlSuffix(String s) {
    final t = s.trimRight();
    final i = t.lastIndexOf(',{');
    if (i > 0 && t.endsWith('}')) {
      return (t.substring(0, i).trim(), t.substring(i));
    }
    return (t, '');
  }

  /// 跨阶段书级变量袋（legado `book.variableMap` 的内存近似）：
  /// 搜索条目求值时 `@put:{k:rule}` 的产出按 bookUrl 快照，
  /// 详情阶段 `@get:{k}` 从这里读回（17k：搜索 `@put:{book:id}` →
  /// 详情 `http://api.17k.com/book/@get:{book}/volumes`）。
  /// ponytail: 简单 FIFO 淘汰 + 进程内存（重启丢弃），legado 是落库持久。
  static final Map<String, Map<String, String>> _itemVars = {};

  /// 搜索条目收口：把当前会话变量挂到该书（`bookUrl` 必须先就绪）。
  static void cacheItemVars(
      String sourceUrl, String bookUrl, Map<String, String> vars) {
    if (sourceUrl.isEmpty || bookUrl.isEmpty) return;
    if (_itemVars.length > 400) _itemVars.remove(_itemVars.keys.first);
    _itemVars['$sourceUrl\u0000$bookUrl'] = Map.of(vars);
  }

  /// 详情/目录阶段读回该书在搜索阶段写入的变量。
  static Map<String, String> itemVars(String sourceUrl, String bookUrl) =>
      _itemVars['$sourceUrl\u0000$bookUrl'] ?? const {};

  /// 分身回传用：本源在搜索阶段写入的书级变量快照（bookUrl → 变量表）。
  /// 搜索在后台 isolate 跑时，`@put:{...}` 写的是分身那一份；不带回来的话，
  /// 主线程随后的详情 `@get:{...}`（17k 那类源）会拿到空值。
  static Map<String, Map<String, String>> itemVarsSnapshotFor(String sourceUrl) {
    final pre = '$sourceUrl\u0000';
    final out = <String, Map<String, String>>{};
    for (final e in _itemVars.entries) {
      if (e.key.startsWith(pre)) out[e.key.substring(pre.length)] = e.value;
    }
    return out;
  }

  Future<String> _getHtml(BookSource source, String url) async =>
      (await _fetch(source, url)).body;

  /// 诊断接口：只抓章节页原始 HTML（不跑规则）。
  ///
  /// 抓取失败或需要 JS 补网时抛错，交给调用方打印；
  /// 用于人工核对「正文为空」到底是站点返回空页还是规则不匹配。
  Future<String> fetchChapterHtml(
    BookSource source,
    String url, {
    Map<String, dynamic>? book,
  }) async {
    final target = splitUrlSuffix(url).$1;
    return _fetch(source, target).then((r) => r.body);
  }

  /// 抓页面并保留「最终地址」（经历 30x 后相对链接要按它解析，同 legado）。
  Future<SourceResponse> _fetch(BookSource source, String url) async {
    // `,{...}` 请求选项尾缀走 analyze_url 的正规解析管线（宽松 JSON：
    // 单引号/尾逗号/未加引号模板值都能吃；不渲染——保存值已渲染）。
    final t = parseUrlTemplate(url);
    var headers = headerMap(source);
    var method = 'GET';
    String? body;
    String? charset;
    if (t.options.isNotEmpty) {
      // 请求选项（legado AnalyzeUrl）：body 有值且未写 method → POST。
      final m = (t.options['method'] ?? '').toString().toUpperCase();
      if (m == 'POST' || t.options['body'] != null) {
        method = m.isEmpty ? 'POST' : m;
        final b = t.options['body'];
        body = b is String ? b : jsonEncode(b);
        final Map? oh = t.options['headers'] as Map?;
        if (oh != null && oh.isNotEmpty) {
          headers = {
            ...headers,
            for (final e in oh.entries)
              e.key.toString(): e.value.toString().trim(),
          };
        }
        charset = t.options['charset']?.toString();
      }
    }
    final SourceResponse resp;
    if (method == 'POST') {
      resp = await _client.post(
        t.url,
        headers: headers,
        body: body,
        charset: charset,
        timeout: _httpTimeout,
        retries: 1,
      );
    } else {
      resp = await _client.get(
        t.url,
        headers: headers,
        charset: charset,
        timeout: _httpTimeout,
        retries: 1,
      );
    }
    if (!resp.ok) {
      throw SourceHttpException('HTTP ${resp.statusCode}');
    }
    return resp;
  }

  /// header 求值结果缓存（P1-8）：下载整本时每章一次请求都会走这里，
  /// `@js:` 头（QQ 浏览器源注入 QIMEI/Referer）重算一次要起一遍 JS 引擎。
  /// 带 TTL 缓存：既省掉重复求值，又不会让时效性签名一直用旧值。
  static final Map<String, (Map<String, String>, DateTime)> _hdrCache = {};
  static const Duration _hdrTtl = Duration(minutes: 1);

  /// 测试用：清空 header 缓存。
  @visibleForTesting
  static void debugClearHeaderCache() => _hdrCache.clear();

  /// 书源 header 求值：`@js:`/`<js>` 头先走脚本（legado：header 走规则求值，
  /// QQ 浏览器源用它注入 Referer/UA/QIMEI），其余按 JSON 宽松解析。
  static Map<String, String> headerMap(BookSource source) {
    final raw = (source.header ?? '').trim();
    if (raw.isEmpty) return const {};
    final key = '${source.bookSourceUrl}\u0000$raw';
    final hit = _hdrCache[key];
    if (hit != null && DateTime.now().difference(hit.$2) < _hdrTtl) {
      return hit.$1;
    }
    final m = _evalHeaderMap(source, raw);
    if (_hdrCache.length >= 128) _hdrCache.remove(_hdrCache.keys.first);
    _hdrCache[key] = (m, DateTime.now());
    return m;
  }

  static Map<String, String> _evalHeaderMap(BookSource source, String raw) {
    final low = raw.toLowerCase();
    final jsHead = low.startsWith('@js:') ||
        (low.startsWith('<js>') && low.endsWith('</js>'));
    if (JsBridge.available && jsHead) {
      final body = low.startsWith('@js:')
          ? raw.substring(4)
          : raw.substring(4, raw.length - 5);
      try {
        final out = JsBridge.evalCode(body, env: jsEnvFor(source, JsSession()));
        if (out != null && out.trim().isNotEmpty) {
          final m = RuleAnalyzer.parseHeaderJson(out);
          if (m.isNotEmpty) return m;
        }
      } catch (_) {
        // 脚本失败：退回静态解析（通常为空表）
      }
    }
    // JS 头且脚本不可用/求值失败：不把脚本文本当 JSON 解析（legado 同为解析失败）。
    if (jsHead) return const {};
    return RuleAnalyzer.parseHeaderJson(raw);
  }

  static bool _flag(dynamic v) =>
      v == true || v == 1 || v == 'true' || v == '1';
}
