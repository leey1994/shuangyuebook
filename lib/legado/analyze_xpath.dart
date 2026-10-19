// XPath 分析器（纯 Dart 迷你实现，覆盖书源规则常用子集）。
//
// 支持：
//   /a/b/c                  子节点路径（绝对 / 相对）
//   //a//b                  后代查找（任意深度）
//   *                       任意元素
//   [@attr] [@attr='v'] [@attr="v"]   属性断言
//   [N] [last()]            位置筛选（1 起，作用于同父分组；数字优先于标签名）
//   [text()='v']            文本等值断言（trim 比较）
//   [contains(text(),'v')] [contains(@attr,'v')]   子串断言
//   [tag]                   子元素存在断言（如 `//li[span]/a`）
//   @attr                   取属性（最终步）
//   text()                  取文本（最终步）
//
// 解析失败 / 文档不是合法 XML → 返回空结果（不抛异常）。
// 注：真实网页 HTML 常不合法（未闭合标签），上层会在解析失败时降级处理。
import 'package:xml/xml.dart';

/// XPath 求值结果：元素列表或字符串列表。
class XPathResult {
  const XPathResult.elements(this.elements) : strings = const [];
  const XPathResult.strings(this.strings) : elements = const [];

  final List<XmlElement> elements;
  final List<String> strings;

  bool get isEmpty => elements.isEmpty && strings.isEmpty;
}

// ---------- 表达式解析 ----------

class _Step {
  _Step({
    required this.descendant,
    required this.name,
    required this.isAttr,
    required this.isText,
  });

  final bool descendant; // `//` 轴；false = 子节点轴
  final String name; // 元素名、'*' 或属性名
  final bool isAttr;
  final bool isText;
  final preds = <_Pred>[];
}

class _Pred {
  String? attr;
  String? value;
  int? index;
  bool isLast = false;
  String? textEq; // [text()='值']
  String? textContains; // [contains(text(),'值')]
  String? attrContainsName; // [contains(@attr,'值')]
  String? attrContainsVal;
  String? childExists; // [tag]：存在该子元素
  // 复合谓词：[A and B] / [A or B] / [not(...)]
  final ands = <_Pred>[];
  final ors = <_Pred>[];
  bool isNot = false;
  _Pred? notInner;
  // [starts-with(@attr,'值')]
  String? startsWithAttr;
  String? startsWithVal;
}

List<_Step>? _parseSteps(String expr) {
  var s = expr.trim();
  if (s.isEmpty) return null;
  // string(路径) / normalize-space(路径)：取路径首元素文本（书源常用取文本变体）
  final fnWrap = RegExp(
    r'^(?:string|normalize-space)\s*\(\s*(.+?)\s*\)$',
    dotAll: true,
  ).firstMatch(s);
  if (fnWrap != null) {
    final inner = _parseSteps(fnWrap.group(1)!);
    if (inner == null) return null;
    final wrapped = _Step(
      descendant: false,
      name: '#string',
      isAttr: false,
      isText: false,
    );
    return [...inner, wrapped];
  }
  // 前导相对轴：`.`=当前元素、`..`=父元素、`.//`=当前元素后代
  var firstDescendant = false;
  final prefix = <_Step>[];
  _Step axis(String name) => _Step(
        descendant: false,
        name: name,
        isAttr: false,
        isText: false,
      );
  while (s.isNotEmpty) {
    if (s.startsWith('.//')) {
      // 剥掉 `.//`：#self 锚定到 ctx，首个真实步按后代轴处理
      prefix.add(axis('#self'));
      s = s.substring(3);
      firstDescendant = true;
      break;
    } else if (s == '.') {
      prefix.add(axis('#self'));
      s = '';
    } else if (s.startsWith('./')) {
      prefix.add(axis('#self'));
      s = s.substring(2);
    } else if (s == '..') {
      prefix.add(axis('#parent'));
      s = '';
    } else if (s.startsWith('../')) {
      prefix.add(axis('#parent'));
      s = s.substring(3);
    } else {
      break;
    }
  }
  final steps = <_Step>[...prefix];
  var i = 0;
  var pendingDescendant = false;
  var sawSlash = false;
  while (i < s.length) {
    final c = s[i];
    if (c == '/') {
      sawSlash = true;
      if (i + 1 < s.length && s[i + 1] == '/') {
        pendingDescendant = true;
        i += 2;
      } else {
        pendingDescendant = false;
        i++;
      }
      continue;
    }
    // 读一个 step，直到下一个 '/'（不含谓词中的 '/' —— 谓词里通常没有斜杠）
    var j = i;
    var bracket = 0;
    while (j < s.length) {
      final cj = s[j];
      if (cj == '[') bracket++;
      if (cj == ']') bracket--;
      if (cj == '/' && bracket == 0) break;
      j++;
    }
    final raw = s.substring(i, j).trim();
    if (raw.isEmpty) return null;
    final step = _parseStep(
      raw,
      pendingDescendant || firstDescendant,
    );
    if (step == null) return null;
    steps.add(step);
    i = j;
    pendingDescendant = false;
    firstDescendant = false;
  }
  return steps;
}

