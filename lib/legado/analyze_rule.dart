// 规则求值引擎：把「规则字符串 + 文档」的完整求值流程串起来。
//
// 求值顺序（对照 Legado 的公开行为，独立实现）：
//   1. `||` 拆分备选：从左到右求值，取第一个非空结果（兜底）；
//   2. 每条备选内 `&&` 串联：各段结果用换行拼接；
//   3. 每段规则先拆 `##` 替换链（只作用于字符串结果）；
//   4. 按模式分派：`@json:` / `@xpath:` / `@css:` / `@regex:`，
//      无前缀时：JSON 文档 → JSONPath；HTML 文档 → CSS（疑似正则才走正则）。
//
// 引擎无状态、可重复求值；文档只解析一次并缓存。
import 'dart:convert';

import 'package:html/dom.dart' as dom;
import 'package:xml/xml.dart' as xml;

import 'analyze_css.dart';
import 'analyze_json.dart';
import 'analyze_regex.dart';
import 'analyze_template.dart';
import 'analyze_xpath.dart';
import 'js_engine.dart';
import 'rule_analyzer.dart';

/// HTML → XML 宽松解析（容错常见的不合法写法，供 XPath 使用）。
xml.XmlDocument? parseXmlLoose(String html) {
  if (html.trim().isEmpty) return null;
  try {
    return xml.XmlDocument.parse(html);
  } catch (_) {
    // 继续尝试清洗
  }
  var s = html;
  // 注释与 DOCTYPE（XML 注释不允许 `--`；DTD 声明对包内解析器也无意义）
  s = s.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');
  s = s.replaceAll(RegExp(r'<!DOCTYPE[^>]*>', caseSensitive: false), '');
  // script/style 内容常含裸 `<`、`&&`：包 CDATA（内含 `]]>` 时先拆开）
  s = s.replaceAllMapped(
    RegExp(r'(<(?:script|style)\b[^>]*>)([\s\S]*?)(</(?:script|style)>)',
        caseSensitive: false),
    (m) {
      final body = (m.group(2) ?? '').replaceAll(']]>', ']] >');
      return '${m.group(1)}<![CDATA[$body]]>${m.group(3)}';
    },
  );
  // 自闭合空元素（HTML void 表）
  s = s.replaceAllMapped(
    RegExp(
        r'<(br|hr|img|input|meta|link|area|base|col|embed|param|source|track|wbr)([^<>]*?)(/?)>',
        caseSensitive: false),
    (m) {
      if ((m.group(3) ?? '').isNotEmpty) return m.group(0)!;
      final attrs = m.group(2) ?? '';
      if (attrs.trimRight().endsWith('/')) return m.group(0)!;
      return '<${m.group(1)}$attrs/>';
    },
  );
  // 常见 HTML 命名实体 → 直出字符（XML 只预定义五个实体）
  s = s.replaceAllMapped(RegExp(r'&([a-zA-Z][a-zA-Z0-9]*);'), (m) {
    return _htmlEntities[(m.group(1) ?? '').toLowerCase()] ?? m.group(0)!;
  });
  // 裸 & 转义
  s = s.replaceAll(
    RegExp(r'&(?!(#\d+|#x[0-9a-fA-F]+|[a-zA-Z][a-zA-Z0-9]*);)'),
    '&amp;',
  );
  try {
    return xml.XmlDocument.parse(s);
  } catch (_) {
    // 兜底：容错 HTML DOM → 规范 XML（把 HTML5 宽松解析的容错全部吸收）
    try {
      return xml.XmlDocument.parse(serializeDomToXml(parseHtml(html)));
    } catch (_) {
      return null;
    }
  }
}

/// HTML 空元素标签（XML 序列化时自闭合）。
const _voidTags = {
  'br', 'hr', 'img', 'input', 'meta', 'link', 'area', 'base',
  'col', 'embed', 'param', 'source', 'track', 'wbr',
};

/// 常见 HTML 命名实体映射（避免 XML 解析器拒绝未定义实体）。
const _htmlEntities = {
  'nbsp': '\u00a0', 'ldquo': '\u201c', 'rdquo': '\u201d', 'lsquo': '\u2018',
  'rsquo': '\u2019', 'middot': '\u00b7', 'hellip': '\u2026', 'mdash': '\u2014',
  'ndash': '\u2013', 'times': '\u00d7', 'divide': '\u00f7', 'laquo': '\u00ab',
  'raquo': '\u00bb', 'copy': '\u00a9', 'reg': '\u00ae', 'trade': '\u2122',
  'bull': '\u2022', 'sect': '\u00a7', 'deg': '\u00b0', 'plusmn': '\u00b1',
  'sup2': '\u00b2', 'sup3': '\u00b3', 'euro': '\u20ac', 'pound': '\u00a3',
  'yen': '\u00a5', 'cent': '\u00a2', 'larr': '\u2190', 'rarr': '\u2192',
  'uarr': '\u2191', 'darr': '\u2193', 'infin': '\u221e', 'prime': '\u2032',
};

