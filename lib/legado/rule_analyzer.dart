// 规则字符串解析工具（独立实现，语义对照 Legado 书源规则的公开行为）。
//
// 书源规则字符串的通用结构：
//   `A || B || C`         多个备选规则，从左到右取第一个非空结果（兜底）
//   `A && B`              串联拼接（两段结果直接相连）
//   `base##regex##rep`    结果替换链（可多组依次执行；末尾单段 = 删除匹配）
//   `base##@base64##`     把当前结果按 Base64 解码（部分站点把真实链接藏进
//                         data-* 属性，如基友书屋的 data-coXX 属性）
//   `@json: / @xpath: / @css:`  显式指定求值模式（无前缀时按文档类型自动分派）
//
// 注意：与 Legado 一致，`||` / `&&` / `##` 不做转义处理。
import 'dart:convert';

/// 求值模式。
enum RuleMode {
  /// 自动：按文档类型推断（JSON 文档 → JSONPath；其余 → CSS）。
  auto,
  css,
  json,
  xpath,
  regex,
}

/// 单条替换链：`pattern` 匹配 → 替换为 `replacement`（支持 `$1` 捕获组）。
class ReplaceChain {
  const ReplaceChain(this.pattern, this.replacement, {this.replaceFirst = false});

  final String pattern;
  final String replacement;

  /// 四段链 `base##p##r###`（legado `split("##").size > 3` → replaceFirst）：
  /// 取第一个匹配段做组展开，无匹配时结果为空串（legado 语义）。
  final bool replaceFirst;
}

/// 规则拆解结果：基础规则 + 替换链。
class RuleParts {
  const RuleParts(this.base, this.chains);

  final String base;
  final List<ReplaceChain> chains;

  bool get hasChains => chains.isNotEmpty;
}

/// JS 段：规则串按 legado `JS_PATTERN`（`<js>…</js> | @js:…`）切分后的片段。
class JsSegment {
  const JsSegment.text(this.text) : isJs = false;
  const JsSegment.js(this.text) : isJs = true;

  final bool isJs;
  final String text;
}

/// 规则字符串的解析工具集。
abstract final class RuleAnalyzer {
  static const String jsonPrefix = '@json:';
  static const String xpathPrefix = '@xpath:';
  static const String cssPrefix = '@css:';
  static const String regexPrefix = '@regex:';

  /// 顶层拆分 `||` 备选（忽略 `[](){}` 与引号内部的 `||`；去空白、忽略空段）。
  static List<String> splitAlternatives(String rule) => _splitTopLevel(rule, '||')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// 拆分 `&&` 串联（去空白、忽略空段）。
  static List<String> splitConcat(String rule) => _splitTopLevel(rule, '&&')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  /// 顶层 `&&` / `%%` 组合拆分（对齐 legado `splitRule("&&","||","%%")`）：
  /// 以**首个出现的**分隔符为准切分；无顶层组合符返回 null。
  /// `%%` 用于多列表拉链（round-robin）合并。
  static (String, List<String>)? splitCombine(String rule) {
    final op = _firstTopLevelOp(rule, const ['&&', '%%']);
    if (op == null) return null;
    final parts = _splitTopLevel(rule, op)
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    return (op, parts);
  }

  static String? _firstTopLevelOp(String s, List<String> ops) {
    var depth = 0;
    var quote = '';
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote.isNotEmpty) {
        if (c == quote && (i == 0 || s[i - 1] != r'\')) quote = '';
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        continue;
      }
      if (c == '[' || c == '(' || c == '{') {
        depth++;
        continue;
      }
      if (c == ']' || c == ')' || c == '}') {
        if (depth > 0) depth--;
        continue;
      }
      if (depth != 0) continue;
      for (final op in ops) {
        if (s.startsWith(op, i)) return op;
      }
    }
    return null;
  }