_Step? _parseStep(String raw, bool descendant) {
  // 分离谓词
  final preds = <_Pred>[];
  var name = raw;
  final firstBracket = raw.indexOf('[');
  if (firstBracket >= 0) {
    name = raw.substring(0, firstBracket);
    var i = firstBracket;
    while (i < raw.length) {
      if (raw[i] != '[') return null;
      final close = raw.indexOf(']', i);
      if (close < 0) return null;
      final inner = raw.substring(i + 1, close).trim();
      final pred = _parsePred(inner);
      if (pred == null) return null; // 复合谓词不支持 → 整条规则失败
      preds.add(pred);
      i = close + 1;
    }
  }
  name = name.trim();
  if (name.isEmpty) return null;
  _Step step;
  if (name.startsWith('@')) {
    step = _Step(
      descendant: descendant,
      name: name.substring(1),
      isAttr: true,
      isText: false,
    );
  } else if (name == 'text()') {
    step = _Step(
      descendant: descendant,
      name: 'text()',
      isAttr: false,
      isText: true,
    );
  } else {
    step = _Step(
      descendant: descendant,
      name: name,
      isAttr: false,
      isText: false,
    );
  }
  step.preds.addAll(preds);
  return step;
}

_Pred? _parsePred(String inner) {
  final t = inner.trim();
  if (t.isEmpty) return _Pred();
  // 复合谓词：顶层 and / or 拆分（括号深度 0 处）
  final andParts = _splitTopBool(t, ' and ');
  if (andParts != null && andParts.length > 1) {
    final p = _Pred();
    for (final part in andParts) {
      final sub = _parsePred(part);
      if (sub == null) return null; // 任一半边不支持 → 整条失败（宁空勿错）
      p.ands.add(sub);
    }
    return p;
  }
  final orParts = _splitTopBool(t, ' or ');
  if (orParts != null && orParts.length > 1) {
    final p = _Pred();
    for (final part in orParts) {
      final sub = _parsePred(part);
      if (sub == null) return null;
      p.ors.add(sub);
    }
    return p;
  }
  // not(...)：取括号内递归
  final notM = RegExp(r'^not\s*\(([\w\W]*)\)$', dotAll: true).firstMatch(t);
  if (notM != null) {
    final sub = _parsePred(notM.group(1)!);
    if (sub == null) return null;
    final p = _Pred();
    p.isNot = true;
    p.notInner = sub;
    return p;
  }
  // starts-with(@attr,'值')
  final sw = RegExp(
    r'''^starts-with\(\s*@([\w:-]+)\s*,\s*(?:"([^"]*)"|'([^']*)')\s*\)$''',
  ).firstMatch(t);
  if (sw != null) {
    final p = _Pred();
    p.startsWithAttr = sw.group(1);
    p.startsWithVal = (sw.group(2) ?? sw.group(3) ?? '');
    return p;
  }
  final p = _parseSimplePred(t);
  if (p == null) return null; // 不支持的谓词：让整条规则失败（宁空勿错）
  return p;
}

