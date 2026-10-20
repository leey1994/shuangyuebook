// URL 模板分析器：把书源里的 URL 模板渲染成实际请求地址。
//
// 支持（对照 Legado AnalyzeUrl 的公开行为，独立实现）：
//   {{key}} / {{searchKey}} / {{keyword}}   搜索词（按 charset 百分号编码）
//   {{page}}                                页码
//   {{(page-1)*10}} / {{Date.now()}}        算术与常用 JS 函数子集（见 analyze_template）
//   {{任意键}}                              从 vars 传入的自定义变量
//   `,{...}` 尾缀                            请求选项 JSON（method / body / charset / headers）
//     - 容忍单引号 `{'charset': 'gbk'}`、尾逗号、以及 body 内模板 {{key}}
//   `<js>…</js>` 前置块                      无法执行脚本，但后随的明文 URL 可直接使用
//   `@post->` / `@get->`                    阅读 2.0 旧语法，翻译为 3.0 的 `,{...}` 选项
//   相对路径                                 以书源 bookSourceUrl 为基准补全为绝对地址
//
// 关于编码：Legado 用书源 charset 选项对 `{{key}}` 做 URL 编码（默认 UTF-8）。
// GBK 站点若按 UTF-8 编码查询词，服务端按 GBK 解码会得到乱码 → 搜不到结果，
// 因此这里按 charset 选择编码器。
import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

import 'analyze_template.dart';
import 'js_engine.dart';
import 'rule_analyzer.dart';

/// 模板解析结果：纯 URL 模板 + 请求选项。
class UrlTemplate {
  const UrlTemplate(this.url, this.options);

  /// URL（[parseUrlTemplate] 不渲染；[buildRequest] 渲染并补全）。
  final String url;

  /// `,{...}` 尾缀解析出的选项（无则空 Map）。
  final Map<String, dynamic> options;
}

/// 剥离 `<js>前置脚本</js>`（无法执行脚本，但后随明文地址可直接使用）。
String _stripJsPrelude(String s) {
  if (!s.startsWith('<js')) return s;
  final end = s.indexOf('</js>');
  if (end > 0) {
    final rest = s.substring(end + 5).trim();
    if (rest.isNotEmpty) return rest;
  }
  return s;
}

/// 拆分 URL 与选项 JSON 尾缀（不渲染模板）。
///
/// 例：`/search?q={{key}},{"method":"POST"}` →
/// url=`/search?q={{key}}`，options={"method":"POST"}
UrlTemplate parseUrlTemplate(String raw) {
  final s = _stripJsPrelude(raw.trim());
  final split = _splitOptions(s, const {});
  return _withLegacyOptions(UrlTemplate(split.$1, split.$2));
}

/// 阅读 2.0 旧语法 `地址@post->k=v&k2=v2` / `地址@get->k=v`：
/// 翻译成 3.0 的 `,{...}` 请求选项（POST 请求体 / GET 查询串）。
UrlTemplate _withLegacyOptions(UrlTemplate t) {
  final m =
      RegExp(r'^(.*?)@(post|get)->(.*)$', caseSensitive: false, dotAll: true)
          .firstMatch(t.url);
  if (m == null) return t;
  final head = m.group(1)!.trim();
  final verb = m.group(2)!.toLowerCase();
  final tail = m.group(3)!.trim();
  if (head.isEmpty || tail.isEmpty) return t;
  if (verb == 'post') {
    final opts = Map<String, dynamic>.from(t.options);
    opts['method'] = 'POST';
    opts.putIfAbsent('body', () => tail);
    return UrlTemplate(head, opts);
  }
  final sep = head.contains('?') ? '&' : '?';
  return UrlTemplate('$head$sep$tail', t.options);
}

// ---------- 选项尾缀解析 ----------

/// 从字符串尾部找 `,\s*{...}` 请求选项，返回（头段, 选项）。
(String, Map<String, dynamic>) _splitOptions(
  String s,
  Map<String, dynamic> vars,
) {
  final matches = RegExp(r',\s*\{').allMatches(s).toList();
  for (final m in matches.reversed) {
    final tail = s.substring(m.end - 1);
    final parsed = _parseOptionsTail(tail, vars);
    if (parsed != null) return (s.substring(0, m.start).trim(), parsed);
  }
  return (s.trim(), const {});
}

/// 宽松解析选项对象：原样 JSON → 渲染模板后 → 单引号/尾逗号修复版 →
/// 「模板值按 JSON 字符串包裹」版（应对 `"page":{{page}}` 未加引号的写法）。
Map<String, dynamic>? _parseOptionsTail(
  String tail,
  Map<String, dynamic> vars,
) {
  final t = tail.trim();
  if (!t.startsWith('{') || !t.endsWith('}')) return null;
  final rendered = _renderRaw(t, vars);
  final jsonQuoted = _renderJsonQuoted(t, vars);
  final candidates = <String>[
    t,
    rendered,
    _singleToDouble(t),
    _singleToDouble(rendered),
    _stripTrailingCommas(_singleToDouble(rendered)),
    jsonQuoted,
    _stripTrailingCommas(_singleToDouble(jsonQuoted)),
  ];
  for (final c in candidates) {
    try {
      final d = jsonDecode(c);
      if (d is Map) {
        return d.map((k, v) => MapEntry(k.toString(), v));
      }
    } catch (_) {
      // 换下一个候选形态
    }
  }
  return null;
}

