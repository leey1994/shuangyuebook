// CSS 分析器：把 Legado 风格的 CSS 规则应用到 HTML 文档 / 元素上。
//
// 规则语法（对照 Legado 的公开行为，用 `@` 串联多个阶段）：
//   `class.book-list@tag.li`           在 .book-list 内选 li（返回元素）
//   `class.book-list@tag.li@tag.a@href` 逐级深入，最后取 href 属性
//   `id.content@text`                  取 #content 的文本
//   `class.novel.0@text`               取第 0 个匹配（支持 `.N` / `N` / 负索引）
//   `tbody tr!0`                       排除第 0 个（`!0:2:4` 多排除）
//   `tag.tr[1:20]` / `a[0,2]` / `li[3]`  切片 / 多下标 / 单下标
//   `li:lt(5)` `td:gt(2)` `a:eq(1)`     jsoup 风格位置伪类
//   `li:first-of-type` `p:nth-of-type(2)` / `li:has(a)`  类型位置与包含过滤
//   `[property~=category|status]`       jsoup 风格属性正则（含正则特征时）
//   `@css:` 前缀由上层引擎剥离
//
// 兼容旧写法：`tag.li` → `li`、`class.xx` → `.xx`、`id.xx` → `#xx`。
// 提取器关键字：text / textNodes / ownText / html / all；其余单词视为属性名。
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;

import 'rule_analyzer.dart';

/// 阶段类型。
enum CssStageType { selector, position, extractor, range }

/// 单个阶段。
class CssStage {
  const CssStage(this.type, this.value);

  final CssStageType type;
  final String value;
}

/// 尾部排除后缀：`!0` `!0:2:4` `!1,3` `!-1`（负索引从尾部数）。
final RegExp _excludeSuffix =
    RegExp(r'!\s*(-?\d+(?:\s*[:,\s]\s*-?\d+)*)$');

/// 尾部切片/下标后缀：`[1:20]` `[3:]` `[:5]` `[0,2]` `[3]`。
final RegExp _sliceSuffix =
    RegExp(r'\[(\s*-?\d*\s*:\s*-?\d*\s*|-?\d+\s*(?:,\s*-?\d+\s*)+|-?\d+)\]$');

/// 解析结果缓存（同一规则的阶段列表逐条目重复解析；上限 512，超过整体清空。
/// [elementsMode] 影响语义，作为缓存键的一部分）。
final Map<String, List<CssStage>> _cssStageCache = {};

/// 把规则拆分为阶段列表（`@` 分隔）。解析失败时返回空列表。
/// 解析 CSS 规则为阶段序列。
///
/// [elementsMode]：为 true 时（`getRawList`/`getElements` 路径，如 chapterList）
/// 末段的裸名字一律按**选择器**理解——`.listmain@dd@a`、`li!0:4@a` 这类
/// 「目录规则以裸标签结尾」的写法在书源里极常见；若按属性提取器处理会
/// 一直找名为 `a`/`p` 的属性 → 命中 0 → 目录为空。
List<CssStage> parseCssStages(String rule, {bool elementsMode = false}) {
  final key = elementsMode ? '1$rule' : '0$rule';
  if (_cssStageCache.length > 512) _cssStageCache.clear();
  return _cssStageCache.putIfAbsent(key, () => _parseCssStagesUncached(rule, elementsMode: elementsMode));
}

