// 用大模型生成「阅读 3.0」书源：
//
//   抓页瘦身 → 模型生成 JSON → 结构校验 → 用本仓库解析引擎实测
//   （搜索 / 详情目录 / 正文）→ 失败回灌重试。
//
// 为什么必须实测：模型给的 CSS 选择器经常「看起来对、跑起来空」，
// 只校验 JSON 结构等于没验。这里直接复用 OnlineRepo / OnlineBookService，
// 生成结论和 App 真实解析走同一条链路。
//
// 成本与边界见 tool/source_gen_probe/README.md。
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'models.dart';
import 'http_client.dart';
import 'online_book_service.dart';
import 'online_repo.dart';
import 'source_store.dart';

/// OpenAI 兼容接口配置（用户自备）。
class LlmConfig {
  const LlmConfig({
    required this.baseUrl,
    required this.apiKey,
    required this.model,
  });

  /// 形如 `https://api.openai.com/v1`（不带 `/chat/completions`）。
  final String baseUrl;
  final String apiKey;
  final String model;

  String get _root => baseUrl.trim().replaceAll(RegExp(r'/+$'), '');

  /// OpenAI 协议端点。容忍几种常见填法：
  /// `https://api.x.com/v1`、尾斜杠、以及有人直接把全路径
  /// `/v1/chat/completions` 填进接口地址（原样用，不再追加）。
  String get chatUrl {
    final root = _root;
    if (root.endsWith('/chat/completions')) return root;
    return '$root/chat/completions';
  }

  String get modelsUrl {
    var root = _root;
    const suffix = '/chat/completions';
    if (root.endsWith(suffix)) {
      root = root.substring(0, root.length - suffix.length);
    }
    return '$root/models';
  }

  bool get configured => _root.isNotEmpty && apiKey.trim().isNotEmpty && model.trim().isNotEmpty;
}

class LlmException implements Exception {
  LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}

class LlmClient {
  LlmClient(this.cfg);
  final LlmConfig cfg;

  /// 模型整轮回答（几千 token）+ 慢网关，90s 经常不够；
  /// 超时会被包装成友好提示，不会原样把 TimeoutException 甩给用户。
  static const Duration _timeout = Duration(seconds: 180);

  /// 拉取可用模型列表（OpenAI 兼容 `GET /models`）。
  ///
  /// 失败抛 [LlmException]，调用方据此退回「手动填写型号」。
  Future<List<String>> listModels() async {
    final r = await http.get(
      Uri.parse(cfg.modelsUrl),
      headers: {'authorization': 'Bearer ${cfg.apiKey}'},
    ).timeout(const Duration(seconds: 20));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw LlmException('模型列表接口 ${r.statusCode}：${_clip(r.body, 200)}');
    }
    dynamic j;
    try {
      j = jsonDecode(utf8.decode(r.bodyBytes));
    } catch (_) {
      throw LlmException('模型列表返回的不是 JSON');
    }
    final data = j is Map ? j['data'] : null;
    if (data is! List) throw LlmException('模型列表格式不认识（缺少 data）');
    final ids = <String>[
      for (final e in data)
        if (e is Map && '${e['id'] ?? ''}'.trim().isNotEmpty) '${e['id']}',
    ]..sort();
    if (ids.isEmpty) throw LlmException('模型列表为空');
    return ids;
  }

  Future<String> chat(List<Map<String, String>> messages) async {
    final r = await http
        .post(
          Uri.parse(cfg.chatUrl),
          headers: {
            'content-type': 'application/json',
            'authorization': 'Bearer ${cfg.apiKey}',
          },
          body: jsonEncode({
            'model': cfg.model,
            'temperature': 0.2,
            'messages': messages,
          }),
        )
        .timeout(_timeout);
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw LlmException('模型接口 ${r.statusCode}：${_clip(r.body, 300)}');
    }
    final j = jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
    final choices = j['choices'];
    if (choices is! List || choices.isEmpty) {
      throw LlmException('模型没有返回 choices');
    }
    final msg = (choices.first as Map)['message'];
    final content = msg is Map ? msg['content'] : null;
    if (content is! String || content.trim().isEmpty) {
      throw LlmException('模型返回内容为空');
    }
    return content;
  }

  static String _clip(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}