String _singleToDouble(String s) =>
    s.contains("'") ? s.replaceAll("'", '"') : s;

String _stripTrailingCommas(String s) => s
    .replaceAll(RegExp(r',\s*\}'), '}')
    .replaceAll(RegExp(r',\s*\]'), ']');

/// 浅渲染（模板 → 原始值，不编码、不解析结构）。
String _renderRaw(String s, Map<String, dynamic> vars) {
  if (!s.contains('{{') && !s.contains(r'{$')) return s;
  return TemplateEngine(vars: vars).render(s, encodeValues: false);
}

/// 渲染为 JSON 字符串值（模板 → `"值"`，用于未加引号的 JSON 字段）。
String _renderJsonQuoted(String s, Map<String, dynamic> vars) {
  if (!s.contains('{{')) return s;
  final eng = TemplateEngine(vars: vars, encoder: jsonEncode);
  return eng.render(s, encodeValues: true);
}

/// 请求描述对象：书源规则直接返回
/// `{"method":"POST","url":"https://…","body":"…"}` 时，等价于
/// 「地址 `,{…}` 选项」写法（可乐小说等 POST 源就是这么写的）。
const List<String> _urlObjectKeys = [
  'method',
  'charset',
  'headers',
  'body',
  'webView',
  'webJs',
  'bodyJs',
  'origin',
  'retry',
  'type',
  'timeout',
  'followRedirects',
  'js',
];

/// 把「请求描述对象」字符串翻译回 `url,{options}` 规范串；不是对象则返回 null。
String? _urlObjectToTemplate(String s) {
  final t = s.trim();
  if (!t.startsWith('{') || !t.endsWith('}')) return null;
  dynamic d;
  try {
    d = jsonDecode(t);
  } catch (_) {
    try {
      d = jsonDecode(_stripTrailingCommas(_singleToDouble(t)));
    } catch (_) {
      return null;
    }
  }
  if (d is! Map) return null;
  final url = (d['url'] ?? d['URL'] ?? d['地址'])?.toString().trim() ?? '';
  if (url.isEmpty) return null;
  final opts = <String, dynamic>{};
  for (final k in _urlObjectKeys) {
    final v = d[k];
    if (v == null) continue;
    // body 允许直接写对象/数组（legado 的 UrlOption.body 是 Any）
    opts[k] = (v is Map || v is List) ? jsonEncode(v) : v;
  }
  if (opts.isEmpty) return url;
  return '$url,${jsonEncode(opts)}';
}

// ---------- 渲染与补全 ----------

/// 渲染模板变量（URL 语境：按 charset 百分号编码）。
///
/// [vars] 至少应包含 `key` 与 `page`；`searchKey` / `keyword` 会映射到 `key`。
/// [js] 提供时，子集无法求值的 `{{…}}` 走真实 JS（对齐 legado 的 evalJS）。
String renderUrlTemplate(
  String template,
  Map<String, dynamic> vars, {
  String? charset,
  JsEnv? js,
}) {
  if (template.isEmpty) return template;
  final eng = TemplateEngine(
    vars: vars,
    encoder: _encoderFor(charset),
    jsEval: (js != null && JsBridge.available)
        ? (expr, _) => JsBridge.evalCode(
              expr,
              env: js.copyWith(vars: {...?js.vars, ...vars}),
            )
        : null,
  );
  return eng.render(template, encodeValues: true);
}

String Function(String) _encoderFor(String? charset) {
  final cs = (charset ?? '').toLowerCase();
  final gbkFamily = cs.contains('gbk') ||
      cs.contains('gb2312') ||
      cs.contains('gb18030') ||
      cs.contains('gb-2312') ||
      cs.contains('cp936');
  if (!gbkFamily) return Uri.encodeComponent;
  return (v) {
    try {
      final bytes = gbk.encode(v);
      final buf = StringBuffer();
      for (final b in bytes) {
        buf.write('%');
        buf.write(b.toRadixString(16).padLeft(2, '0').toUpperCase());
      }
      return buf.toString();
    } catch (_) {
      return Uri.encodeComponent(v);
    }
  };
}

/// 把（已渲染的）地址补全为绝对地址。
///
/// - 已是 `http(s)://` → 原样返回；
/// - 以 `/` 开头或相对路径 → 以 [baseUrl] 为基准解析（先清理 `##分组` 尾缀）。
String resolveUrl(String url, String baseUrl) {
  final u = url.trim();
  if (u.isEmpty) return u;
  if (u.startsWith('http://') || u.startsWith('https://')) return u;
  // data: URI 是脚本回传的「本地响应」，不能被 baseUrl 解析掉（上游同语义）。
  if (u.startsWith('data:')) return u;
  final base = RuleAnalyzer.cleanBaseUrl(baseUrl);
  if (base.isEmpty) return u;
  try {
    return Uri.parse(base).resolve(u).toString();
  } catch (_) {
    return u;
  }
}