List<CssStage> _parseCssStagesUncached(String rule,
    {bool elementsMode = false}) {
  final parts = rule.split('@');
  final stages = <CssStage>[];
  for (var i = 0; i < parts.length; i++) {
    final raw = parts[i];
    var p = raw.trim();
    if (p.isEmpty) continue;
    // 先剥离尾部「排除 / 切片 / 下标」后缀（可叠加），阶段顺序与书写顺序一致。
    final suffixes = <String>[];
    while (p.isNotEmpty) {
      final excl = _excludeSuffix.firstMatch(p);
      if (excl != null && excl.start > 0) {
        suffixes.insert(0, '!${excl.group(1)}');
        p = p.substring(0, excl.start).trim();
        continue;
      }
      final slice = _sliceSuffix.firstMatch(p);
      if (slice != null && slice.start > 0) {
        suffixes.insert(0, slice.group(1)!);
        p = p.substring(0, slice.start).trim();
        continue;
      }
      break;
    }
    if (p.isNotEmpty) {
      final isFirst = stages.isEmpty;
      final isLast = i == parts.length - 1;
      if (_isIndex(p)) {
        stages.add(CssStage(CssStageType.position, _indexValue(p).toString()));
      } else if (_suffixIndex.hasMatch(p) &&
          !RegExp(r'^[A-Za-z_][\w:-]*$').hasMatch(p)) {
        // 形如 `class.item.0` / `.item.1` / `tr.-2` 的“选择器 + 索引”合并写法
        final m = _suffixIndex.firstMatch(p)!;
        stages.add(
          CssStage(CssStageType.selector, _normalizeSelector(m.group(1)!)),
        );
        stages.add(CssStage(CssStageType.position, m.group(2)!));
      } else if (_extractorKeywords.contains(p)) {
        stages.add(CssStage(CssStageType.extractor, p));
      } else if (isLast && !isFirst && !elementsMode && _attrNameRe.hasMatch(p)) {
        // 只有**末段**的纯名字才是属性提取（`a@href`）。
        // 中间段一律选择器：`.nodeContent@p@html` / `div@p@text` 里的裸标签名
        // `p`/`a`/`i` 长得像属性名，修前被当成“取 p 属性”→ 命中 0 → 正文变空。
        stages.add(CssStage(CssStageType.extractor, p));
      } else {
        // 首段也一律按选择器理解：`a@href` / `h3@text` 这类单段标签是阅读源
        // 最常见写法，不能因为长得像属性名就被当成属性提取（修前 `a@href`
        // 命中 0 → 整行静默丢弃）。
        stages.add(CssStage(CssStageType.selector, _normalizeSelector(p)));
      }
    }
    for (final s in suffixes) {
      stages.add(CssStage(CssStageType.range, s));
    }
  }
  return stages;
}

bool _isIndex(String p) =>
    RegExp(r'^-?\d+$').hasMatch(p) || RegExp(r'^\.-?\d+$').hasMatch(p);

final _suffixIndex = RegExp(r'^(.+)\.(-?\d+)$');

int _indexValue(String p) => int.parse(p.startsWith('.') ? p.substring(1) : p);

const _extractorKeywords = {'text', 'textNodes', 'ownText', 'html', 'all'};

/// 属性名形态：字母/下划线开头，允许数字、连字符、冒号（如 data-src、xlink:href）。
final _attrNameRe = RegExp(r'^[A-Za-z_][\w:-]*$');

String _normalizeSelector(String p) {
  // 复合段（空格分隔的多个选择器token）逐 token 归一化：
  // `id.mulu class.DivTd3` 修前只换首 token → `#mulu class.DivTd3`
  // 里残留的 `class.DivTd3` 不是合法 CSS → 整个选择器命中 0。
  final tokens = p.split(' ');
  if (tokens.length > 1) {
    return tokens.map(_normalizeSelector).join(' ');
  }
  // 开头 `-` 是导源工具留下的装饰噪声（`-.chapters p`、`-class.chapters`），
  // 不是合法 CSS → 命中 0；剥掉后按正常段归一化。
  if (p.length > 1 && p.startsWith('-')) {
    final rest = p.substring(1);
    if (rest.startsWith('.') ||
        rest.startsWith('#') ||
        rest.startsWith('class.') ||
        rest.startsWith('id.') ||
        rest.startsWith('tag.')) {
      return _normalizeSelector(rest);
    }
  }
  if (p.startsWith('tag.')) return p.substring(4);
  if (p.startsWith('class.')) return '.${p.substring(6)}';
  if (p.startsWith('id.')) return '#${p.substring(3)}';
  return p;
}

/// 解析 HTML 文本为文档对象（容错）。
dom.Document parseHtml(String html) => html_parser.parse(html);