/// 把底层超时翻译成人话（用户看到的不该是 TimeoutException）。
Never _rethrowFriendly(Object e, String what, int seconds) {
  if (e is TimeoutException) {
    throw LlmException('$what超时（$seconds 秒）：'
        '站点或模型接口响应太慢。稍后重试，或改用「先浏览一遍」直接提供页面地址。');
  }
  if (e is LlmException) throw e;
  throw LlmException('$what失败：$e');
}

/// 抓页面并瘦身成模型可读的 DOM 片段。
///
/// 原始页面动辄几十上百 KB（脚本/样式占大头），既不省钱也超上下文；
/// 去掉 script/style/注释、压缩空白后通常只剩几 KB。
Future<String> fetchSlim(String url, {int maxChars = 20000}) async {
  try {
    // 用书源同款 HTTP 客户端：连接池 / Cookie / 编码探测与实测阶段完全一致
    // —— 裸 http.get 的 TLS 指纹会被不少小说站 WAF 直接拒掉
    // （实测 book.sfacg.com：curl 200 / 裸 Dart 400 空响应）。
    final r = await SourceHttpClient()
        .get(
          url,
          headers: {
            'user-agent':
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
                    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36',
            'accept-language': 'zh-CN,zh;q=0.9',
          },
          timeout: const Duration(seconds: 40),
        )
        .timeout(const Duration(seconds: 45));
    if (r.statusCode < 200 || r.statusCode >= 300) {
      throw LlmException('抓取 $url 失败：HTTP ${r.statusCode}');
    }
    // SourceHttpClient 已按站点编码解码好正文
    final slim = slimHtml(r.body);
    if (slim.length <= maxChars) return slim;
    // 截到最近的标签边界（'>'），避免模型看到半个标签
    final cut = slim.lastIndexOf('>', maxChars);
    return cut <= 0
        ? slim.substring(0, maxChars)
        : '${slim.substring(0, cut + 1)}\n<!-- 片段已截断 -->';
  } on TimeoutException catch (e) {
    _rethrowFriendly(e, '抓取页面', 40);
  } on LlmException {
    rethrow;
  } catch (e) {
    _rethrowFriendly(e, '抓取页面', 40);
  }
}

/// 去脚本 / 样式 / 注释，压缩空白，保留标签结构。
/// 去脚本 / 样式 / 注释，压缩空白，超长文本截短，保留标签结构。
///
/// 搜索结果页的「大量内容」是成百条书籍简介，动辄几百 KB 全是长文本；
/// 模型写规则只需要列表结构 + 代表性条目，长文一律截到 160 字，
/// 上下文体积直接决定模型响应速度（超时的大头）。
String slimHtml(String html) {
  final stripped = html
      .replaceAll(RegExp(r'<!--[\s\S]*?-->'), '')
      .replaceAll(
          RegExp(r'<(script|style|noscript|svg|iframe)[\s\S]*?</\1>',
              caseSensitive: false),
          '')
      .replaceAll(RegExp(r'\s+'), ' ');
  // 超长文本节点截短（[^<>] 无嵌套量词，线性扫描无回溯风险）
  final capped = stripped.replaceAllMapped(
      RegExp(r'>([^<>]{160,})<'),
      (m) => '>${m.group(1)!.substring(0, 160)}…<');
  return capped.replaceAll('> <', '><').trim();
}

/// 「先浏览一遍」采集到的一页。
///
/// [html] 是 WebView 渲染后的 DOM：搜索结果大量是 JS 动态渲染的站
/// （如 shuyous 的搜索结果页），静态重抓只能拿到空壳 —— 浏览时顺手把
/// 渲染后的 DOM 带回来，这类站才生成得了。null = 桌面端手填地址，现场抓。
class CollectedPage {
  const CollectedPage({required this.url, this.html});
  final String url;
  final String? html;
}

/// 从模型输出里抠出 JSON 并解析（容忍 ```json 包裹 / 前后废话）。
BookSource? parseSourceJson(String raw) {
  var s = raw.trim();
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(s);
  if (fence != null) s = fence.group(1)!.trim();
  final start = s.indexOf('{');
  final end = s.lastIndexOf('}');
  if (start < 0 || end <= start) return null;
  try {
    final map = jsonDecode(s.substring(start, end + 1)) as Map<String, dynamic>;
    if ('${map['bookSourceUrl'] ?? ''}'.trim().isEmpty) return null;
    return BookSource.fromJson(map);
  } catch (_) {
    return null;
  }
}