/// 把容错解析出的 HTML DOM 序列化为规范 XML（XPath 兜底路径）。
String serializeDomToXml(dom.Node root) {
  final b = StringBuffer();
  void write(dom.Node n) {
    if (n is dom.Element) {
      final tag = (n.localName ?? 'div').toLowerCase();
      b.write('<$tag');
      n.attributes.forEach((k, v) {
        b.write(' ${k.toString().toLowerCase()}="${_xmlAttrEscape(v)}"');
      });
      if (_voidTags.contains(tag)) {
        b.write('/>');
        return;
      }
      b.write('>');
      if (tag == 'script' || tag == 'style') {
        b.write('<![CDATA[');
        for (final c in n.nodes) {
          if (c is dom.Text) b.write(c.text.replaceAll(']]>', ']] >'));
        }
        b.write(']]>');
      } else {
        for (final c in n.nodes) {
          write(c);
        }
      }
      b.write('</$tag>');
    } else if (n is dom.Text) {
      b.write(n.text
          .replaceAll('&', '&amp;')
          .replaceAll('<', '&lt;')
          .replaceAll('>', '&gt;'));
    } else if (n is dom.Document || n is dom.DocumentFragment) {
      for (final c in n.nodes) {
        write(c);
      }
    }
    // 注释等其它节点丢弃
  }

  write(root);
  return b.toString();
}

String _xmlAttrEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// 规则求值器。
class AnalyzeRule {
  AnalyzeRule(this.document,
      {String baseUrl = '', Map<String, dynamic>? vars, this.js})
      : baseUrl = RuleAnalyzer.cleanBaseUrl(baseUrl),
        vars = vars ?? <String, dynamic>{};

  /// 文档文本（HTML 或 JSON；也可为普通文本）。
  final String? document;

  /// 书源主地址（补全相对链接用；已清理 `#` 尾缀）。
  final String baseUrl;

  /// 调用方注入的上下文变量（如 `key` / `page` / `book`）。可在生命周期内补充。
  final Map<String, dynamic> vars;

  /// P0：书源 JS 环境（会话 / 书源上下文由服务层注入；为空时 JS 段按旧行为降级）。
  final JsEnv? js;

  /// `@put:` 注解写入的变量（`@get:` / `{{var}}` 读取）。
  final Map<String, String> _stored = {};

  dom.Document? _htmlDoc;
  bool _jsonTried = false;
  dynamic _jsonDoc;
  bool _xmlTried = false;
  xml.XmlDocument? _xmlDoc;

  /// init 求值结果（对齐 legado `AnalyzeRule.setContent(结果)` 的 content 覆盖）：
  /// JSON 对象（Map/List）保持原型；字符串整体作为新文档文本。
  dynamic _override;

  /// 文本形态的 content（init 覆盖为字符串时为覆盖值本身）。
  String? get _srcText => _override is String ? _override as String : document;

  /// init 覆盖的对象根。
  dynamic get _overrideRoot =>
      (_override is Map || _override is List) ? _override : null;

  /// JSON 求值根：init 对象覆盖优先，否则文档 JSON。
  dynamic get _jsonRoot => _overrideRoot ?? jsonDoc;

  /// 对齐 legado `AnalyzeRule.setContent(结果)`：把 init 结果设为后续规则的
  /// content（JSON 保持对象原型；字符串整体作为新文档文本）。
  void setContentObject(Object? obj) {
    if (obj == null) return;
    _override = obj;
    _htmlDoc = null;
    _jsonTried = false;
    _jsonDoc = null;
    _xmlTried = false;
    _xmlDoc = null;
  }

  /// 对齐 legado `AnalyzeRule.getElement`（init 语义）：求值规则并返回「对象」
  /// 结果——JSON 模式返回对象原型（Map/List/标量），JS 段返回脚本值；
  /// CSS/XPath 元素集不在此序列化（现网无依赖该行为的失败源）。
  Object? getRawElement(String ruleStr) {
    final r0 = ruleStr.trim();
    if (r0.isEmpty) return null;
    if (RuleAnalyzer.hasJs(r0)) return _evalJsSegmentsRaw(r0, null);
    final r = preprocess(r0);
    if (r.isEmpty) return null;
    final (mode, base) = RuleAnalyzer.parsePrefix(r);
    if (base.isEmpty) return null;
    var m = mode;
    if (m == RuleMode.auto) {
      m = (r.startsWith(r'$.') ||
              r.startsWith(r'$[') ||
              r.startsWith(r'$..') ||
              _jsonRoot != null)
          ? RuleMode.json
          : RuleMode.css;
    }
    if (m != RuleMode.json) return null;
    final root = _jsonRoot;
    if (root == null) return null;
    final res = jsonSelect(root, r);
    if (res.isEmpty) return null;
    if (res.length == 1) return res.first;
    return res;
  }

  /// 惰性解析 HTML。
  dom.Document get htmlDoc => _htmlDoc ??= parseHtml(_srcText ?? '');

  /// 惰性解析 JSON（文档不是 JSON 时返回 null）。
  dynamic get jsonDoc {
    if (!_jsonTried) {
      _jsonTried = true;
      final d = (_srcText ?? '').trim();
      if (d.startsWith('{') || d.startsWith('[')) {
        try {
          _jsonDoc = jsonDecode(d);
        } catch (_) {
          _jsonDoc = null;
        }
      }
    }
    return _jsonDoc;
  }