/// 按顶层的兄弟组合子（`~` 后继兄弟 / `+` 紧邻兄弟）切段。
/// 括号、中括号与引号内的 `~`/`+` 不切（`[href~=x]`、`:contains(a+b)`）。
List<(String, String)>? _splitSiblingChain(String s) {
  final parts = <(String, String)>[];
  var depth = 0;
  String? quote;
  var start = 0;
  var comb = '';
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      continue;
    }
    if (ch == '(' || ch == '[') {
      depth++;
      continue;
    }
    if (ch == ')' || ch == ']') {
      if (depth > 0) depth--;
      continue;
    }
    if (depth == 0 && (ch == '~' || ch == '+')) {
      parts.add((s.substring(start, i).trim(), comb));
      comb = ch;
      start = i + 1;
    }
  }
  if (parts.isEmpty) return null;
  parts.add((s.substring(start).trim(), comb));
  return parts.isEmpty ? null : parts;
}

/// `A ~ B C`：A 的后继兄弟里挑出 B，再在 B 内取 C（jsoup 的 `~` 语义）。
///
/// package:html 不认 jsoup 的 `:contains`，两者同时出现时整条选择器会静默 0
/// 命中（抖音小说目录 `#list dt:contains(正文) ~ dd a` 就是这样丢的）。
List<dom.Element> _selectBySiblingChain(
  dom.Node context,
  List<(String, String)> parts,
) {
  var set = selectElements(context, parts.first.$1);
  for (var i = 1; i < parts.length; i++) {
    final comb = parts[i].$2;
    final seg = parts[i].$1;
    if (seg.isEmpty || set.isEmpty) return const [];
    final sp = _splitTopLevelSpaces(seg);
    final head = sp.first;
    final rest = sp.length > 1 ? sp.sublist(1).join(' ') : '';
    final matched = selectElements(context, head).toSet();
    final picked = <dom.Element>[];
    for (final e in set) {
      if (comb == '+') {
        final n = e.nextElementSibling;
        if (n != null && matched.contains(n)) picked.add(n);
      } else {
        var n = e.nextElementSibling;
        while (n != null) {
          if (matched.contains(n)) picked.add(n);
          n = n.nextElementSibling;
        }
      }
    }
    if (rest.isEmpty) {
      set = picked;
    } else {
      final out = <dom.Element>[];
      for (final e in picked) {
        out.addAll(selectElements(e, rest));
      }
      set = out;
    }
  }
  // jsoup 的 select 每个元素只出现一次：多个兄弟起点会重复命中同一批元素
  // （两个 `dt ~ dd` 起点各带一遍 dd），这里按身份去重保序。
  final seen = <dom.Element>{};
  final uniq = <dom.Element>[];
  for (final e in set) {
    if (seen.add(e)) uniq.add(e);
  }
  return uniq;
}