/// 顶层布尔拆分：返回 null = 不含该操作符；含括号深度 0 的拆分点则返回各段。
List<String>? _splitTopBool(String s, String op) {
  if (!s.contains(op)) return null;
  var depth = 0;
  var inS = false;
  var inD = false;
  final parts = <String>[];
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    final c = s[i];
    if (!inS && !inD) {
      if (c == "'") inS = true;
      if (c == '"') inD = true;
      if (c == '(' || c == '[') depth++;
      if (c == ')' || c == ']') depth--;
      if (depth == 0 && s.startsWith(op, i)) {
        parts.add(buf.toString());
        buf.clear();
        i += op.length - 1;
        continue;
      }
    } else {
      if (inS && c == "'") inS = false;
      if (inD && c == '"') inD = false;
    }
    buf.write(c);
  }
  parts.add(buf.toString());
  return parts;
}

_Pred? _parseSimplePred(String inner) {
  final p = _Pred();
  if (inner.startsWith('@')) {
    final eq = inner.indexOf('=');
    if (eq < 0) {
      p.attr = inner.substring(1).trim();
      return p;
    }
    p.attr = inner.substring(1, eq).trim();
    var v = inner.substring(eq + 1).trim();
    if (v.length >= 2 &&
        ((v.startsWith("'") && v.endsWith("'")) ||
            (v.startsWith('"') && v.endsWith('"')))) {
      v = v.substring(1, v.length - 1);
    }
    p.value = v;
    return p;
  }
  // [text()='值'] / [text()="值"]
  final tEq = RegExp(r'''^text\(\)\s*=\s*"([^"]*)"$''').firstMatch(inner) ??
      RegExp(r"^text\(\)\s*=\s*'([^']*)'$").firstMatch(inner);
  if (tEq != null) {
    p.textEq = tEq.group(1)!.trim();
    return p;
  }
  // [contains(text(),'值')]
  final tCon = RegExp(
    r'''^contains\(\s*text\(\)\s*,\s*(?:"([^"]*)"|'([^']*)')\s*\)$''',
  ).firstMatch(inner);
  if (tCon != null) {
    p.textContains = (tCon.group(1) ?? tCon.group(2) ?? '').trim();
    return p;
  }
  // [contains(@attr,'值')]
  final aCon = RegExp(
    r'''^contains\(\s*@([\w:-]+)\s*,\s*(?:"([^"]*)"|'([^']*)')\s*\)$''',
  ).firstMatch(inner);
  if (aCon != null) {
    p.attrContainsName = aCon.group(1);
    p.attrContainsVal = aCon.group(2) ?? aCon.group(3) ?? '';
    return p;
  }
  if (inner == 'last()') {
    p.isLast = true;
    return p;
  }
  final n = int.tryParse(inner);
  if (n != null) {
    p.index = n;
    return p;
  }
  // [tag]：存在该子元素（如 `//li[span]/a`；数字下标已先行处理）
  if (RegExp(r'^[\w:-]+$').hasMatch(inner)) {
    p.childExists = inner;
    return p;
  }
  return null; // 未知谓词：失败而不是“保留全部”
}

// ---------- 求值 ----------

