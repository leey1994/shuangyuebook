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

// ---------- 渲染与补全 ----------

/// 渲染模板变量（URL 语境：按 charset 百分号编码）。
///
/// [vars] 至少应包含 `key` 与 `page`；`searchKey` / `keyword` 会映射到 `key`。
String renderUrlTemplate(
  String template,
  Map<String, dynamic> vars, {
  String? charset,
}) {
  if (template.isEmpty) return template;
  final eng = TemplateEngine(vars: vars, encoder: _encoderFor(charset));
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
/// 选项中的 body/headers 也一并处理：
/// - body 模板按「原始值」渲染（JSON 请求体不能百分号编码）；
/// - headers 若为 JSON 字符串则解码为 Map。
UrlTemplate buildRequest(
  String rawTemplate,
  String baseUrl,
  Map<String, dynamic> vars,
) {
  var s = _stripJsPrelude(rawTemplate.trim());
  // 尾随 `@js:…`（对 URL 做签名/时间戳等变换）：无法执行 → 用脚本前的地址尽力请求
  s = RuleAnalyzer.stripTrailingJs(s);
  final split = _splitOptions(s, vars);
  final t = _withLegacyOptions(UrlTemplate(split.$1, split.$2));
  final options = Map<String, dynamic>.from(t.options);
  final charset = options['charset']?.toString();
  final rendered = renderUrlTemplate(t.url, vars, charset: charset);
  final url = resolveUrl(rendered, baseUrl);
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
