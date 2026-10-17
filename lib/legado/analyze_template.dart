// `{{...}}` / `{$...}` 模板求值（URL 与规则字段共用）。
//
// 覆盖 Legado 书源最常用的表达式子集（无 JS 引擎环境下的实用降级；对照其公开行为）：
//   {{key}} / {{page}} / {{自定义变量}}         变量取值（含 URL 别名 searchKey/keyword）
//   {{$.a.b}} / {{$..a}} / {{$.a[1:]}}          JSONPath（可带 `##` 替换链）
//   {{book.name}} / {{source.bookSourceUrl}}    上下文变量（book 由调用方注入）
//   {{(page-1)*10}} / {{page-1}}                算术
//   {{encodeURIComponent(key)}} / {{decodeURIComponent(x)}}  编码
//   {{'a'+key+'\n'}}                            字符串拼接 / 字面量（含 \n \t \uXXXX）
//   {{Date.now()}} / {{Math.round(new Date()/1000)}}         数字函数
//   {{java.getString('$.x')}}                    JSONPath 取值模拟（阅读源最常见写法）
//   {{@@规则}}                                   引用另一条规则的结果（由回调执行）
//   其余（java.* / cookie.* / 语句式 JS）→ 空串（无脚本执行能力，显式降级）
import 'analyze_json.dart';
import 'rule_analyzer.dart';

/// `{{@@规则}}` 的求值回调：规则按其所在文档/上下文求值。
typedef TemplateRuleEval = String? Function(String rule, Object? ctx);

class TemplateEngine {
  TemplateEngine({
    Map<String, dynamic>? vars,
    Map<String, String>? store,
    this.baseUrl = '',
    this.jsonRoot,
    TemplateRuleEval? evalRule,
    this.jsEval,
    String Function(String)? encoder,
  })  : vars = vars ?? const {},
        store = store ?? const {},
        _evalRule = evalRule,
        _encoder = encoder;

  /// 调用方注入的变量（key / page / book 等）。
  final Map<String, dynamic> vars;

  /// `@put:` 写入的变量（扁平字符串存储）。
  final Map<String, String> store;

  final String baseUrl;

  /// 文档级 JSON（规则模式下作为 `$` 根的回退）。
  final dynamic jsonRoot;

  final TemplateRuleEval? _evalRule;

  /// P0：JS 兜底求值挂钩（子集无法求值时走真实 JS；null = 引擎不可用）。
  /// `ctx` 为链上当前结果（legado：`evalJS(expr, result)`，即 JS 里的 `result`）。
  /// 返回 null 表示脚本报错（模板降级为空串）。
  final String? Function(String expr, Object? ctx)? jsEval;

  final String Function(String)? _encoder;

  static final RegExp _braces = RegExp(r'\{\{([\s\S]*?)\}\}');
  static final RegExp _singleBrace = RegExp(r'\{(\$[^{}]{1,200})\}');

  /// 渲染全部模板。返回空串表示“表达式无法求值”（与 Legado 的 JS 报错降级一致）。
  String render(String input, {bool encodeValues = false, Object? ctx}) {
    if (!input.contains('{')) return input;
    if (!input.contains('{{') && !input.contains(r'{$')) return input;
    var out = input;
    if (out.contains('{{')) {
      out = out.replaceAllMapped(_braces, (m) => _sub(m.group(1)!, encodeValues, ctx));
    }
    if (out.contains(r'{$')) {
      out = out.replaceAllMapped(
          _singleBrace, (m) => _sub(m.group(1)!, encodeValues, ctx));
    }
    return out;
  }

  String _sub(String expr, bool encodeValues, Object? ctx) {
    final v = eval(expr, ctx);
    if (v == null || v.$1.isEmpty) return '';
    if (encodeValues && v.$2) {
      final enc = _encoder;
      return enc == null ? Uri.encodeComponent(v.$1) : enc(v.$1);
    }
    return v.$1;
  }

