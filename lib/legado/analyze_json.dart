// JSONPath 分析器（Legado 书源使用的实用子集，独立实现）。
//
// 支持：
//   $.a.b            子字段
//   $['a']["b"]      带引号子字段
//   $.a[0] / [-1]    数组下标（负数从末尾）
//   $.a[*]           数组/对象通配
//   $..name          递归后代查找（深度优先）
//   $[0].name        顶层数组
//   $.a[?(@.x)]      过滤表达式（存在性 / == != > < >= <= / || && 组合）
//   $.a[1:3] / [1:] / [:3]   切片（0 起，含头不含尾，负值从末尾）
//   $.a[0,2]         多下标
//
// 解析失败时返回空列表（与“查无结果”同语义），不抛异常。

import 'dart:convert';

/// 解析路径为段列表（非法路径返回 null）。
List<_Seg>? _parseJsonPath(String path) {
  var p = path.trim();
  if (p.startsWith(r'$')) p = p.substring(1);
  final segs = <_Seg>[];
  var i = 0;
  while (i < p.length) {
    final c = p[i];
    if (c == '.') {
      if (i + 1 < p.length && p[i + 1] == '.') {
        // 递归后代：..name 或 ..*
        var j = i + 2;
        if (j >= p.length) return null;
        if (p[j] == '*') {
          segs.add(const _Seg(_SegKind.recursive, '*'));
          i = j + 1;
        } else if (p[j] == '[') {
          final close = _findBracket(p, j);
          if (close < 0) return null;
          final inner = p.substring(j + 1, close).trim();
          if (inner.startsWith('?')) {
            // `$..[?(...)]`：全后代扫描 + 过滤（宽松支持）
            final m = RegExp(r'^\?\s*\((.*)\)\s*$', dotAll: true)
                .firstMatch(inner);
            final filter = m == null ? null : _parseFilter(m.group(1)!);
            if (filter == null) return null;
            segs.add(const _Seg(_SegKind.recursive, '*'));
            segs.add(_Seg(_SegKind.filter, '', filter: filter));
            i = close + 1;
            continue;
          }
          final name = _unquote(inner);
          if (name == null) return null;
          segs.add(_Seg(_SegKind.recursive, name));
          i = close + 1;
        } else {
          final m = RegExp(r'^[A-Za-z_$][\w$\-]*').firstMatch(p.substring(j));
          if (m == null) return null;
          segs.add(_Seg(_SegKind.recursive, m.group(0)!));
          i = j + m.group(0)!.length;
        }
        continue;
      }
      // 普通子字段：.name 或 .*
      i++;
      if (i >= p.length) break;
      if (p[i] == '[') {
        // `$.[0]` / `$.[*]`：点后直接跟下标/通配（交给 bracket 分支）
        continue;
      }
      if (p[i] == '*') {
        segs.add(const _Seg(_SegKind.wildcard, '*'));
        i++;
      } else {
        final m = RegExp(r'^[A-Za-z_$][\w$\-]*').firstMatch(p.substring(i));
        if (m == null) return null;
        segs.add(_Seg(_SegKind.child, m.group(0)!));
        i += m.group(0)!.length;
      }
    } else if (c == '[') {
      final close = _findBracket(p, i);
      if (close < 0) return null;
      final inner = p.substring(i + 1, close).trim();
      final seg = _parseBracket(inner);
      if (seg == null) return null;
      segs.add(seg);
      i = close + 1;
    } else {
      // 隐式根字段（宽松写法：省略开头的 `$.`）
      final m = RegExp(r'^[A-Za-z_$][\w$\-]*').firstMatch(p.substring(i));
      if (m == null) return null;
      segs.add(_Seg(_SegKind.child, m.group(0)!));
      i += m.group(0)!.length;
    }
  }
  return segs;
}