/// 瘦身后按 [maxChars] 截断（落在标签边界，避免模型看到半个标签）。
String cappedSlim(String slim, [int maxChars = 20000]) {
  if (slim.length <= maxChars) return slim;
  final cut = slim.lastIndexOf('>', maxChars);
  return cut <= 0
      ? slim.substring(0, maxChars)
      : '${slim.substring(0, cut + 1)}\n<!-- 片段已截断 -->';
}

/// 生成用的 system prompt：把 3.0 格式与规则语法一次讲清。
const String sourceGenSystemPrompt = r'''
你是「阅读 3.0」书源规则生成器。根据用户给的站点页面片段（已去脚本的 HTML），
输出**一个**可直接导入的 JSON 对象，不要解释、不要 markdown 代码块。

JSON 结构（字段名必须完全一致）：
{
  "bookSourceName": "站点名",
  "bookSourceUrl": "https://站点根地址",
  "bookSourceGroup": "AI生成",
  "bookSourceType": 0,
  "enabled": true,
  "enabledExplore": false,
  "searchUrl": "搜索地址，关键词用 {{key}} 占位",
  "ruleSearch": {
    "bookList": "结果列表选择器", "name": "书名规则", "author": "作者规则",
    "bookUrl": "书页地址规则", "coverUrl": "封面规则",
    "intro": "简介规则（可空）", "kind": "分类规则（可空）",
    "lastChapter": "最新章节规则（可空）", "wordCount": "字数规则（可空）"
  },
  "ruleBookInfo": {
    "name": "书名", "author": "作者", "coverUrl": "封面", "intro": "简介",
    "kind": "分类", "lastChapter": "最新章节",
    "tocUrl": "目录页地址（目录不在书页时填）", "wordCount": "", "init": ""
  },
  "ruleToc": {
    "chapterList": "章节列表选择器", "chapterName": "章节名规则",
    "chapterUrl": "章节地址规则"
  },
  "ruleContent": {"content": "正文规则"}
}

规则语法：
- `选择器@属性`：CSS 选择器取属性（text / html / href / src / 任意属性名）。
- 支持 `class.xxx` / `id.xxx` / `tag.div` / 原生 CSS，以及 `:eq(n)` `:first` `:has(x)`
  `:contains(文字)`；多个结果用 `a.0`、`a.1` 取第 n 个。
- `@text` 取文本，`@html` 取内部 HTML（正文常用）。
- 清洗：`规则##正则##替换`，可多段；正则替换为空写 `规则##正则`。
- 拼接：`规则1&&规则2`，多个结果用换行拼接。
- 搜索页关键词一定是 `{{key}}`；地址可以是相对路径（引擎按 baseUrl 解析）。
- `ruleBookInfo.tocUrl`：目录章节列表就在书页里时**必须留空**，不要编造目录地址；
  只有目录确实在另一个地址（如 /book/1/catalog）时才填那个地址。
- `ruleSearch.bookUrl` 要指向能直接打开的书页；搜索结果里是跳转/中转地址时，
  用规则把真实书页地址拼出来。
- 正文优先用 id/class 明确的容器（如 `#content` / `.article-content`），`@html` 再交给引擎清洗。
- 不要编造页面里不存在的选择器；看不清的字段留空字符串。
''';

/// 把 `{{key}}` 模板替换成关键词并补全绝对地址；模板为空返回 null。
String? resolveTemplate(String tpl, String keyword, String siteUrl) {
  if (tpl.trim().isEmpty) return null;
  final filled = tpl.replaceAll('{{key}}', Uri.encodeComponent(keyword));
  final uri = Uri.tryParse(filled);
  if (uri == null) return null;
  if (uri.hasScheme) return filled;
  final base = Uri.tryParse(siteUrl);
  if (base == null) return null;
  return base.resolveUri(uri).toString();
}

/// 一步实测的结论（UI / 回灌共用）。
class ProbeStep {
  ProbeStep(this.name, {required this.ok, required this.detail, required this.ms});
  final String name;
  final bool ok;
  final String detail;
  final int ms;

  @override
  String toString() => '$name ${ok ? 'OK' : 'FAIL'} ${ms}ms $detail';
}

/// 生成阶段：搜索 → 书详情 → 目录 → 正文，每一步独立生成、独立实测。
enum GenStep { search, detail, toc, content }