  /// 惰性解析 XML（供 XPath；失败返回 null）。
  xml.XmlDocument? get xmlDoc {
    if (!_xmlTried) {
      _xmlTried = true;
      _xmlDoc = parseXmlLoose(_srcText ?? '');
    }
    return _xmlDoc;
  }

  // ---------- 对外 API ----------

  /// 取单个字符串结果（`||` 兜底取第一个非空）。
  String? getString(String rule, {Object? ctx, bool isUrl = false}) {
    if (RuleAnalyzer.hasJs(rule)) {
      return _evalJsSegmentsString(rule, ctx);
    }
    return _getStringNoJs(rule, ctx: ctx, firstOnly: isUrl);
  }

  /// 不含 JS 段的常规求值（JS 桥回调复用此入口，避免重入引擎）。
  String? _getStringNoJs(String rule, {Object? ctx, bool firstOnly = false}) {
    final hadTpl = rule.contains('{{') || rule.contains(r'{$');
    rule = preprocess(rule, ctx: ctx);
    for (final alt in RuleAnalyzer.splitAlternatives(rule)) {
      final merged = _combinedStrings(alt, ctx);
      // isUrl（legado `getString(rule, isUrl=true)` → AnalyzeByJSoup.getString0）：
      // URL 类字段只取首个匹配，不做多值拼接。
      if (merged.isNotEmpty) {
        return firstOnly ? merged.first : merged.join('\n');
      }
    }
    // 兜底：模板渲染结果本身即规则值。
    // 真实源里 kind/lastChapter/updateTime/intro 等大量字段是纯模板
    // （如 `{{$.category}},{{$.finished}}`），渲染完不应再按 CSS 选择器二次求值。
    if (hadTpl) {
      final v = _literalFallback(rule);
      if (v != null) return v;
    }
    return null;
  }

  /// JS 段线程求值（对齐 legado `splitSourceRule` + `evalJS` 的 result 线程）：
  /// 首个 JS 段的 `result` = 文档原文（legado: `result = content`）；
  /// 文本段走常规流水线；JS 段结果作为之后段的输入（`sel@js:code` 即 CSS→JS）。
  String? _evalJsSegmentsString(String rule, Object? ctx) {
    final v = _evalJsSegmentsRaw(rule, ctx);
    final s = v?.toString();
    return (s == null || s.isEmpty) ? null : s;
  }

  /// 同上，但保留脚本最终值的原型（init 语义需要 Map/List 不被字符串化）。
  Object? _evalJsSegmentsRaw(String rule, Object? ctx) {
    final segs = RuleAnalyzer.splitJs(rule);
    if (!JsBridge.available) return _legacyJsDegrade(segs, ctx);
    // JSON 元素原件传给脚本（对齐 legado：result 为对象，而非字符串化的 JSON）
    Object? cur = (ctx is Map || ctx is List)
        ? ctx
        : (ctx != null ? _jsResultOf(ctx) : (_override ?? _srcText));
    var curCtx = ctx;
    var hasText = false;
    for (final seg in segs) {
      if (seg.isJs) {
        // legado：JS 源码里的 `{{...}}` 模板先按当前条目渲染（晋江系
        // `num='第{{$.chapterid}}章'` 内嵌在字符串字面量里）。
        var src = seg.text;
        if (src.contains('{{')) {
          src = _templates().render(src, encodeValues: false, ctx: curCtx);
        }
        final v = JsBridge.evalCode(src, env: _envWith(curCtx), input: cur);
        if (v == null) {
          // 脚本报错但有前置文本结论：退回旧降级（宁可用地址也不整链丢空）
          if (JsBridge.lastError != null && hasText) {
            final s0 = cur?.toString();
            if (s0 != null && s0.isNotEmpty) return s0;
          }
          return null; // 脚本失败：整链中止（legado: result ?: continue）
        }
        cur = v;
        curCtx = v;
      } else {
        final v = _getStringNoJs(seg.text, ctx: curCtx);
        if (v != null && v.isNotEmpty) {
          hasText = true;
          cur = v;
          curCtx = v;
        }
      }
    }
    return cur;
  }

  /// 无引擎降级：保留 JS 段之前文本段的结论（旧行为）。
  String? _legacyJsDegrade(List<JsSegment> segs, Object? ctx) {
    String? out;
    for (final seg in segs) {
      if (seg.isJs) continue;
      final v = _getStringNoJs(seg.text, ctx: ctx);
      if (v != null && v.isNotEmpty) out = v;
    }
    return out;
  }

  /// 为 JS 求值构造带上下文的派生环境（挂钩子；钩子走 no-JS 入口防重入）。
  JsEnv _envWith(Object? ctx) {
    final b = js;
    return JsEnv(
      scopeKey: b?.scopeKey ?? (baseUrl.isEmpty ? '#default' : baseUrl),
      sourceUrl: b?.sourceUrl ?? baseUrl,
      baseUrl: b?.baseUrl ?? baseUrl,
      sourceName: b?.sourceName ?? '',
      sourceHeader: b?.sourceHeader,
      sourceJson: b?.sourceJson,
      jsLib: b?.jsLib,
      book: b?.book ??
          (vars['book'] is Map
              ? Map<String, dynamic>.from(vars['book'] as Map)
              : null),
      chapter: b?.chapter ??
          (vars['chapter'] is Map
              ? Map<String, dynamic>.from(vars['chapter'] as Map)
              : null),
      title: b?.title ?? (vars['title'] is String ? vars['title'] as String : null),
      nextChapterUrl: b?.nextChapterUrl,
      session: b?.session,
      vars: Map<String, dynamic>.from(vars),
      getString: (r) => _getStringNoJs(r, ctx: ctx),
      getElement: (r) => _getStringNoJs(r, ctx: ctx),
      getElements: (r) => getElements(r, ctx: ctx).map(_elemHtml).toList(),
      getCookie: b?.getCookie,
    );
  }