/// 在 [context]（文档或元素）上执行 [expr]。
XPathResult evalXPath(XmlNode context, String expr) {
  final steps = _parseSteps(expr);
  if (steps == null || steps.isEmpty) return const XPathResult.elements([]);

  var current = <XmlElement>[];
  var i0 = 0;
  // 合成轴：`#self` / `#parent`（`.` / `..` 起始的相对路径）
  while (i0 < steps.length &&
      (steps[i0].name == '#self' || steps[i0].name == '#parent')) {
    final wantParent = steps[i0].name == '#parent';
    if (current.isEmpty) {
      final base = context is XmlElement
          ? context
          : (context is XmlDocument ? context.rootElement : null);
      if (base == null) return const XPathResult.elements([]);
      final el =
          wantParent ? base.parentElement : base;
      if (el == null) return const XPathResult.elements([]);
      current = [el];
    } else {
      final next = <XmlElement>[];
      for (final el in current) {
        final e = wantParent ? el.parentElement : el;
        if (e != null) next.add(e);
      }
      current = next;
    }
    i0++;
  }

  final rest = steps.sublist(i0);
  if (rest.isEmpty) return XPathResult.elements(current);
  final first = rest.first;
  final trimmed = expr.trimLeft();
  final isAbsolute = trimmed.startsWith('/') && !trimmed.startsWith('//');
  var startK = 0;
  if (current.isEmpty) {
    startK = 1;
    if (isAbsolute || trimmed.startsWith('//')) {
      final rootEl = context is XmlDocument
          ? context.rootElement
          : (context is XmlElement ? context : context.firstElementChild);
      if (rootEl == null) return const XPathResult.elements([]);
      // `//` = descendant-or-self（jsoupXpath 相对语义：元素 ctx 含自身；
      // `//@href` 属性首步必须取得到 ctx 自身的属性）。`/` = 从根元素起。
      final nodes = isAbsolute
          ? <XmlElement>[rootEl]
          : <XmlElement>[rootEl, ...rootEl.descendantElements];
      if (first.isAttr || first.isText) {
        return _terminal(nodes, first);
      }
      current = _matchOn(nodes, first, includeSelf: true);
    } else {
      // 相对路径：对上下文的所有后代做首步匹配（书源里最常见的是 .// 变体）
      final base = context is XmlElement ? context : context.firstElementChild;
      if (base == null) return const XPathResult.elements([]);
      if (first.isAttr || first.isText) {
        return _terminal([base], first);
      }
      final all = base.descendantElements.toList();
      current = _matchOn(all, first, includeSelf: false);
    }
  }

  for (var k = startK; k < rest.length; k++) {
    final step = rest[k];
    if (step.isAttr || step.isText) {
      return _terminal(current, step);
    }
    if (step.name == '#string') {
      // string(路径)：取路径首元素的整体文本
      final out = <String>[];
      for (final el in current) {
        final t = el.innerText.trim();
        if (t.isNotEmpty) out.add(t);
      }
      return XPathResult.strings(out);
    }
    final next = <XmlElement>[];
    for (final el in current) {
      if (step.descendant) {
        next.addAll(
          _matchOn(el.descendantElements.toList(), step, includeSelf: false),
        );
      } else {
        next.addAll(
          _matchOn(el.childElements.toList(), step, includeSelf: true),
        );
      }
    }
    current = next;
    if (current.isEmpty) break;
  }

  // 末步是普通元素步：若 expr 以 @/text() 结尾则已在上面返回
  if (rest.last.isAttr || rest.last.isText) {
    return _terminal(_resolveLastPreds(current, rest.last), rest.last);
  }
  return XPathResult.elements(current);
}

List<XmlElement> _resolveLastPreds(List<XmlElement> nodes, _Step step) =>
    _applyPreds(nodes, step);

List<XmlElement> _matchOn(
  List<XmlElement> candidates,
  _Step step, {
  required bool includeSelf,
}) {
  var matched = candidates.where((el) => _nameMatches(el, step.name)).toList();
  matched = _applyPreds(matched, step);
  return matched;
}

bool _nameMatches(XmlElement el, String name) {
  if (name == '*') return true;
  return el.name.local == name || el.name.toString() == name;
}