extension GenStepX on GenStep {
  String get label => switch (this) {
        GenStep.search => '搜索',
        GenStep.detail => '书详情',
        GenStep.toc => '目录',
        GenStep.content => '正文',
      };
}

/// 一步的生成结果：[ok] 时 [source] 是合并了本步规则的书源草稿。
class StepResult {
  const StepResult({
    required this.ok,
    required this.detail,
    this.source,
    this.bookUrl,
  });
  final bool ok;
  final String detail;
  final BookSource? source;

  /// 第 1 步实测到的书页地址（后续步骤实测要用）。
  final String? bookUrl;
}

/// 分步生成：一次只喂一个页面的上下文，只实测一步 —— 失败定位准确、
/// 模型上下文小、用户可以按提示重新浏览出问题的那一步。
class SourceGenerator {
  SourceGenerator({required this.llm});

  final LlmClient llm;

  /// 第 1 步：搜索（searchUrl + ruleSearch）。
  ///
  /// [page] 是用户浏览采集的搜索结果页（渲染后 DOM）；没浏览时退回
  /// 搜索模板 / 首页兜底。
  Future<StepResult> generateSearchStep({
    required String siteUrl,
    required String keyword,
    CollectedPage? page,
    String searchUrlTemplate = '',
    int maxRounds = 2,
    void Function(String)? log,
    void Function(String bookUrl)? bookUrlOut,
  }) async {
    var fallback = '';
    if (page == null || (page.html?.trim().isEmpty ?? true)) {
      final tpl = searchUrlTemplate.trim();
      fallback = tpl.isEmpty
          ? siteUrl
          : resolveTemplate(tpl, keyword, siteUrl) ?? siteUrl;
    }
    final block = await _pagesBlock(page, fallback, label: '搜索结果', log: log);
    String? found;
    final r = await _runStep(
      task: '任务：生成书源的搜索部分 —— bookSourceName / bookSourceUrl / '
          'searchUrl / ruleSearch。bookSourceUrl 用站点主地址 $siteUrl，'
          '或页面里能看出的主域名。ruleBookInfo / ruleToc / ruleContent '
          '后续步骤会补，本步先原样给出（可空）。',
      draft: null,
      pagesBlock: block,
      keyword: keyword,
      siteUrl: siteUrl,
      verify: (src) => SourceProbe()
          .verifySearch(src, keyword, onFirstBookUrl: (u) => found = u),
      maxRounds: maxRounds,
      log: log,
    );
    if (r.ok && found != null) {
      return StepResult(
          ok: true, detail: r.detail, source: r.source, bookUrl: found);
    }
    return r;
  }

  /// 第 2 步：书详情（ruleBookInfo）。
  Future<StepResult> generateDetailStep({
    required BookSource draft,
    required String bookUrl,
    CollectedPage? page,
    int maxRounds = 2,
    void Function(String)? log,
  }) async {
    final block = await _pagesBlock(page, bookUrl, label: '书详情', log: log);
    return _runStep(
      task: '任务：补全 ruleBookInfo（name / author / coverUrl / intro / kind / '
          'lastChapter / tocUrl）。目录章节列表就在书页里时 tocUrl 必须留空；'
          '在另一个地址时才填。只改 ruleBookInfo 相关字段，其余保持草稿原样。',
      draft: draft,
      pagesBlock: block,
      keyword: '',
      siteUrl: draft.bookSourceUrl,
      verify: (src) => SourceProbe().verifyDetail(src, bookUrl),
      maxRounds: maxRounds,
      log: log,
    );
  }

  /// 第 3 步：目录（ruleToc）。
  Future<StepResult> generateTocStep({
    required BookSource draft,
    required String bookUrl,
    CollectedPage? page,
    int maxRounds = 2,
    void Function(String)? log,
  }) async {
    // 目录页：浏览采集的优先；否则 tocUrl（草稿里若有），否则书页本身
    var fallback = bookUrl;
    final tocUrl = _draftTocUrl(draft);
    if (page == null && tocUrl != null) fallback = tocUrl;
    final block =
        await _pagesBlock(page, fallback, label: '目录', log: log);
    return _runStep(
      task: '任务：补全 ruleToc（chapterList / chapterName / chapterUrl）。'
          '只改 ruleToc，其余保持草稿原样。页面片段是目录所在页'
          '（可能与书详情页相同）。',
      draft: draft,
      pagesBlock: block,
      keyword: '',
      siteUrl: draft.bookSourceUrl,
      verify: (src) => SourceProbe().verifyToc(src, bookUrl),
      maxRounds: maxRounds,
      log: log,
    );
  }