/// 一步到位：解析 + 渲染 + 补全。
///
/// [baseUrl] 通常是书源的 `bookSourceUrl`。
/// [js] 提供且引擎可用时：JS 段真执行、`{{…}}` 支持 JS 兜底、页列表 `<a,b,c>` 生效。
/// 选项中的 body/headers 也一并处理：
/// - body 模板按「原始值」渲染（JSON 请求体不能百分号编码）；
/// - headers 若为 JSON 字符串则解码为 Map。
UrlTemplate buildRequest(
  String rawTemplate,
  String baseUrl,
  Map<String, dynamic> vars, {
  JsEnv? js,
}) {
  var s = rawTemplate.trim();
  if (RuleAnalyzer.hasJs(s) && js != null && JsBridge.available) {
    // P0：执行 JS 段（对齐 legado AnalyzeUrl.analyzeJs）
    s = _evalJsBlocks(s, js, vars);
    if (JsBridge.traceAjax) {
      print('[url] js raw=${s.length}字 ${s.length > 300 ? s.substring(0, 300) : s}');
    }
  } else {
    // 无引擎降级：剥离前置 <js> 块；尾随 @js: 丢弃（用于脚本前的地址尽力请求）
    s = _stripJsPrelude(s);
    s = RuleAnalyzer.stripTrailingJs(s);
  }
  // 规则（多半是 JS）可能直接返回请求描述对象：{method,url,body,…}
  s = _urlObjectToTemplate(s) ?? s;
  final split = _splitOptions(s, vars);
  var t = _withLegacyOptions(UrlTemplate(split.$1, split.$2));
  var options = Map<String, dynamic>.from(t.options);
  var rendered = renderUrlTemplate(t.url, vars,
      charset: options['charset']?.toString(), js: js);
  if (options.isEmpty) {
    // `{{js(...)}}` 的返回值本身可能带请求选项（`url,{"method":…}`，如 纸间）：
    // 渲染后若才发现选项，就地再拆一次，避免整串被当成 URL 转义。
    final re = _splitOptions(rendered, vars);
    if (re.$2.isNotEmpty) {
      rendered = re.$1;
      t = _withLegacyOptions(UrlTemplate(rendered, re.$2));
      options = Map<String, dynamic>.from(t.options);
      rendered = t.url;
    }
  }
  // P0：阅读页列表 `<url1,url2,…>`（legado pagePattern；{{}} 替换后按 page 选取）
  var url = _applyPageList(rendered, vars['page']);
  url = resolveUrl(url, baseUrl);
  if (options.containsKey('body')) {
    options['body'] = _renderBody(options['body'], vars);
  }
  final hs = options['headers'];
  if (hs is String && hs.trim().isNotEmpty) {
    try {
      final d = jsonDecode(hs);
      if (d is Map) options['headers'] = d;
    } catch (_) {
      // 非法 JSON 头：保持原样交给上层
    }
  }
  return UrlTemplate(url, options);
}

/// 执行 URL 模板中的 JS 段（对齐 legado `AnalyzeUrl.analyzeJs`）：
/// `result` 初值 = 整串；文本段 `text.replace("@result", result)`（无占位则整体替换）；
/// JS 段 `evalJS(code, result)`，脚本返回串作为新的 `result`。
String _evalJsBlocks(String input, JsEnv js, Map<String, dynamic> vars) {
  final segs = RuleAnalyzer.splitJs(input);
  if (!segs.any((s) => s.isJs)) return input;
  final env = js.copyWith(vars: {...?js.vars, ...vars});
  var result = input;
  for (final seg in segs) {
    if (seg.isJs) {
      result = JsBridge.evalCode(seg.text, env: env, input: result) ?? '';
    } else {
      final t = seg.text.trim();
      if (t.isNotEmpty) result = t.replaceAll('@result', result);
    }
  }
  return result;
}

/// 页列表 `<url1,url2,…>`：按 `page` 选第 page 项（越界取末项）。
///
/// page 非法（null / 非数字）时原样返回（legado：page 为空则不替换）。
String _applyPageList(String s, dynamic page) {
  if (!s.contains('<') || page is! num) return s;
  final p = page.toInt();
  return s.replaceAllMapped(RegExp(r'<(.*?)>', dotAll: true), (m) {
    final items = m.group(1)!.split(',').map((e) => e.trim()).toList();
    if (items.isEmpty) return '';
    var idx = p - 1;
    if (idx < 0) idx = 0;
    if (idx >= items.length) idx = items.length - 1;
    return items[idx];
  });
}

dynamic _renderBody(dynamic body, Map<String, dynamic> vars) {
  if (body is String) return _renderRaw(body, vars);
  if (body is Map) {
    return {
      for (final e in body.entries)
        e.key.toString(): _renderBody(e.value, vars),
    };
  }
  if (body is List) return [for (final v in body) _renderBody(v, vars)];
  return body;
}