/// 在上下文节点（Document 或 Element）内执行 CSS 元素选择。
///
/// package:html/csslib 不支持的常见形态由本函数降级实现：
/// - 尾部 `:has(inner)`：先按 `sel` 选择，再按「存在后代匹配 inner」过滤；
/// - 尾部 jsoup 位置伪类 `:lt(n)` `:gt(n)` `:eq(n)`；
/// - 类型位置 `:nth-of-type(n)` `:first-of-type` `:last-of-type`；
/// - `[attr~=a|b]` 形态的属性正则（含正则特征时接管）。
List<dom.Element> selectElements(dom.Node context, String selector) {
  final s = selector.trim();
  if (s.isEmpty) return const [];
  final filter = _splitTrailingFilter(s);
  if (filter != null) {
    return _applyListFilter(selectElements(context, filter.$1), filter.$2);
  }
  // 兄弟组合子 `~`/`+`：命中靠自实现的链式求值，能与 jsoup 伪类共存。
  // 非空即采用；为空时继续走原路径（兼容 package:html 自己的语义）。
  final chain = _splitSiblingChain(s);
  if (chain != null) {
    final out = _selectBySiblingChain(context, chain);
    if (out.isNotEmpty) return out;
  }
  final has = _splitTrailingHas(s);
  if (has != null) {
    return [
      for (final e in selectElements(context, has.$1))
        if (e.querySelector(has.$2) != null) e,
    ];
  }
  // jsoup 文本伪类 `:contains(text)` / `:containsOwn(text)`（9 个源在用）：
  // package:html 不认识，静默 0 命中。语义对齐 jsoup——`contains` 看整棵
  // 子树的 `text`，`containsOwn` 只看元素自身直接文本，均大小写不敏感。
  final cont = _containsPseudo.firstMatch(s);
  if (cont != null) {
    final own = cont.group(1) != null;
    final needle = cont
        .group(2)!
        .trim()
        .replaceAll(RegExp(r'''^["']+|["']+$'''), '')
        .trim()
        .toLowerCase();
    final base = (s.substring(0, cont.start) + s.substring(cont.end)).trim();
    if (needle.isEmpty) return selectElements(context, base);
    final pool = base.isEmpty ? _allElements(context) : selectElements(context, base);
    return [
      for (final e in pool)
        if ((own ? _ownText(e) : e.text).toLowerCase().contains(needle)) e,
    ];
  }
  final attrRe = _splitAttrRegex(s);
  if (attrRe != null) {
    final base = selectElements(context, attrRe.$1);
    final re = _safeRegExp(attrRe.$3);
    if (re == null) return base;
    return [
      for (final e in base)
        if (re.hasMatch(e.attributes[attrRe.$2] ?? '')) e,
    ];
  }
  // `text.XXX`：按「元素自身文本（ownText）包含 XXX」选元素（对齐 legado
  // `getElementsContainingOwnText`，大小写不敏感）。阅读源常见，如
  // text.下一页@href、text.章节目录@href。若用全文 `e.text`，祖先节点
  // （html/body 的聚合文本）会抢先命中，`@href` 便提取不到真正的链接。
  if (s.startsWith('text.')) {
    final needle = s.substring(5).split('.').first.trim().toLowerCase();
    if (needle.isEmpty) return const [];
    final all = context is dom.Document
        ? context.querySelectorAll('*')
        : context is dom.Element
            ? context.querySelectorAll('*')
            : const <dom.Element>[];
    return [
      for (final e in all)
        if (_ownText(e).toLowerCase().contains(needle)) e,
    ];
  }
  // 位置伪类出现在组合选择器中间（`span:nth-child(2) a`）时 package:html 不支持
  // （`:nth-child` 静默 0 命中、`:nth-of-type` 直接抛 UnimplementedError）。
  // 按顶层空格切段逐段选择，段内的位置伪类退化成尾部过滤（新龙小说网等依赖此形态）。
  if (_selectorNeedsStaging(s)) {
    final parts = _splitTopLevelSpaces(s);
    if (parts.length > 1) {
      var cur = selectElements(context, parts.first);
      for (var i = 1; i < parts.length && cur.isNotEmpty; i++) {
        final next = <dom.Element>[];
        for (final e in cur) {
          next.addAll(selectElements(e, parts[i]));
        }
        cur = next;
      }
      return cur;
    }
  }
  try {
    if (context is dom.Document) {
      return context.querySelectorAll(s);
    }
    if (context is dom.Element) {
      return context.querySelectorAll(s);
    }
    return const [];
  } catch (_) {
    // 选择器语法不支持：返回空结果（与“找不到元素”同语义）
    return const [];
  }
}

// ---------- 组合选择器里的位置伪类 ----------

/// jsoup 文本伪类：`:contains(x)` / `:containsOwn(x)`。
final RegExp _containsPseudo =
    RegExp(r':contains(own)?\(\s*([^)]*)\)', caseSensitive: false);

/// 上下文下的全部元素（Document / Element 统一入口）。
List<dom.Element> _allElements(dom.Node context) {
  if (context is dom.Document) return context.querySelectorAll('*');
  if (context is dom.Element) return context.querySelectorAll('*');
  return const [];
}


final RegExp _posPseudo = RegExp(
    r':(nth-child|nth-last-child|nth-of-type|eq|lt|gt)\s*\('
    r'|:(first-child|last-child|first-of-type|last-of-type)(?![-\w])');

/// 选择器是否需要「切段选择」：含位置伪类、含顶层空格、且没有 `>`/`+`/`~`
/// 这类兄弟/子代组合子（有的话语义交给 package:html，失败为原语义）。
bool _selectorNeedsStaging(String s) {
  if (!s.contains(' ')) return false;
  if (s.contains('>') || s.contains('+') || s.contains('~')) return false;
  return _posPseudo.hasMatch(s);
}