  /// 元素 → outerHtml（`java.getElements` 回给脚本的形状）。
  static String _elemHtml(Object e) {
    if (e is dom.Element) return e.outerHtml;
    if (e is xml.XmlElement) return e.toXmlString();
    return '$e';
  }

  /// 模板渲染后的字面值兜底（应用 `##` 替换链；整条 JS 规则除外）。
  String? _literalFallback(String rendered) {
    final t = rendered.trim();
    if (t.isEmpty) return null;
    final lower = t.toLowerCase();
    if (lower.startsWith('@js:') || lower.startsWith('<js>')) return null;
    final parts = RuleAnalyzer.splitReplaces(t);
    var v = parts.base.trim();
    if (v.isEmpty) return null;
    if (parts.chains.isNotEmpty) v = RuleAnalyzer.applyReplaces(v, parts.chains);
    return v.isEmpty ? null : v;
  }

  /// 规则列表的顺序前缀（legado AnalyzeRule）：`-` 反转，`+` 显式正序。
  ///
  /// 目录规则最常见（`-@js:...` 把最新章节排在前面、`-class.list@tag.a` 同理）。
  /// 去掉前缀再求值，最后整体反转，语义与上游一致。
  static ({String rule, bool reverse}) _splitOrder(String rule) {
    final t = rule.trimLeft();
    if (t.startsWith('-')) {
      return (rule: t.substring(1).trimLeft(), reverse: true);
    }
    if (t.startsWith('+')) {
      return (rule: t.substring(1).trimLeft(), reverse: false);
    }
    return (rule: rule, reverse: false);
  }

  /// 取字符串列表（`||` 兜底取第一个非空列表）。
  List<String> getStrings(String rule, {Object? ctx}) {
    final ord = _splitOrder(rule);
    final out = _getStringsInner(ord.rule, ctx);
    return ord.reverse ? out.reversed.toList() : out;
  }

  List<String> _getStringsInner(String rule, Object? ctx) {
    if (RuleAnalyzer.hasJs(rule)) {
      final s = _evalJsSegmentsString(rule, ctx);
      if (s == null || s.isEmpty) return const [];
      return s.split('\n');
    }
    final hadTpl = rule.contains('{{') || rule.contains(r'{$');
    rule = preprocess(rule, ctx: ctx);
    for (final alt in RuleAnalyzer.splitAlternatives(rule)) {
      final out = _combinedStrings(alt, ctx);
      if (out.isNotEmpty) return out;
    }
    if (hadTpl) {
      final v = _literalFallback(rule);
      if (v != null) return [v];
    }
    return const [];
  }

  /// 取元素列表（用于 bookList 这类“再迭代”的规则；CSS / XPath 皆可）。
  List<Object> getElements(String rule, {Object? ctx}) {
    final ord = _splitOrder(rule);
    final out = _getElementsInner(ord.rule, ctx);
    return ord.reverse ? out.reversed.toList() : out;
  }

  List<Object> _getElementsInner(String rule, Object? ctx) {
    if (RuleAnalyzer.hasJs(rule)) {
      final s = _evalJsSegmentsString(rule, ctx);
      if (s == null || s.isEmpty) return const [];
      return s.split('\n');
    }
    rule = preprocess(rule, ctx: ctx);
    for (final alt in RuleAnalyzer.splitAlternatives(rule)) {
      final raw = _combinedRaw(alt, ctx);
      final els =
          raw.where((o) => o is dom.Element || o is xml.XmlElement).toList();
      if (els.isNotEmpty) return els;
    }
    return const [];
  }

  /// 取原始结果列表（保留原型：DOM 元素 / XML 节点 / JSON 值 / 字符串）。
  List<Object> getRawList(String rule, {Object? ctx}) {
    final ord = _splitOrder(rule);
    final out = _getRawListInner(ord.rule, ctx);
    return ord.reverse ? out.reversed.toList() : out;
  }

  List<Object> _getRawListInner(String rule, Object? ctx) {
    if (RuleAnalyzer.hasJs(rule)) {
      // 条目保持字符串原型（legado：content 为字符串，JsonPath 字段规则
      // 自行 parse，JS 字段规则直接拿到 JSON 串 `JSON.parse(result)`）。
      return _rawItemsOf(_evalJsSegmentsRaw(rule, ctx));
    }
    rule = preprocess(rule, ctx: ctx);
    for (final alt in RuleAnalyzer.splitAlternatives(rule)) {
      final raw = _combinedRaw(alt, ctx);
      if (raw.isNotEmpty) return raw;
    }
    return const [];
  }