  /// 第 4 步：正文（ruleContent）。
  Future<StepResult> generateContentStep({
    required BookSource draft,
    required String bookUrl,
    CollectedPage? page,
    int maxRounds = 2,
    void Function(String)? log,
  }) async {
    var fallback = bookUrl;
    if (page == null) {
      try {
        final info = await OnlineBookService()
            .fetchInfo(draft, bookUrl)
            .timeout(const Duration(seconds: 45));
        if (info.chapters.isNotEmpty) fallback = info.chapters.first.url;
      } catch (_) {}
    }
    final block = await _pagesBlock(page, fallback, label: '正文', log: log);
    return _runStep(
      task: '任务：补全 ruleContent.content（正文规则，通常 @html 取容器后交给引擎清洗）。'
          '只改 ruleContent，其余保持草稿原样。页面片段是正文页。',
      draft: draft,
      pagesBlock: block,
      keyword: '',
      siteUrl: draft.bookSourceUrl,
      verify: (src) => SourceProbe().verifyContent(src, bookUrl),
      maxRounds: maxRounds,
      log: log,
    );
  }

  String? _draftTocUrl(BookSource draft) {
    final raw = draft.extra['ruleBookInfo'];
    if (raw is Map) {
      final t = '${raw['tocUrl'] ?? ''}'.trim();
      if (t.isNotEmpty) {
        final u = Uri.tryParse(t);
        if (u != null && u.hasScheme) return t;
        if (u == null) return null;
        final base = Uri.tryParse(draft.bookSourceUrl);
        if (base != null) return base.resolveUri(u).toString();
      }
    }
    return null;
  }

  /// 页面上下文：浏览采集的渲染 DOM 优先，否则现场抓。
  Future<String> _pagesBlock(
      CollectedPage? page, String fallbackUrl,
      {String? label, void Function(String)? log}) async {
    final name = label ?? '页面';
    if (page != null && page.html != null && page.html!.trim().isNotEmpty) {
      log?.call('使用浏览采集的$name页面（渲染后 DOM）');
      return '### $name：${page.url}\n${cappedSlim(page.html!)}';
    }
    if (fallbackUrl.isEmpty) {
      return '（本步没有页面片段：依据通用小说站结构谨慎生成，拿不准的字段留空）';
    }
    log?.call('抓取$name页面…');
    try {
      return '### $name：$fallbackUrl\n${await fetchSlim(fallbackUrl)}';
    } catch (e) {
      log?.call('抓取$name页面失败：$e');
      return '（抓取 $fallbackUrl 失败：$e。请依据通用结构谨慎生成。）';
    }
  }

  /// 分步骨架：任务 + 页面 + 草稿 → 模型 → 解析 → 本步实测 → 回灌重试。
  Future<StepResult> _runStep({
    required String task,
    required BookSource? draft,
    required String pagesBlock,
    required String keyword,
    required String siteUrl,
    required Future<ProbeStep> Function(BookSource src) verify,
    required int maxRounds,
    void Function(String)? log,
  }) async {
    var feedback = '';
    for (var round = 1; round <= maxRounds; round++) {
      log?.call('第 $round 轮：请模型生成…');
      String raw;
      try {
        raw = await llm.chat([
          {'role': 'system', 'content': sourceGenSystemPrompt},
          {
            'role': 'user',
            'content': '$task\n站点：$siteUrl\n'
                '${keyword.isEmpty ? '' : '搜索关键词示例：$keyword\n'}'
                '\n页面片段：\n$pagesBlock\n\n'
                '${draft == null ? '当前还没有草稿，直接输出完整书源 JSON。' : '当前草稿（在此基础上补全/修正本步字段，返回完整书源 JSON）：\n${jsonEncode(draft.toJson())}'}'
                '${feedback.isEmpty ? '' : '\n上一轮实测失败原因：\n$feedback'}',
          },
        ]);
      } on TimeoutException {
        feedback = '模型响应超时（180 秒）。换更快的模型/网关，或稍后重试。';
        log?.call(feedback);
        continue;
      }
      final src = parseSourceJson(raw);
      if (src == null) {
        feedback = '返回内容不是合法的书源 JSON（需要顶层对象且含 bookSourceUrl）。';
        log?.call(feedback);
        continue;
      }
      final st = await verify(src);
      log?.call(st.ok ? '实测 OK：${st.detail}' : '实测 FAIL：${st.detail}');
      if (st.ok) return StepResult(ok: true, detail: st.detail, source: src);
      feedback = '- ${st.name}：${st.detail}';
    }
    return StepResult(ok: false, detail: feedback);
  }
}