/// 按顶层空格切分（括号/中括号内与引号内的空格不切）。
List<String> _splitTopLevelSpaces(String s) {
  final out = <String>[];
  final buf = StringBuffer();
  var depth = 0;
  String? quote;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (quote != null) {
      buf.write(ch);
      if (ch == quote) quote = null;
      continue;
    }
    if (ch == '"' || ch == "'") {
      quote = ch;
      buf.write(ch);
      continue;
    }
    if (ch == '(' || ch == '[') {
      depth++;
      buf.write(ch);
      continue;
    }
    if (ch == ')' || ch == ']') {
      if (depth > 0) depth--;
      buf.write(ch);
      continue;
    }
    if (depth == 0 &&
        (ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r')) {
      final t = buf.toString().trim();
      if (t.isNotEmpty) out.add(t);
      buf.clear();
      continue;
    }
    buf.write(ch);
  }
  final t = buf.toString().trim();
  if (t.isNotEmpty) out.add(t);
  return out;
}

// ---------- 尾部过滤伪类 ----------

/// 元素自身的文本（仅直接子文本节点；`<br>` 计为换行）。
/// 对齐 jsoup `Element.ownText()`。
String _ownText(dom.Element el) {
  final buf = StringBuffer();
  for (final n in el.nodes) {
    if (n is dom.Text) {
      buf.write(n.text);
    } else if (n is dom.Element && n.localName == 'br') {
      buf.write('\n');
    }
  }
  return buf.toString();
}

final RegExp _filterSuffix = RegExp(
    r':(lt|gt|eq|nth-last-child|nth-child|nth-of-type|first-child|last-child|first-of-type|last-of-type)\s*(?:\(([^()]*)\))?\s*$');

(String, (String, String?))? _splitTrailingFilter(String s) {
  final m = _filterSuffix.firstMatch(s);
  if (m == null) return null;
  final name = m.group(1)!;
  final arg = m.group(2)?.trim();
  if (name == 'lt' || name == 'gt' || name == 'eq' || name == 'nth-of-type' ||
      name == 'nth-child' || name == 'nth-last-child') {
    if (arg == null || arg.isEmpty) return null;
  }
  final base = s.substring(0, m.start).trim();
  if (base.isEmpty) return null;
  return (base, (name, arg));
}

List<dom.Element> _applyListFilter(List<dom.Element> list, (String, String?) f) {
  switch (f.$1) {
    case 'lt':
      final n = int.tryParse(f.$2 ?? '') ?? 0;
      final out = <dom.Element>[];
      for (var i = 0; i < list.length && i < n; i++) {
        out.add(list[i]);
      }
      return out;
    case 'gt':
      final n = int.tryParse(f.$2 ?? '') ?? 0;
      final out = <dom.Element>[];
      for (var i = n + 1; i < list.length; i++) {
        out.add(list[i]);
      }
      return out;
    case 'eq':
      final n = int.tryParse(f.$2 ?? '') ?? 0;
      return (n >= 0 && n < list.length) ? [list[n]] : const [];
    case 'nth-of-type':
      return [for (final e in list) if (_matchNthOfType(e, f.$2!)) e];
    case 'nth-child':
      return [for (final e in list) if (_matchNth(_childPosition(e), f.$2!)) e];
    case 'nth-last-child':
      return [
        for (final e in list)
          if (_matchNth(
              _childPosition(e, total: true) - _childPosition(e) + 1, f.$2!))
            e,
      ];
    case 'first-child':
      return [for (final e in list) if (_childPosition(e) == 1) e];
    case 'last-child':
      return [
        for (final e in list)
          if (_childPosition(e) == _childPosition(e, total: true)) e,
      ];
    case 'first-of-type':
      return [for (final e in list) if (_typePosition(e) == 1) e];
    case 'last-of-type':
      return [
        for (final e in list)
          if (_typePosition(e) == _typePosition(e, total: true)) e,
      ];
  }
  return list;
}