  /// 求值单个表达式（`{{ }}` 之间的原文）。返回（字符串值, 是否需要 URL 编码）。
  (String, bool)? eval(String rawExpr, Object? ctx) {
    var expr = rawExpr.trim();
    if (expr.isEmpty) return null;
    List<ReplaceChain> chains = const [];
    if (expr.contains('##')) {
      final parts = RuleAnalyzer.splitReplaces(expr);
      expr = parts.base;
      chains = parts.chains;
    }
    if (expr.isEmpty) return null;
    String? s;
    var enc = true;
    var ruleLike = false;
    if (expr.startsWith('@@')) {
      s = _evalRule?.call(expr.substring(2).trim(), ctx);
      enc = false;
      ruleLike = true;
    } else if (expr.startsWith('@') || expr.startsWith('//')) {
      // legado isRule()：`@xxx` / `//` 开头按规则求值（如 {{@css:.title}}、{{//div}}）
      s = _evalRule?.call(expr, ctx);
      enc = false;
      ruleLike = true;
    } else {
      final r = _ExprParser(expr, this, ctx).parse();
      if (r != null) {
        s = _stringify(r.$1);
        enc = r.$2;
      } else if (expr.startsWith(r'$')) {
        // legado isRule()：`$.` / `$[` 按 JSONPath 规则求值（不落到 JS，避免 $ is not defined）
        s = jsonPathLookup(expr, ctx);
        enc = true;
        ruleLike = true;
      }
      if (s == null && !ruleLike) {
        // P0：子集无法求值 → 真实 JS 兜底（legado：{{}} 内容按 JS 求值）。
        // JS 结果原样保留（需要编码时源里显式调 java.encodeURI 等）。
        final js = jsEval?.call(expr, ctx);
        if (js != null && js.isNotEmpty) {
          s = js;
          enc = false;
        }
      }
    }
    if (s == null) return null;
    if (chains.isNotEmpty) s = RuleAnalyzer.applyReplaces(s, chains);
    return (s, enc);
  }

  /// JSONPath 取值（ctx 为 Map/List 优先，否则文档级 JSON）。
  String? jsonPathLookup(String path, Object? ctx) {
    final root = (ctx is Map || ctx is List)
        ? ctx
        : ((jsonRoot is Map || jsonRoot is List) ? jsonRoot : null);
    if (root == null) return null;
    for (final v in jsonSelect(root, path)) {
      final s = jsonValueToString(v);
      if (s != null && s.isNotEmpty) return s;
    }
    return null;
  }

  /// 变量查找：@put 存储 → 注入变量 → 别名（key/page/source.*）。
  dynamic lookup(String name) {
    if (store.containsKey(name)) return store[name];
    if (vars.containsKey(name)) return vars[name];
    final segs = name.split('.');
    if (segs.length > 1) {
      dynamic cur;
      var found = false;
      if (store.containsKey(segs.first)) {
        cur = store[segs.first];
        found = true;
      } else if (vars.containsKey(segs.first)) {
        cur = vars[segs.first];
        found = true;
      }
      if (found) {
        for (var i = 1; i < segs.length; i++) {
          if (cur is Map && cur.containsKey(segs[i])) {
            cur = cur[segs[i]];
          } else if (i == 1) {
            // 容忍标量：`@put:{book:id}` 存的是标量，`{{book.id}}` 直接取该值
            return cur;
          } else {
            return null;
          }
        }
        return cur;
      }
    }
    switch (name) {
      case 'key':
      case 'searchKey':
      case 'keyword':
        return vars['key'];
      case 'page':
        return vars['page'] ?? 1;
      case 'baseUrl':
      case 'source.bookSourceUrl':
        return baseUrl.isEmpty ? null : baseUrl;
    }
    return null;
  }

  static String? _stringify(dynamic v) {
    if (v == null) return null;
    if (v is String) return v;
    if (v is num) {
      if (v is int) return v.toString();
      if (v == v.roundToDouble()) return v.toInt().toString();
      return v.toString();
    }
    if (v is bool) return v ? 'true' : 'false';
    return jsonValueToString(v);
  }
}

// ---------------- 表达式求值（迷你 JS 子集） ----------------

class _Bad implements Exception {}

/// 解析结果失败时返回 null（模板降级为空串）。
class _ExprParser {
  _ExprParser(this.src, this.eng, this.ctx);

  final String src;
  final TemplateEngine eng;
  final Object? ctx;
  int pos = 0;

  (dynamic, bool)? parse() {
    try {
      _ws();
      if (pos >= src.length) return null;
      final v = _additive();
      _ws();
      if (pos < src.length) return null;
      return v;
    } on _Bad {
      return null;
    } catch (_) {
      return null;
    }
  }

  void _ws() {
    while (pos < src.length && (src[pos] == ' ' || src[pos] == '\t' || src[pos] == '\n' || src[pos] == '\r')) {
      pos++;
    }
  }

  bool _peek(String s) => src.startsWith(s, pos);