  /// 顶层按定长分隔符切分（忽略括号与引号内部）。
  static List<String> _splitTopLevel(String s, String sep) {
    final out = <String>[];
    final buf = StringBuffer();
    var depth = 0;
    var quote = '';
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (quote.isNotEmpty) {
        buf.write(c);
        if (c == quote && (i == 0 || s[i - 1] != r'\')) quote = '';
        continue;
      }
      if (c == '"' || c == "'") {
        quote = c;
        buf.write(c);
        continue;
      }
      if (c == '[' || c == '(' || c == '{') depth++;
      if (c == ']' || c == ')' || c == '}') {
        if (depth > 0) depth--;
      }
      if (depth == 0 && c == sep[0] && s.startsWith(sep, i)) {
        out.add(buf.toString());
        buf.clear();
        i += sep.length - 1;
        continue;
      }
      buf.write(c);
    }
    out.add(buf.toString());
    return out;
  }

  /// legado `AppPattern.JS_PATTERN`：`<js>…</js>` 或 `@js:…`（大小写不敏感）。
  /// `@js:` 贪婪吞掉其后全部内容（legado 同语义，仅第一个 `@js:` 生效）。
  static final RegExp _jsPattern = RegExp(
    r'<js>([\w\W]*?)</js>|@js:([\w\W]*)',
    caseSensitive: false,
  );

  /// 是否包含 JS 段。
  static bool hasJs(String rule) => _jsPattern.hasMatch(rule);

  /// 按 `JS_PATTERN` 切分规则串为顺序片段（剔除空白文本段）。
  ///
  /// 例：`class.x@js:code` → [text("class.x"), js("code")]
  ///     `<js>a</js>https://x` → [js("a"), text("https://x")]
  static List<JsSegment> splitJs(String rule) {
    final segs = <JsSegment>[];
    var start = 0;
    for (final m in _jsPattern.allMatches(rule)) {
      if (m.start > start) {
        segs.add(JsSegment.text(rule.substring(start, m.start)));
      }
      segs.add(JsSegment.js(m.group(1) ?? m.group(2) ?? ''));
      start = m.end;
    }
    if (start < rule.length) {
      segs.add(JsSegment.text(rule.substring(start)));
    }
    if (segs.isEmpty) segs.add(JsSegment.text(rule));
    return segs.where((s) => s.isJs || s.text.trim().isNotEmpty).toList();
  }

  /// 拆出 `##` 替换链。
  ///
  /// `a##p1##r1##p2##r2` → base=`a`, chains=[(p1,r1),(p2,r2)]
  /// 末尾落单的一段视为“删除该匹配”（replacement 为空串）。
  ///
  /// 解析结果按规则串缓存（同一规则逐条目重复拆解；上限 512，超过整体清空，
  /// 模板渲染出的高基数串最坏只造成缓存抖动，不影响语义）。
  static final Map<String, RuleParts> _partsCache = {};
  static RuleParts splitReplaces(String rule) {
    if (!rule.contains('##')) {
      return RuleParts(rule.trim(), const []);
    }
    if (_partsCache.length > 512) _partsCache.clear();
    return _partsCache.putIfAbsent(rule, () => _splitReplacesUncached(rule));
  }

  static RuleParts _splitReplacesUncached(String rule) {
    final parts = rule.split('##');
    final base = parts.first.trim();
    // 四段链标记：`base##p##r###` 尾段仅剩 `#`／空 → 末链 replaceFirst
    // （legado `split("##").size > 3`）。尾段本身是标记、不参与配对游走。
    final flagged =
        parts.length >= 4 && parts.last.replaceAll('#', '').trim().isEmpty;
    final walk = flagged ? parts.sublist(0, parts.length - 1) : parts;
    final chains = <ReplaceChain>[];
    for (var i = 1; i < walk.length; i += 2) {
      final pattern = walk[i];
      final replacement = (i + 1 < walk.length) ? walk[i + 1] : '';
      if (pattern.isEmpty) continue;
      chains.add(ReplaceChain(pattern, replacement));
    }
    if (flagged && chains.isNotEmpty) {
      final last = chains.removeLast();
      chains.add(
          ReplaceChain(last.pattern, last.replacement, replaceFirst: true));
    }
    return RuleParts(base, chains);
  }

  /// 解析模式前缀，返回（模式, 剩余规则）。无前缀时模式为 [RuleMode.auto]。
  ///
  /// `@@` 前缀（legado 转义写法）→ 剥离后按默认模式处理。
  /// 前缀**大小写不敏感**（上游 `AnalyzeRule.kt:665-683` 用 `ignoreCase = true`，
  /// `@Json:` / `@XPath:` 同样成立）。
  static (RuleMode, String) parsePrefix(String rule) {
    var r = rule.trim();
    if (r.startsWith('@@')) {
      r = r.substring(2).trim();
    }
    if (r.startsWith('@')) {
      final low = r.toLowerCase();
      for (final (prefix, mode) in _prefixTable) {
        if (low.startsWith(prefix)) {
          return (mode, r.substring(prefix.length).trim());
        }
      }
    }
    return (RuleMode.auto, r);
  }

  /// 规则前缀表（小写形式，按上表顺序匹配）。
  static const List<(String, RuleMode)> _prefixTable = [
    (jsonPrefix, RuleMode.json),
    (xpathPrefix, RuleMode.xpath),
    (cssPrefix, RuleMode.css),
    (regexPrefix, RuleMode.regex),
  ];

  /// 规范空白：折叠连续空白为单个空格并去首尾（用于把 HTML 文本变干净）。
  ///
  /// 每个文本节点都会走这里，正则必须预编译（原来每次调用都 new RegExp）。
  static final RegExp _wsRe = RegExp(r'[\s\u00A0]+');
  static String collapseSpaces(String s) =>
      s.replaceAll(_wsRe, ' ').trim();

  /// 正则缓存（含编译失败的 null 记忆，避免同一坏规则反复抛异常）。
  ///
  /// `##` 替换链占单条规则耗时的大头（实测 ~50%），全部来自这里逐次重编译。
  /// 上限 512：书源数量有限，超过即整体清空（最坏情况退回原行为）。
  static final Map<String, RegExp?> _regexCache = {};
  static RegExp? _cachedRegex(String pattern) {
    if (_regexCache.length > 512) _regexCache.clear();
    return _regexCache.putIfAbsent(pattern, () {
      try {
        return RegExp(pattern);
      } catch (_) {
        return null;
      }
    });
  }

  /// 应用替换链（容错：非法正则跳过该链）。
  ///
  /// 替换串支持 `$1`..`$9` 与 `$&` 引用捕获组（手动展开，跨版本一致）。
  /// `##@base64##` 特殊链：把当前字符串按 Base64 解码（失败则保持原样）。
  static String applyReplaces(String input, List<ReplaceChain> chains) {
    var out = input;
    for (final chain in chains) {
      if (chain.pattern == _base64Chain) {
        out = tryBase64Decode(out) ?? out;
        continue;
      }
      final re = _cachedRegex(chain.pattern);
      if (re == null) continue; // 非法正则：跳过，不影响其它链
      if (chain.replaceFirst) {
        // 四段链：只取第一个匹配段并展开替换；无匹配 → 空串（legado replaceFirst）
        final m = re.firstMatch(out);
        out = (m == null) ? '' : _expandReplacement(chain.replacement, m);
        continue;
      }
      out = out.replaceAllMapped(
          re, (m) => _expandReplacement(chain.replacement, m));
    }
    return out;
  }

  static final RegExp _refPattern = RegExp(r'\$(\d|&)');

  /// 展开替换串中的 `$1`..`$9` 与 `$&`（手动展开，跨版本一致）。
  static String _expandReplacement(String replacement, Match m) {
    if (!replacement.contains(r'$')) return replacement;
    return replacement.replaceAllMapped(_refPattern, (r) {
      final k = r.group(1)!;
      if (k == '&') return m.group(0) ?? '';
      final idx = int.parse(k);
      return m.group(idx) ?? '';
    });
  }

  static const String _base64Chain = '@base64';

  /// 书源 header 字段宽松解析（对照 legado 的 Gson 宽松模式）：
  /// 1) 严格 JSON；2) 单引号 JSON（Python 风格字典，真实源大量使用）；
  /// 3) 每行 `Key: Value` 纯文本。解析不出时返回空表。
  static Map<String, String> parseHeaderJson(String raw) {
    final t = raw.trim();
    if (t.isEmpty) return {};
    final direct = _mapFromJson(t);
    if (direct != null) return direct;
    final loose = _mapFromJson(_squoteToDquote(t));
    if (loose != null) return loose;
    final out = <String, String>{};
    for (final line in t.split(RegExp(r'[\r\n;]+'))) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      var k = line.substring(0, i).trim();
      var v = line.substring(i + 1).trim();
      k = _unquote(k);
      v = _unquote(v);
      if (k.isNotEmpty && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  static Map<String, String>? _mapFromJson(String s) {
    try {
      final d = jsonDecode(s);
      if (d is Map) {
        return {for (final e in d.entries) e.key.toString(): e.value.toString()};
      }
    } catch (_) {}
    return null;
  }

  static String _unquote(String s) {
    if (s.length >= 2 &&
        (s.startsWith('"') || s.startsWith("'")) &&
        s.endsWith(s[0])) {
      return s.substring(1, s.length - 1);
    }
    return s;
  }

  /// 把单引号包裹的 JSON 片段转成双引号（Gson 宽松解析的等价近似）。
  static String _squoteToDquote(String s) {
    final out = StringBuffer();
    var inD = false;
    var inS = false;
    var esc = false;
    for (var i = 0; i < s.length; i++) {
      final c = s[i];
      if (esc) {
        out.write(c);
        esc = false;
        continue;
      }
      if (c == r'\') {
        out.write(c);
        esc = true;
        continue;
      }
      if (inD) {
        if (c == '"') inD = false;
        out.write(c);
        continue;
      }
      if (inS) {
        if (c == "'") {
          inS = false;
          out.write('"');
        } else {
          out.write(c == '"' ? r'\"' : c);
        }
        continue;
      }
      if (c == '"') {
        inD = true;
        out.write(c);
        continue;
      }
      if (c == "'") {
        inS = true;
        out.write('"');
        continue;
      }
      out.write(c);
    }
    return out.toString();
  }

  /// 尽力 Base64 解码（URL-safe 变体与缺失 padding 均容错）。
  static String? tryBase64Decode(String s) {
    final t = s.trim();
    if (t.isEmpty) return null;
    try {
      var b = t.replaceAll('-', '+').replaceAll('_', '/');
      final pad = b.length % 4;
      if (pad != 0) b = b.padRight(b.length + (4 - pad), '=');
      return utf8.decode(base64.decode(b), allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 清理书源主地址：部分源的 `bookSourceUrl` 带 `##分组` / `#备注` 尾缀
  /// （如 `https://www.qidian.com##分类`），直接参与相对地址解析会破坏基准地址。
  static String cleanBaseUrl(String base) {
    var b = base.trim();
    if (b.isEmpty) return b;
    final h = b.indexOf('#');
    if (h >= 0) {
      final head = b.substring(0, h).trim();
      if (head.isNotEmpty) b = head;
    }
    return b;
  }

  /// 剥离尾随 `@js:…` 脚本段（无 JS 引擎：保留脚本前的中间结果做尽力降级）。
  ///
  /// 整条规则就是 `@js:` 脚本（位置 0）时不剥离，交由上层按「不支持」显式处理。
  static String stripTrailingJs(String rule) {
    final i = rule.toLowerCase().lastIndexOf('@js:');
    if (i <= 0) return rule;
    return rule.substring(0, i);
  }
}