/// 元素在「同父同名元素」中的位置（1 起）；[total] 为 true 时返回总数。
int _typePosition(dom.Element el, {bool total = false}) {
  final parent = el.parent;
  if (parent == null) return 1;
  final name = el.localName;
  var pos = 0;
  for (final c in parent.children) {
    if (c.localName == name) {
      pos++;
      if (!total && identical(c, el)) return pos;
    }
  }
  return total ? pos : (pos == 0 ? 1 : pos);
}

/// 元素在**同父全部元素**中的位置（1 起，对应 CSS `:nth-child`）；
/// [total] 为 true 时返回同父元素总数（供 `:nth-last-child` / `:last-child`）。
int _childPosition(dom.Element el, {bool total = false}) {
  final parent = el.parent;
  if (parent == null) return 1;
  var pos = 0;
  for (final c in parent.children) {
    pos++;
    if (!total && identical(c, el)) return pos;
  }
  return total ? pos : (pos == 0 ? 1 : pos);
}

bool _matchNthOfType(dom.Element el, String spec) =>
    _matchNth(_typePosition(el), spec);

bool _matchNth(int pos, String spec) {
  final t = spec.trim().toLowerCase();
  if (t == 'odd') return pos % 2 == 1;
  if (t == 'even') return pos % 2 == 0;
  final n = int.tryParse(t);
  if (n != null) return pos == n;
  final m = RegExp(r'^([+-]?\d*)n\s*([+-]\s*\d+)?$').firstMatch(t);
  if (m == null) return false;
  var a = m.group(1) ?? '';
  final b = int.tryParse((m.group(2) ?? '0').replaceAll(' ', '')) ?? 0;
  final aVal = a.isEmpty || a == '+' ? 1 : (a == '-' ? -1 : int.parse(a));
  if (aVal == 0) return pos == b;
  final k = (pos - b) / aVal;
  return k >= 0 && k == k.floorToDouble();
}

// ---------- `:has` / `~=` ----------

/// 拆分尾部 `sel:has(inner)`；复杂形态（嵌套括号 / 逗号列表 / 子代 `>`）返回 null，
/// 走原逻辑失败为原语义。
(String, String)? _splitTrailingHas(String selector) {
  final s = selector.trim();
  if (!s.endsWith(')')) return null;
  final i = s.lastIndexOf(':has(');
  if (i <= 0) return null;
  final inner = s.substring(i + 5, s.length - 1).trim();
  if (inner.isEmpty ||
      inner.contains('(') ||
      inner.contains(')') ||
      inner.contains(',') ||
      inner.contains(':') ||
      inner.contains('>')) {
    return null;
  }
  final base = s.substring(0, i).trim();
  if (base.isEmpty || base.contains(',')) return null;
  return (base, inner);
}

/// 拆分 jsoup 风格 `[attr~=regex]`（仅当值含正则特征时接管；普通词匹配交给 csslib）。
(String, String, String)? _splitAttrRegex(String selector) {
  final ms = RegExp(r'\[([\w:-]+)\s*~=\s*([^\[\]]+)\]').allMatches(selector);
  if (ms.isEmpty) return null;
  final m = ms.last;
  final pattern = m.group(2)!.trim();
  if (!pattern.contains('|') &&
      !pattern.contains('*') &&
      !pattern.contains('^') &&
      !pattern.contains(r'$') &&
      !pattern.contains('(')) {
    return null;
  }
  final base = (selector.substring(0, m.start) + selector.substring(m.end)).trim();
  return (base.isEmpty ? '*' : base, m.group(1)!, pattern);
}

RegExp? _safeRegExp(String p) {
  try {
    return RegExp(p);
  } catch (_) {
    return null;
  }
}

// ---------- 阶段求值 ----------