/// 用本仓库的解析引擎实测书源（分步版：每一步都能单独验证）。
class SourceProbe {
  OnlineRepo _repoFor(BookSource src) =>
      OnlineRepo(store: SourceStore(initial: [src]), offthreadParse: false);

  /// 搜索：≥1 条结果；把第一条的书页地址回传（后续步骤实测要用）。
  Future<ProbeStep> verifySearch(
    BookSource src,
    String keyword, {
    void Function(String bookUrl)? onFirstBookUrl,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final res = await _repoFor(src)
          .searchOne(src, keyword)
          .timeout(const Duration(seconds: 45));
      final books = res.books;
      if (books.isNotEmpty && onFirstBookUrl != null) {
        final u = books.first.bookUrl ?? '';
        if (u.isNotEmpty) onFirstBookUrl(u);
      }
      return ProbeStep('搜索',
          ok: books.isNotEmpty,
          detail: res.error ?? '拿到 ${books.length} 条',
          ms: sw.elapsedMilliseconds);
    } catch (e) {
      return ProbeStep('搜索',
          ok: false,
          detail: e is TimeoutException ? '搜索超时（45 秒）' : '$e',
          ms: sw.elapsedMilliseconds);
    }
  }

  /// 书详情：书名/作者等字段能解析出来。
  Future<ProbeStep> verifyDetail(BookSource src, String bookUrl) async {
    final sw = Stopwatch()..start();
    try {
      final info = await OnlineBookService()
          .fetchInfo(src, bookUrl)
          .timeout(const Duration(seconds: 45));
      final ok = info.name != null && info.name!.trim().isNotEmpty;
      return ProbeStep('书详情',
          ok: ok,
          detail: '书名=${info.name ?? '(空)'}，作者=${info.author ?? '(空)'}',
          ms: sw.elapsedMilliseconds);
    } catch (e) {
      return ProbeStep('书详情',
          ok: false,
          detail: e is TimeoutException ? '书页超时（45 秒）' : '$e',
          ms: sw.elapsedMilliseconds);
    }
  }

  /// 目录：章节数 > 0。
  Future<ProbeStep> verifyToc(BookSource src, String bookUrl) async {
    final sw = Stopwatch()..start();
    try {
      final info = await OnlineBookService()
          .fetchInfo(src, bookUrl)
          .timeout(const Duration(seconds: 45));
      return ProbeStep('目录',
          ok: info.chapters.isNotEmpty,
          detail: '目录 ${info.chapters.length} 章',
          ms: sw.elapsedMilliseconds);
    } catch (e) {
      return ProbeStep('目录',
          ok: false,
          detail: e is TimeoutException ? '目录页超时（45 秒）' : '$e',
          ms: sw.elapsedMilliseconds);
    }
  }

  /// 正文：目录前 3 章里读到 ≥100 字。
  Future<ProbeStep> verifyContent(BookSource src, String bookUrl) async {
    final sw = Stopwatch()..start();
    try {
      final info = await OnlineBookService()
          .fetchInfo(src, bookUrl)
          .timeout(const Duration(seconds: 45));
      String? good;
      var tried = 0;
      for (final ch in info.chapters.take(3)) {
        tried++;
        final text = await OnlineBookService()
            .fetchChapterText(src, ch.url)
            .timeout(const Duration(seconds: 30));
        final clean = text.replaceAll(RegExp(r'\s+'), '');
        if (clean.length >= 100) {
          good = clean;
          break;
        }
      }
      return ProbeStep('正文',
          ok: good != null,
          detail: good != null
              ? '${good.length} 字：${good.length > 40 ? good.substring(0, 40) : good}'
              : '前 $tried 章都没有正文',
          ms: sw.elapsedMilliseconds);
    } catch (e) {
      return ProbeStep('正文',
          ok: false,
          detail: e is TimeoutException ? '正文超时（30 秒）' : '$e',
          ms: sw.elapsedMilliseconds);
    }
  }
}