  (dynamic, bool) _additive() {
    var left = _multiplicative();
    while (true) {
      _ws();
      if (_peek('+')) {
        pos++;
        final right = _multiplicative();
        left = _plus(left, right);
      } else if (_peek('-')) {
        pos++;
        final right = _multiplicative();
        left = (_num(left.$1) - _num(right.$1), false);
      } else {
        return left;
      }
    }
  }

  (dynamic, bool) _plus((dynamic, bool) a, (dynamic, bool) b) {
    if (a.$1 is num && b.$1 is num) return (a.$1 + b.$1, false);
    final s = '${TemplateEngine._stringify(a.$1) ?? ''}${TemplateEngine._stringify(b.$1) ?? ''}';
    return (s, a.$2 || b.$2);
  }

  (dynamic, bool) _multiplicative() {
    var left = _unary();
    while (true) {
      _ws();
      if (_peek('*')) {
        pos++;
        final right = _unary();
        left = (_num(left.$1) * _num(right.$1), false);
      } else if (_peek('/')) {
        pos++;
        final right = _unary();
        left = (_num(left.$1) / _num(right.$1), false);
      } else if (_peek('%')) {
        pos++;
        final right = _unary();
        final a = _num(left.$1), b = _num(right.$1);
        left = (a % b, false);
      } else {
        return left;
      }
    }
  }

  (dynamic, bool) _unary() {
    _ws();
    if (_peek('-')) {
      pos++;
      final v = _unary();
      return (-_num(v.$1), false);
    }
    if (_peek('+')) {
      pos++;
      return _unary();
    }
    return _primary();
  }