  /// JS 列表规则结果 → 条目列表：JSON 数组/对象还原为 Map 条目
  /// （对齐 legado：JS 对象列表逐项 `setContent(item)` 后按裸键取属性）。
  List<Object> _rawItemsOf(Object? v) {
    if (v is List) return List<Object>.from(v);
    if (v is Map) return [v];
    final s = v?.toString() ?? '';
    if (s.isEmpty) return const [];
    final t = s.trim();
    if (t.startsWith('[') || t.startsWith('{')) {
      try {
        final d = jsonDecode(t);
        if (d is List) return List<Object>.from(d);
        if (d is Map) return [d];
      } catch (_) {}
    }
    return s.split('\n');
  }

  // ---------- 预处理（@put / @get / {{}} 模板） ----------

  TemplateEngine _templates() => TemplateEngine(
        // JS `java.put` 写入的会话变量并入查找源（legado：java.put/get 与
        // `@get:/{{var}}` 同源——book/source 变量表；如得间 `bid` 由目录地址
        // 脚本写入、章网址模板 `@get:{bid}` 读取）。
        vars: {...?js?.session?.vars, ...vars},
        store: _stored,
        baseUrl: baseUrl,
        jsonRoot: _jsonRoot,
        evalRule: (r, c) => _evalStringPiece(r, c),
        // legado：`{{}}` 内容非规则时按 JS 求值，`result` 绑定 = 链上当前结果
        // （如搜索 bookUrl 的 `...?bookid={{result}}` 紧随 `<js>` 段）。
        jsEval: JsBridge.available
            ? (expr, c) => JsBridge.evalCode(expr, env: _envWith(c), input: c)
            : null,
      );

  /// 规则前置处理：
  /// 1) `@put:{k:规则,…}` 求值后存入变量，并从规则串中移除；
  /// 2) `@get:{k}` 内联替换为已存变量的值（可出现在 URL 中间）；
  /// 3) 尾随 `@js:…` 脚本剥离（无 JS 引擎：保留脚本前的中间结果）；
  /// 4) `{{表达式}}` / `{$JSONPath}` 模板求值。
  static final RegExp _putRe = RegExp(r'@put:\s*\{([^{}]*)\}');
  static final RegExp _getRe = RegExp(r'@get:\s*\{([^{}]*)\}');

  String preprocess(String rule, {Object? ctx}) {
    if (rule.isEmpty) return rule;
    if (!rule.contains('@') && !rule.contains('{{') && !rule.contains(r'{$')) {
      return rule;
    }
    var r = rule;
    if (r.contains('@put:')) {
      r = r.replaceAllMapped(_putRe, (m) {
        _applyPut(m.group(1)!, ctx);
        return '';
      });
    }
    if (r.contains('@get:')) {
      r = r.replaceAllMapped(_getRe, (m) {
        final k = m.group(1)!.trim();
        // legado：`@get:{k}` 读 put 变量袋（ruleData.variableMap）优先于
        // 绑定注入（`book` 可同时是绑定对象与 put 键，两命名空间同名不互扰）。
        final bucket = _stored[k] ?? js?.session?.vars[k];
        if (bucket != null) return bucket;
        final v = _templates().lookup(k);
        return v == null ? '' : v.toString();
      });
    }
    r = RuleAnalyzer.stripTrailingJs(r);
    if (r.contains('{{') || r.contains(r'{$')) {
      r = _templates().render(r, encodeValues: false, ctx: ctx);
    }
    return r;
  }

  void _applyPut(String content, Object? ctx) {
    for (final pair in _splitTopLevel(content, ',')) {
      final i = pair.indexOf(':');
      if (i <= 0) continue;
      var k = pair.substring(0, i).trim();
      var v = pair.substring(i + 1).trim();
      if (_quoted(k)) k = k.substring(1, k.length - 1);
      if (_quoted(v)) v = v.substring(1, v.length - 1);
      if (k.isEmpty) continue;
      _stored[k] = getString(v, ctx: ctx) ?? '';
      // legado put/get 同桶（java.put 与 @put 同 ruleData）——镜像进会话变量，
      // 会话变量再由服务层按书快照/回注，实现跨阶段（搜索→详情）`@get:`。
      final s = js?.session;
      if (s != null) s.vars[k] = _stored[k]!;
    }
  }

  static bool _quoted(String s) =>
      s.length >= 2 &&
      ((s.startsWith('"') && s.endsWith('"')) ||
          (s.startsWith("'") && s.endsWith("'")));