List<XmlElement> _applyPreds(List<XmlElement> nodes, _Step step) {
  var list = nodes;
  for (final p in step.preds) {
    list = _applyOnePred(list, p);
  }
  return list;
}

List<XmlElement> _applyOnePred(List<XmlElement> list, _Pred p) {
  // 复合：and = 逐半边过滤；or = 并集（保序去重）；not = 反选
  if (p.ands.isNotEmpty) {
    var list2 = list;
    for (final sub in p.ands) {
      list2 = _applyOnePred(list2, sub);
    }
    return list2;
  }
  if (p.ors.isNotEmpty) {
    final out = <XmlElement>[];
    for (final sub in p.ors) {
      for (final el in _applyOnePred(list, sub)) {
        if (!out.contains(el)) out.add(el);
      }
    }
    return out;
  }
  if (p.isNot && p.notInner != null) {
    final hit = _applyOnePred(list, p.notInner!).toSet();
    return list.where((el) => !hit.contains(el)).toList();
  }
  if (p.startsWithAttr != null) {
    return list
        .where((el) =>
            (el.getAttribute(p.startsWithAttr!) ?? '')
                .startsWith(p.startsWithVal!))
        .toList();
  }
  if (p.attr != null) {
    final attr = p.attr!;
    if (p.value == null) {
      return list.where((el) => el.getAttribute(attr) != null).toList();
    }
    return list
        .where((el) => (el.getAttribute(attr) ?? '') == p.value)
        .toList();
  }
  if (p.index != null) {
    // 位置：按父节点分组，第 N 个（1 起）
    return _pickByPosition(list, p.index! - 1, fromEnd: false);
  }
  if (p.isLast) {
    return _pickByPosition(list, 0, fromEnd: true);
  }
  if (p.textEq != null) {
    return list.where((el) => _nodeText(el) == p.textEq).toList();
  }
  if (p.textContains != null) {
    return list.where((el) => _nodeText(el).contains(p.textContains!)).toList();
  }
  if (p.attrContainsName != null) {
    return list
        .where(
          (el) => (el.getAttribute(p.attrContainsName!) ?? '')
              .contains(p.attrContainsVal!),
        )
        .toList();
  }
  if (p.childExists != null) {
    return list
        .where(
          (el) => el.childElements.any((c) => c.name.local == p.childExists),
        )
        .toList();
  }
  return list; // 空谓词（不应出现）
}

/// 元素文本（折叠空白；用于 text() 谓词比较）。
String _nodeText(XmlElement el) =>
    el.innerText.trim().replaceAll(RegExp(r'\s+'), ' ');

List<XmlElement> _pickByPosition(
  List<XmlElement> nodes,
  int idx, {
  required bool fromEnd,
}) {
  final grouped = <XmlNode?, List<XmlElement>>{};
  for (final el in nodes) {
    grouped.putIfAbsent(el.parent, () => []).add(el);
  }
  final out = <XmlElement>[];
  for (final group in grouped.values) {
    final i = fromEnd ? group.length - 1 : idx;
    if (i >= 0 && i < group.length) out.add(group[i]);
  }
  return out;
}

XPathResult _terminal(List<XmlElement> nodes, _Step step) {
  if (step.isAttr) {
    final out = <String>[];
    for (final el in nodes) {
      final v = el.getAttribute(step.name);
      if (v != null && v.trim().isNotEmpty) out.add(v.trim());
    }
    return XPathResult.strings(out);
  }
  // text()：取直接文本子节点；若没有直接文本，退化取整体文本
  final out = <String>[];
  for (final el in nodes) {
    final texts = el.children
        .whereType<XmlText>()
        .map((t) => t.value.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (texts.isEmpty) {
      final whole = el.innerText.trim();
      if (whole.isNotEmpty) out.add(whole);
    } else {
      out.addAll(texts);
    }
  }
  return XPathResult.strings(out);
}