/// 按阶段求值。
///
/// [context] 为文档或元素；返回：
/// - 未到提取器：`List<dom.Element>`
/// - 已到提取器：`List<String>`
List<Object> evalCss(dom.Node context, List<CssStage> stages) {
  var current = <dom.Node>[context];
  for (var i = 0; i < stages.length; i++) {
    final stage = stages[i];
    switch (stage.type) {
      case CssStageType.selector:
        final next = <dom.Node>[];
        for (final node in current) {
          next.addAll(selectElements(node, stage.value));
        }
        // 首段是「纯属性名」形态且一个标签都没选到时，退回取当前节点的同名属性：
        // 大量书源的 chapterUrl 直接写 `href`（要的是属性，不是 <href> 标签）。
        if (next.isEmpty &&
            i == 0 &&
            _attrNameRe.hasMatch(stage.value) &&
            context is dom.Element) {
          final v = context.attributes[stage.value];
          if (v != null && v.trim().isNotEmpty) return [v.trim()];
        }
        current = next;
      case CssStageType.position:
        final idx0 = int.tryParse(stage.value) ?? 0;
        final idx = idx0 < 0 ? current.length + idx0 : idx0;
        current = (idx >= 0 && idx < current.length)
            ? [current[idx]]
            : const <dom.Node>[];
      case CssStageType.range:
        current = _applyRange(current, stage.value);
      case CssStageType.extractor:
        return _extract(current, stage.value);
    }
    if (current.isEmpty) return const <Object>[];
  }
  return List<Object>.from(current);
}

List<dom.Node> _applyRange(List<dom.Node> cur, String spec) {
  if (cur.isEmpty) return cur;
  final s = spec.trim();
  if (s.startsWith('!')) {
    final excl = _parseIndexSet(s.substring(1), cur.length);
    if (excl.isEmpty) return cur;
    final keep = <dom.Node>[];
    for (var i = 0; i < cur.length; i++) {
      if (!excl.contains(i)) keep.add(cur[i]);
    }
    return keep;
  }
  if (s.contains(':') && !s.contains(',')) {
    final pair = s.split(':');
    var from = pair[0].trim().isEmpty ? 0 : int.tryParse(pair[0].trim()) ?? 0;
    var to = (pair.length > 1 && pair[1].trim().isNotEmpty)
        ? int.tryParse(pair[1].trim()) ?? cur.length
        : cur.length;
    if (from < 0) from += cur.length;
    if (to < 0) to += cur.length;
    from = from.clamp(0, cur.length);
    to = to.clamp(0, cur.length);
    if (from >= to) return const [];
    return cur.sublist(from, to);
  }
  if (s.contains(',')) {
    final out = <dom.Node>[];
    for (final t in s.split(',')) {
      final i0 = int.tryParse(t.trim());
      if (i0 == null) continue;
      final i = i0 < 0 ? cur.length + i0 : i0;
      if (i >= 0 && i < cur.length) out.add(cur[i]);
    }
    return out;
  }
  final i0 = int.tryParse(s);
  if (i0 == null) return cur;
  final i = i0 < 0 ? cur.length + i0 : i0;
  return (i >= 0 && i < cur.length) ? [cur[i]] : const [];
}

Set<int> _parseIndexSet(String s, int len) {
  final out = <int>{};
  for (final t in s.split(RegExp(r'[:,\s]+'))) {
    final v = int.tryParse(t.trim());
    if (v == null) continue;
    final i = v < 0 ? len + v : v;
    if (i >= 0 && i < len) out.add(i);
  }
  return out;
}

List<String> _extract(List<dom.Node> nodes, String extractor) {
  final out = <String>[];
  for (final node in nodes) {
    final el = node is dom.Element ? node : null;
    switch (extractor) {
      case 'text':
        if (el != null) {
          final t = RuleAnalyzer.collapseSpaces(el.text);
          if (t.isNotEmpty) out.add(t);
        }
      case 'textNodes':
        if (el != null) {
          for (final n in el.nodes) {
            if (n is dom.Text) {
              final t = RuleAnalyzer.collapseSpaces(n.text);
              if (t.isNotEmpty) out.add(t);
            }
          }
        }
      case 'ownText':
        if (el != null) {
          final t = RuleAnalyzer.collapseSpaces(_ownText(el));
          if (t.isNotEmpty) out.add(t);
        }
      case 'html':
        if (el != null) {
          final t = el.innerHtml.trim();
          if (t.isNotEmpty) out.add(t);
        }
      case 'all':
        if (el != null) {
          final t = RuleAnalyzer.collapseSpaces(el.text);
          out.add(t);
        }
      default:
        if (el != null) {
          final v = el.attributes[extractor];
          if (v != null && v.trim().isNotEmpty) out.add(v.trim());
        }
    }
  }
  return out;
}