  /// 顶层拆分（忽略引号与括号内部）。
  static List<String> _splitTopLevel(String s, String sep) {
    final out = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    var quote = '';
    for (var i = 0; i < s.length; i++) {
      final ch = s[i];
      if (quote.isNotEmpty) {
        buf.write(ch);
        if (ch == quote && s[i - 1] != r'\') quote = '';
        continue;
      }
      if (ch == '"' || ch == "'") {
        quote = ch;
        buf.write(ch);
        continue;
      }
      if (ch == '(' || ch == '[' || ch == '{') depth++;
      if (ch == ')' || ch == ']' || ch == '}') depth--;
      if (ch == sep && depth == 0) {
        out.add(buf.toString());
        buf.clear();
        continue;
      }
      buf.write(ch);
    }
    if (buf.isNotEmpty) out.add(buf.toString());
    return out;
  }

  /// 应用内容净化规则（`ruleContent.replaceRegex`：以 `##` 开头的替换链）。
  ///
  /// 模板（如 `{{book.name}}`）先按当前上下文渲染；渲染不完整则放弃净化，
  /// 宁可不处理也不误删正文。
  String applyReplaceRegex(String text, String? replaceRegex) {
    final rr = replaceRegex?.trim() ?? '';
    if (rr.isEmpty || text.isEmpty) return text;
    final rendered = preprocess(rr);
    if (rendered.contains('{{')) return text;
    final parts = RuleAnalyzer.splitReplaces('x$rendered');
    if (parts.chains.isEmpty) return text;
    return RuleAnalyzer.applyReplaces(text, parts.chains);
  }

  // ---------- 内部求值 ----------

  List<Object> _evalPiece(String piece, Object? ctx, {bool elementsMode = false}) {
    final parts = RuleAnalyzer.splitReplaces(piece);
    final (mode, base) = RuleAnalyzer.parsePrefix(parts.base);
    List<Object> res;
    if (base.isEmpty) {
      // 空 base（如 `##p##r###`）：对齐 legado —— result 保持为 content 本身，
      // 链正则作用于 `result.toString()`（元素 = outerHtml）。
      final t = _ctxOuter(ctx);
      res = t == null ? const [] : [t];
    } else if (ctx is Map && mode == RuleMode.auto && _bareKeyRe.hasMatch(base)) {
      // legado：content 为 JS 对象（NativeObject）时，单参数规则 = 键值直接访问
      // （如 SF 轻小说 m 站 `chapterName: k` / `chapterUrl: v`）。
      final v = ctx[base];
      final s = v == null ? null : jsonValueToString(v);
      res = (s == null || s.isEmpty) ? const [] : [s];
    } else {
      res = _evalBase(base, mode, ctx, elementsMode: elementsMode);
    }
    if (parts.chains.isEmpty) return res;
    return res
        .map((o) => RuleAnalyzer.applyReplaces(_toStrRaw(o) ?? '', parts.chains))
        .toList();
  }

  String? _evalStringPiece(String piece, Object? ctx) {
    for (final o in _evalPiece(piece, ctx)) {
      final s = _toStr(o);
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  List<String> _evalStringListPiece(String piece, Object? ctx) {
    final out = <String>[];
    for (final o in _evalPiece(piece, ctx)) {
      final s = _toStr(o);
      if (s != null && s.isNotEmpty) out.add(s);
    }
    return out;
  }

  /// `&&`（串接）/`%%`（拉链）组合求值：返回合并后的字符串列表。
  /// 对齐 legado：`%%` 按第 0 列表长度轮转、逐列表取同下标项。
  List<String> _combinedStrings(String alt, Object? ctx) {
    final comb = RuleAnalyzer.splitCombine(alt);
    if (comb == null) return _evalStringListPiece(alt, ctx);
    final lists = [for (final p in comb.$2) _evalStringListPiece(p, ctx)];
    return comb.$1 == '%%' ? _zip(lists) : [for (final l in lists) ...l];
  }

  /// 同上，保留原型（DOM 元素 / XML 节点 / JSON 值 / 字符串）。
  List<Object> _combinedRaw(String alt, Object? ctx) {
    final comb = RuleAnalyzer.splitCombine(alt);
    if (comb == null) return _evalPiece(alt, ctx, elementsMode: true);
    final lists = [
      for (final p in comb.$2) _evalPiece(p, ctx, elementsMode: true),
    ];
    return comb.$1 == '%%' ? _zip(lists) : [for (final l in lists) ...l];
  }

  /// round-robin 拉链合并（legado `%%` 语义）。
  static List<T> _zip<T>(List<List<T>> lists) {
    if (lists.isEmpty) return const [];
    final out = <T>[];
    for (var i = 0; i < lists[0].length; i++) {
      for (final l in lists) {
        if (i < l.length) out.add(l[i]);
      }
    }
    return out;
  }

  List<Object> _evalBase(String rule, RuleMode mode, Object? ctx,
      {bool elementsMode = false}) {
    var m = mode;
    if (m == RuleMode.auto) {
      if (rule.startsWith(r'$.') ||
          rule.startsWith(r'$[') ||
          rule.startsWith(r'$..')) {
        m = RuleMode.json;
      } else if (rule.startsWith('http://') || rule.startsWith('https://')) {
        // 字面地址（模板已在 preprocess 渲染）：直接作为字符串结果，
        // 避免被当作 CSS 选择器求值而静默变空。
        return [rule];
      } else if (rule.startsWith('//') && xmlDoc != null) {
        // 裸 XPath 规则（`//div[@id=…]`）——书源里远多于显式 `@xpath:` 前缀写法
        m = RuleMode.xpath;
      } else if (rule.startsWith('/') &&
          xmlDoc != null &&
          (rule.contains('[') || rule.contains('@'))) {
        m = RuleMode.xpath;
      } else if (jsonDoc != null || _overrideRoot != null) {
        m = RuleMode.json;
      } else if (looksLikeRegex(rule)) {
        m = RuleMode.regex;
      } else {
        m = RuleMode.css;
      }
    }
    switch (m) {
      case RuleMode.css:
        if (ctx is xml.XmlElement) {
          final shim = _xmlCssShim(ctx, rule, elementsMode);
          if (shim != null) return shim;
        }
        final node = _ctxDomNode(ctx);
        return evalCss(node, parseCssStages(rule, elementsMode: elementsMode));
      case RuleMode.json:
        final root = _ctxJson(ctx);
        if (root == null) return const [];
        return List<Object>.from(jsonSelect(root, rule));
      case RuleMode.xpath:
        final doc = xmlDoc;
        if (doc == null) return const [];
        final xmlCtx = _ctxXml(ctx) ?? doc;
        final r = evalXPath(xmlCtx, rule);
        // 列表场景保留元素原型：逐条规则（chapterName/chapterUrl）需要对元素再做
        // 二级求值（对齐 legado：XPath 与 CSS 共用同一批 jsoup 节点）。
        if (elementsMode && r.elements.isNotEmpty) {
          return List<Object>.from(r.elements);
        }
        return r.strings.isEmpty
            ? List<Object>.from(r.elements)
            : List<Object>.from(r.strings);
      case RuleMode.regex:
        final text = _ctxText(ctx) ?? _srcText ?? '';
        return regexExtract(text, rule);
      case RuleMode.auto:
        return const [];
    }
  }

  // ---------- 上下文适配 ----------

  /// XPath 元素 → html 片段文档缓存（同一条目上的 name/url 等多个字段规则
  /// 复用同一次解析，避免每字段各解析一遍片段）。
  final Expando<dom.Document> _fragCache = Expando<dom.Document>();

  /// 字符串条目（JS 列表规则返回的 `<a ...>` 片段）→ 片段文档缓存。
  /// 目录规则常把 JS 拼好的 `<a>` 串当条目，字段规则 `a@text`/`a@href`
  /// 必须在这段片段里找；退回整页会把页面所有链接当章节（静默错结果）。
  final Map<String, dom.Document> _strFragCache = <String, dom.Document>{};

  dom.Node _ctxDomNode(Object? ctx) {
    if (ctx is dom.Node) return ctx;
    if (ctx is String) {
      return _strFragCache.putIfAbsent(ctx, () {
        final t = ctx;
        if (t.contains('<') && t.contains('>')) return parseHtml(t);
        // 纯文本条目：包成单元素，CSS 选择返回空（而不是整页），
        // 需要文本的规则走 `text`/regex 分支。
        return parseHtml('<pre>${const HtmlEscape().convert(t)}</pre>');
      });
    }
    if (ctx is xml.XmlElement) {
      // XPath 条目上的 CSS 习惯字段规则（`a@text` / `a@href`）：
      // 限定在该条目内解析，而不是退回整页（否则每条拿到全页所有 a，
      // 目录里各章同名同地址再被去重压成一章——静默错结果）。
      return _fragCache[ctx] ??= parseHtml(ctx.toXmlString());
    }
    return htmlDoc;
  }

  dynamic _ctxJson(Object? ctx) {
    if (ctx is Map || ctx is List) return ctx;
    // legado：JSON 条目以「字符串」形式存进 content 时（JS 列表规则返回
    // JSON.stringify 数组），JsonPath 规则会把它当 JSON 重新解析再取值。
    if (ctx is String) {
      final t = ctx.trim();
      if (t.length > 1 &&
          ((t.startsWith('{') && t.endsWith('}')) ||
              (t.startsWith('[') && t.endsWith(']')))) {
        try {
          final d = jsonDecode(t);
          if (d is Map || d is List) return d;
        } catch (_) {}
      }
      return null;
    }
    return _jsonRoot;
  }

  xml.XmlNode? _ctxXml(Object? ctx) {
    if (ctx is xml.XmlNode) return ctx;
    return null;
  }

  String? _ctxText(Object? ctx) {
    if (ctx == null) return null;
    if (ctx is String) return ctx;
    if (ctx is dom.Element) {
      final t = RuleAnalyzer.collapseSpaces(ctx.text);
      return t.isEmpty ? null : t;
    }
    if (ctx is xml.XmlElement) {
      final t = RuleAnalyzer.collapseSpaces(ctx.innerText);
      return t.isEmpty ? null : t;
    }
    if (ctx is num || ctx is bool) return ctx.toString();
    return null;
  }

  /// 空 base 链的输入：元素 → outerHtml（对齐 legado：`result.toString()`，
  /// 即 jsoup Element.toString()=outerHtml）；字符串 → 自身；无 ctx → 整页。
  String? _ctxOuter(Object? ctx) {
    if (ctx == null) return _srcText;
    if (ctx is String) return ctx;
    if (ctx is dom.Element) return ctx.outerHtml;
    if (ctx is xml.XmlElement) return ctx.toXmlString();
    if (ctx is Map || ctx is List) return jsonValueToString(ctx);
    if (ctx is num || ctx is bool) return ctx.toString();
    return ctx.toString();
  }

  static const _shimExtractors = {'text', 'all', 'html', 'owntext', 'textnodes'};

  /// 裸键规则（`k` / `v` / `text`）：JS 对象 content 上的直接键访问用。
  static final RegExp _bareKeyRe = RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$');

  /// XPath 元素上下文上的 CSS 层规则（裸属性名 / 提取器关键字）。
  ///
  /// 对齐 legado：XPath 与 CSS 共用同一批 jsoup 节点，`chapterUrl: href`、
  /// `chapterName: text` 这类逐条规则对 XPath 元素同样成立。
  /// 返回 null 表示不走 shim（继续按原 CSS 路径求值）。
  List<Object>? _xmlCssShim(xml.XmlElement el, String rule, bool elementsMode) {
    final r = rule.trim();
    final low = r.toLowerCase();
    if (!elementsMode && _shimExtractors.contains(low)) {
      switch (low) {
        case 'text':
        case 'all':
          final t = RuleAnalyzer.collapseSpaces(el.innerText);
          return t.isEmpty ? const [] : [t];
        case 'textnodes':
          final out = <String>[];
          for (final n in el.children) {
            if (n is xml.XmlText) {
              final t = RuleAnalyzer.collapseSpaces(n.value);
              if (t.isNotEmpty) out.add(t);
            }
          }
          return out;
        case 'owntext':
          final buf = StringBuffer();
          for (final n in el.children) {
            if (n is xml.XmlText) buf.write(n.value);
          }
          final t = RuleAnalyzer.collapseSpaces(buf.toString());
          return t.isEmpty ? const [] : [t];
        case 'html':
          final t = el.innerXml.trim();
          return t.isEmpty ? const [] : [t];
      }
    }
    if (RegExp(r'^[A-Za-z_][\w:-]*$').hasMatch(r)) {
      final v = el.getAttribute(r);
      if (v != null && v.trim().isNotEmpty) return [v.trim()];
    }
    // CSS 习惯字段规则：`a@text` / `a@href` / `.cls@attr` / `#id@attr` /
    // 末段裸标签 `tag`（取首个匹配子元素的文本）。命中即免片段解析。
    final m = RegExp(
      r'^(?:([A-Za-z_][\w:-]*)|\.([\w-]+)|#([\w-]+))(?:@([\w:-]+))?$',
    ).firstMatch(r);
    if (m != null) {
      final tag = m.group(1);
      final cls = m.group(2);
      final id = m.group(3);
      final attr = m.group(4);
      Iterable<xml.XmlElement> sel = const [];
      if (tag != null) {
        sel = tag == '*'
            ? el.descendantElements
            : el.descendantElements
                .where((e) => e.name.local == tag || e.name.toString() == tag);
      } else if (cls != null) {
        sel = el.descendantElements.where(
          (e) => (e.getAttribute('class') ?? '').split(RegExp(r'\s+')).contains(cls),
        );
      } else if (id != null) {
        sel = el.descendantElements
            .where((e) => (e.getAttribute('id') ?? '') == id);
      }
      final first = sel.isEmpty ? null : sel.first;
      if (first != null) {
        if (attr == null) {
          final t = RuleAnalyzer.collapseSpaces(first.innerText);
          return t.isEmpty ? const [] : [t];
        }
        if (attr == 'text') {
          final t = RuleAnalyzer.collapseSpaces(first.innerText);
          return t.isEmpty ? const [] : [t];
        }
        final v = first.getAttribute(attr);
        if (v != null && v.trim().isNotEmpty) return [v.trim()];
        return const [];
      }
    }
    return null;
  }

  /// JS `result` 绑定：元素 → outerHtml（对齐 legado：jsoup `Element.toString()`
  /// 即 outerHtml，源脚本常用 `String(result).match(/>(.*?)</)` 取文本）；
  /// 其余 → 文本（空时退回整页 document）。
  Object? _jsResultOf(Object ctx) {
    if (ctx is dom.Element) {
      final h = ctx.outerHtml;
      return h.isEmpty ? _srcText : h;
    }
    if (ctx is xml.XmlElement) return ctx.toXmlString();
    return _toStr(ctx) ?? _srcText;
  }

  String? _toStr(Object o) {
    if (o is String) {
      final t = RuleAnalyzer.collapseSpaces(o);
      return t.isEmpty ? null : t;
    }
    if (o is dom.Element) {
      final t = RuleAnalyzer.collapseSpaces(o.text);
      return t.isEmpty ? null : t;
    }
    if (o is xml.XmlElement) {
      final t = RuleAnalyzer.collapseSpaces(o.innerText);
      return t.isEmpty ? null : t;
    }
    final v = jsonValueToString(o);
    return v;
  }

  /// 与 [_toStr] 同，但**不折叠空白**：`##` 替换链要看到原始换行/缩进
  /// （对齐 legado：链正则作用于原始 result 字符串，仅最终输出裁剪）。
  String? _toStrRaw(Object o) {
    String raw;
    if (o is String) {
      raw = o;
    } else if (o is dom.Element) {
      raw = o.text; // jsoup text() 语义本身就归一空白，保持原样
    } else if (o is xml.XmlElement) {
      raw = o.innerText;
    } else {
      raw = jsonValueToString(o) ?? '';
    }
    final t = raw.trim();
    return t.isEmpty ? null : t;
  }
}