  double _num(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) {
      final d = double.tryParse(v.trim());
      if (d != null) return d;
    }
    throw _Bad();
  }

  (dynamic, bool) _primary() {
    _ws();
    if (pos >= src.length) throw _Bad();
    final c = src[pos];
    // 括号
    if (c == '(') {
      pos++;
      final v = _additive();
      _ws();
      if (pos >= src.length || src[pos] != ')') throw _Bad();
      pos++;
      return v;
    }
    // 字符串字面量
    if (c == "'" || c == '"') return (_readString(), false);
    // new Date()
    if (src.startsWith('new', pos)) {
      final save = pos;
      pos += 3;
      _ws();
      if (!src.startsWith('Date', pos)) {
        pos = save;
      } else {
        pos += 4;
        _ws();
        if (!_peek('()')) throw _Bad();
        pos += 2;
        return (DateTime.now().millisecondsSinceEpoch, false);
      }
    }
    // 数字
    if (_isDigit(c)) return (_readNumber(), false);
    // JSONPath（$ 开头）
    if (c == r'$') {
      final path = _readJsonPath();
      final v = eng.jsonPathLookup(path, ctx);
      if (v == null) throw _Bad();
      return (v, true);
    }
    // 标识符 / 函数调用
    final name = _readIdent();
    if (name == null || name.isEmpty) throw _Bad();
    _ws();
    if (_peek('(')) {
      final args = _readArgs();
      return _call(name, args);
    }
    final v = eng.lookup(name);
    if (v == null) throw _Bad();
    return (v, true);
  }

  bool _isDigit(String c) => c.codeUnitAt(0) >= 0x30 && c.codeUnitAt(0) <= 0x39;

  dynamic _readNumber() {
    final start = pos;
    while (pos < src.length && (_isDigit(src[pos]) || src[pos] == '.')) {
      pos++;
    }
    final t = src.substring(start, pos);
    return int.tryParse(t) ?? double.parse(t);
  }

  String _readString() {
    final quote = src[pos];
    pos++;
    final buf = StringBuffer();
    while (pos < src.length) {
      final ch = src[pos++];
      if (ch == '\\' && pos < src.length) {
        final nx = src[pos++];
        switch (nx) {
          case 'n':
            buf.write('\n');
          case 't':
            buf.write('\t');
          case 'r':
            buf.write('\r');
          case 'u':
            if (pos + 4 <= src.length) {
              final hex = src.substring(pos, pos + 4);
              final code = int.tryParse(hex, radix: 16);
              if (code != null) {
                buf.writeCharCode(code);
                pos += 4;
                break;
              }
            }
            buf.write('\\u');
          default:
            buf.write(nx);
        }
      } else if (ch == quote) {
        return buf.toString();
      } else {
        buf.write(ch);
      }
    }
    throw _Bad();
  }

  String? _readIdent() {
    final start = pos;
    while (pos < src.length) {
      final ch = src[pos];
      final ok = RegExp(r'[\w$]').hasMatch(ch) || ch == '.';
      if (!ok) break;
      pos++;
    }
    if (pos == start) return null;
    var t = src.substring(start, pos);
    // 尾部点（如 `source.getKey().` 之类）回退
    while (t.endsWith('.')) {
      t = t.substring(0, t.length - 1);
      pos--;
    }
    return t;
  }

  /// `$` 开头的 JSONPath：读到任意深度结束（[] 内保护空格与操作符）。
  String _readJsonPath() {
    final start = pos;
    var depth = 0;
    var quote = '';
    while (pos < src.length) {
      final ch = src[pos];
      if (quote.isNotEmpty) {
        if (ch == quote && src[pos - 1] != '\\') quote = '';
        pos++;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        pos++;
        continue;
      }
      if (ch == '[') {
        depth++;
        pos++;
        continue;
      }
      if (ch == ']') {
        depth--;
        pos++;
        continue;
      }
      if (depth == 0) {
        if (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r') break;
        if ('+-*/%()&|'.contains(ch)) break;
      }
      pos++;
    }
    return src.substring(start, pos);
  }

  List<String> _readArgs() {
    // 消费 '(' 与匹配的 ')'
    if (!_peek('(')) throw _Bad();
    pos++;
    final args = <String>[];
    final buf = StringBuffer();
    var depth = 1;
    var quote = '';
    while (pos < src.length) {
      final ch = src[pos];
      if (quote.isNotEmpty) {
        buf.write(ch);
        if (ch == quote && src[pos - 1] != '\\') quote = '';
        pos++;
        continue;
      }
      if (ch == "'" || ch == '"') {
        quote = ch;
        buf.write(ch);
        pos++;
        continue;
      }
      if (ch == '(') depth++;
      if (ch == ')') {
        depth--;
        if (depth == 0) {
          pos++;
          final t = buf.toString().trim();
          if (t.isNotEmpty) args.add(t);
          return args;
        }
      }
      if (ch == ',' && depth == 1) {
        args.add(buf.toString().trim());
        buf.clear();
        pos++;
        continue;
      }
      buf.write(ch);
      pos++;
    }
    throw _Bad();
  }

  (dynamic, bool) _call(String name, List<String> args) {
    dynamic arg(int i) {
      if (i >= args.length) throw _Bad();
      final r = _ExprParser(args[i], eng, ctx).parse();
      if (r == null) throw _Bad();
      return r.$1;
    }

    switch (name) {
      case 'encodeURIComponent':
        return (Uri.encodeComponent(TemplateEngine._stringify(arg(0)) ?? ''), false);
      case 'encodeURI':
      case 'encodeUrl':
        return (Uri.encodeFull(TemplateEngine._stringify(arg(0)) ?? ''), false);
      case 'decodeURIComponent':
      case 'decodeURI':
        try {
          return (Uri.decodeComponent(TemplateEngine._stringify(arg(0)) ?? ''), false);
        } catch (_) {
          return (TemplateEngine._stringify(arg(0)) ?? '', false);
        }
      case 'Math.round':
        return (_num(arg(0)).round(), false);
      case 'Math.floor':
        return (_num(arg(0)).floor(), false);
      case 'Math.ceil':
        return (_num(arg(0)).ceil(), false);
      case 'Math.abs':
        return (_num(arg(0)).abs(), false);
      case 'Date.now':
        return (DateTime.now().millisecondsSinceEpoch, false);
      case 'String':
        return (TemplateEngine._stringify(arg(0)) ?? '', false);
      case 'Number':
        return (_num(arg(0)), false);
      case 'parseInt':
        final s = TemplateEngine._stringify(arg(0)) ?? '';
        return (int.tryParse(RegExp(r'-?\d+').firstMatch(s)?.group(0) ?? '') ?? 0, false);
      case 'parseFloat':
        final s = TemplateEngine._stringify(arg(0)) ?? '';
        return (double.tryParse(RegExp(r'-?\d+(?:\.\d+)?').firstMatch(s)?.group(0) ?? '') ?? 0, false);
      case 'source.getKey':
      case 'source.bookSourceUrl':
        return (eng.baseUrl, true);
      case 'java.getString':
        // Legado 里最常见的 JSON 取值写法：`java.getString('$.path')`。
        // 无 JS 引擎下按 JSONPath 语义模拟（值原样返回，不做 URL 编码）。
        final path = TemplateEngine._stringify(arg(0)) ?? '';
        if (!path.startsWith(r'$')) throw _Bad();
        return (eng.jsonPathLookup(path, ctx) ?? '', false);
    }
    // java.* / cookie.* / 其它脚本函数：无法执行 → 整体降级
    throw _Bad();
  }
}