/// 括号配对查找（过滤表达式内部可能含 `[` / 引号）。
int _findBracket(String s, int open) {
  var depth = 0;
  var quote = '';
  for (var i = open; i < s.length; i++) {
    final ch = s[i];
    if (quote.isNotEmpty) {
      if (ch == quote && s[i - 1] != r'\') quote = '';
      continue;
    }
    if (ch == "'" || ch == '"') {
      quote = ch;
      continue;
    }
    if (ch == '[') depth++;
    if (ch == ']') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

_Seg? _parseBracket(String inner) {
  if (inner == '*') return const _Seg(_SegKind.wildcard, '*');
  if (RegExp(r'^-?\d+$').hasMatch(inner)) {
    return _Seg(_SegKind.idx, inner);
  }
  if (inner.startsWith('?')) {
    final m = RegExp(r'^\?\s*\((.*)\)\s*$', dotAll: true).firstMatch(inner);
    if (m == null) return null;
    final filter = _parseFilter(m.group(1)!);
    if (filter == null) return null;
    return _Seg(_SegKind.filter, '', filter: filter);
  }
  if (RegExp(r'^-?\d*\s*:\s*-?\d*$').hasMatch(inner) &&
      RegExp(r'\d').hasMatch(inner)) {
    return _Seg(_SegKind.slice, inner);
  }
  if (RegExp(r'^-?\d+\s*(?:,\s*-?\d+)+$').hasMatch(inner)) {
    return _Seg(_SegKind.multi, inner);
  }
  final name = _unquote(inner);
  if (name == null) return null;
  return _Seg(_SegKind.child, name);
}

// ---------- 过滤表达式 ----------

class _Filter {
  const _Filter(this.ors);

  /// OR 组合（`||`）；每组内为 AND 组合（`&&`）。
  final List<List<_Cond>> ors;
}

class _Cond {
  const _Cond(this.path, this.op, this.value);

  final String path;
  final String? op;
  final dynamic value;
}

_Filter? _parseFilter(String content) {
  final orsText = _splitTop(content, '||');
  final ors = <List<_Cond>>[];
  for (final part in orsText) {
    final ands = <_Cond>[];
    for (final clause in _splitTop(part, '&&')) {
      final m = RegExp(
        r'^@\.?\s*([\w$.\[\]-]+)\s*(==|!=|>=|<=|>|<)?\s*(.*)$',
        dotAll: true,
      ).firstMatch(clause.trim());
      if (m == null) return null;
      final path = m.group(1)!.trim();
      final op = m.group(2);
      final rawVal = m.group(3)!.trim();
      ands.add(_Cond(path, op, rawVal.isEmpty ? null : _litValue(rawVal)));
    }
    if (ands.isNotEmpty) ors.add(ands);
  }
  return ors.isEmpty ? null : _Filter(ors);
}

List<String> _splitTop(String s, String sep) {
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
    if (ch == "'" || ch == '"') {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (ch == '(' || ch == '[') depth++;
    if (ch == ')' || ch == ']') depth--;
    if (depth == 0 && s.startsWith(sep, i)) {
      out.add(buf.toString());
      buf.clear();
      i += sep.length - 1;
      continue;
    }
    buf.write(ch);
  }
  out.add(buf.toString());
  return out;
}

dynamic _litValue(String raw) {
  final t = raw.trim();
  if (t.length >= 2 &&
      ((t.startsWith("'") && t.endsWith("'")) ||
          (t.startsWith('"') && t.endsWith('"')))) {
    return t.substring(1, t.length - 1);
  }
  if (t == 'true') return true;
  if (t == 'false') return false;
  if (t == 'null') return null;
  final n = num.tryParse(t);
  if (n != null) return n;
  return t;
}

bool _matchFilter(dynamic item, _Filter f) {
  for (final ands in f.ors) {
    var all = true;
    for (final c in ands) {
      if (!_matchCond(item, c)) {
        all = false;
        break;
      }
    }
    if (all) return true;
  }
  return false;
}

bool _matchCond(dynamic item, _Cond c) {
  dynamic cur = item;
  for (final seg in c.path.split('.')) {
    if (seg.isEmpty) continue;
    if (cur is Map && cur.containsKey(seg)) {
      cur = cur[seg];
    } else if (cur is List && int.tryParse(seg) != null) {
      final i = int.parse(seg);
      if (i < 0 || i >= cur.length) return false;
      cur = cur[i];
    } else {
      return false;
    }
  }
  if (c.op == null) return cur != null && cur != false;
  final v = cur;
  if (c.op == '==') return _filterEq(v, c.value);
  if (c.op == '!=') return !_filterEq(v, c.value);
  final a = _asNum(v);
  final b = _asNum(c.value);
  if (a == null || b == null) return false;
  switch (c.op) {
    case '>':
      return a > b;
    case '<':
      return a < b;
    case '>=':
      return a >= b;
    case '<=':
      return a <= b;
  }
  return false;
}

bool _filterEq(dynamic a, dynamic b) {
  if (a == null) return b == null;
  final na = _asNum(a), nb = _asNum(b);
  if (na != null && nb != null) return na == nb;
  if (a is bool || b is bool) return a.toString() == b.toString();
  return a.toString() == b.toString();
}

num? _asNum(dynamic v) {
  if (v is num) return v;
  if (v is String) return num.tryParse(v.trim());
  return null;
}

String? _unquote(String s) {
  if (s.length >= 2) {
    final a = s[0], b = s[s.length - 1];
    if ((a == "'" && b == "'") || (a == '"' && b == '"')) {
      return s.substring(1, s.length - 1);
    }
  }
  // 无引号：允许裸字段名（宽松兜底）
  if (RegExp(r'^[A-Za-z_$][\w$\-]*$').hasMatch(s)) return s;
  return null;
}

enum _SegKind { child, idx, wildcard, recursive, filter, slice, multi }

class _Seg {
  const _Seg(this.kind, this.name, {this.filter});

  final _SegKind kind;
  final String name;
  final _Filter? filter;
}

/// 在 JSON 数据上执行路径查询；返回命中的原始值列表。
List<dynamic> jsonSelect(dynamic root, String path) {
  final segs = _parseJsonPath(path);
  if (segs == null) return const [];
  var current = <dynamic>[root];
  for (final seg in segs) {
    final next = <dynamic>[];
    switch (seg.kind) {
      case _SegKind.child:
        for (final v in current) {
          if (v is Map && v.containsKey(seg.name)) next.add(v[seg.name]);
        }
      case _SegKind.idx:
        final idx = int.parse(seg.name);
        for (final v in current) {
          if (v is List) {
            final i = idx < 0 ? v.length + idx : idx;
            if (i >= 0 && i < v.length) next.add(v[i]);
          }
        }
      case _SegKind.wildcard:
        for (final v in current) {
          if (v is List) {
            next.addAll(v);
          } else if (v is Map) {
            next.addAll(v.values);
          }
        }
      case _SegKind.recursive:
        for (final v in current) {
          _collectRecursive(v, seg.name, next);
        }
      case _SegKind.filter:
        for (final v in current) {
          if (v is List) {
            for (final it in v) {
              if (_matchFilter(it, seg.filter!)) next.add(it);
            }
          } else if (v is Map) {
            for (final it in v.values) {
              if (_matchFilter(it, seg.filter!)) next.add(it);
            }
          }
        }
      case _SegKind.slice:
        final pair = seg.name.split(':');
        final fromRaw = pair[0].trim();
        final toRaw = pair.length > 1 ? pair[1].trim() : '';
        for (final v in current) {
          if (v is! List) continue;
          var from = fromRaw.isEmpty ? 0 : int.tryParse(fromRaw) ?? 0;
          var to = toRaw.isEmpty ? v.length : int.tryParse(toRaw) ?? v.length;
          if (from < 0) from += v.length;
          if (to < 0) to += v.length;
          from = from.clamp(0, v.length);
          to = to.clamp(0, v.length);
          if (from < to) next.addAll(v.sublist(from, to));
        }
      case _SegKind.multi:
        final idxs = seg.name
            .split(',')
            .map((e) => int.tryParse(e.trim()))
            .whereType<int>()
            .toList();
        for (final v in current) {
          if (v is! List) continue;
          for (final idx in idxs) {
            final i = idx < 0 ? v.length + idx : idx;
            if (i >= 0 && i < v.length) next.add(v[i]);
          }
        }
    }
    current = next;
    if (current.isEmpty) break;
  }
  return current;
}

void _collectRecursive(dynamic node, String name, List<dynamic> out) {
  if (node is Map) {
    for (final e in node.entries) {
      if (name == '*' || e.key == name) out.add(e.value);
      _collectRecursive(e.value, name, out);
    }
  } else if (node is List) {
    for (final v in node) {
      _collectRecursive(v, name, out);
    }
  }
}

/// 把查询结果转成字符串列表（对照书源规则的常见用法）：
/// - String → 原样（去首尾空白，空串丢弃）
/// - num / bool → toString
/// - Map / List → JSON 文本
/// - null → 丢弃
List<String> jsonSelectStrings(dynamic root, String path) {
  final out = <String>[];
  for (final v in jsonSelect(root, path)) {
    final s = jsonValueToString(v);
    if (s != null && s.isNotEmpty) out.add(s);
  }
  return out;
}

/// 单个值 → 字符串（null / 空串 → null）。
String? jsonValueToString(dynamic v) {
  if (v == null) return null;
  if (v is String) {
    final t = v.trim();
    return t.isEmpty ? null : t;
  }
  if (v is num || v is bool) return v.toString();
  // Map / List：编码为 JSON（书源里多见于 kind / 扩展字段）
  return jsonEncodeValue(v);
}

/// JSON 编码（用于 Map / List 结果）。
String jsonEncodeValue(dynamic v) => jsonEncode(v);
