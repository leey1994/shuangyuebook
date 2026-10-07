import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

export 'package:html/dom.dart' show Document, Element;

/// 解析 HTML 文档。
Document parseHtml(String html) => html_parser.parse(html);

/// 相对地址转绝对地址。
String absUrl(String base, String? href) {
  if (href == null || href.isEmpty) return base;
  final b = Uri.parse(base);
  if (href.startsWith('http://') || href.startsWith('https://')) return href;
  if (href.startsWith('//')) return '${b.scheme}:$href';
  if (href.startsWith('/')) return '${b.origin}$href';
  return b.resolveUri(Uri.parse(href)).toString();
}

/// 清洗文本：去首尾空白、全角空格转普通、压缩连续空白。
String cleanText(String s) {
  var t = s.replaceAll('\u3000', ' ').replaceAll('\xa0', ' ');
  t = t.replaceAll(RegExp(r'[ \t\r\n]+'), ' ');
  return t.trim();
}

/// 取元素文本（清洗后），元素为空返回 ''。
String textOf(Element? e) => e == null ? '' : cleanText(e.text);

/// 取 meta 标签 content：优先 property，其次 name。
String? metaContent(Document doc, String key) {
  final els = doc
      .querySelectorAll('meta')
      .where((m) =>
          (m.attributes['property'] ?? m.attributes['name']) == key)
      .toList();
  if (els.isEmpty) return null;
  final v = els.last.attributes['content'];
  return v == null || v.trim().isEmpty ? null : v.trim();
}

/// 找到文字等于（或包含）[label] 的第一个链接，返回其绝对地址。
String? findLinkByText(Document doc, String label, {bool contains = false}) {
  for (final a in doc.querySelectorAll('a')) {
    final t = cleanText(a.text);
    final hit = contains ? t.contains(label) : t == label;
    if (hit) {
      final href = a.attributes['href'];
      if (href != null && href.isNotEmpty && !href.startsWith('javascript')) {
        return href;
      }
    }
  }
  return null;
}

/// 通用分页「下一页」链接（列表页 / 章内分页 / 目录翻页通用）。
/// 只认文字为「下一页」的链接：各站的「下一章」文字不同，天然区分。
String? nextPageUrl(Document doc, String currentUrl) {
  for (final a in doc.querySelectorAll('a')) {
    final t = cleanText(a.text);
    if (t != '下一页' && t != '下页') continue;
    final href = a.attributes['href'];
    if (href == null || href.isEmpty || href.startsWith('javascript')) continue;
    final next = absUrl(currentUrl, href);
    if (next != currentUrl) return next;
  }
  return null;
}

/// 段落通用清洗：去空行、去带链接的广告行。
List<String> cleanParas(List<String> raw) {
  final out = <String>[];
  for (var p in raw) {
    p = p.replaceAll('\u3000', ' ').replaceAll('\xa0', ' ').trim();
    if (p.isEmpty) continue;
    if (p.contains('http://') || p.contains('https://')) continue;
    out.add(p);
  }
  return out;
}

/// 解 JS 字符串转义（`\"` `\\` `\n` `\x41` `\u4e2d` 等）。
String _unescapeJs(String s) => s.replaceAllMapped(
      RegExp(r'\\(u[0-9a-fA-F]{4}|x[0-9a-fA-F]{2}|.)'),
      (m) {
        final g = m.group(1)!;
        final c = g[0];
        if (c == 'u' || c == 'x') {
          return String.fromCharCode(int.parse(g.substring(1), radix: 16));
        }
        switch (g) {
          case 'n':
            return '\n';
          case 'r':
            return '';
          case 't':
            return ' ';
          default:
            return g;
        }
      },
    );

/// 外部正文脚本（速读谷 `/i/a.aspx`）返回 `document.write("<p>…</p>");`。
/// 提取所有 write 参数、解转义、解析为段落；无 `<p>` 时按整段文本兜底。
List<String> parasFromDocWrite(String js) {
  final re = RegExp(r'document\.write\("((?:[^"\\]|\\.)*)"\)');
  final buf = StringBuffer();
  for (final m in re.allMatches(js)) {
    buf.write(_unescapeJs(m.group(1)!));
  }
  if (buf.isEmpty) return [];
  final doc = html_parser.parse(buf.toString());
  final ps = <String>[];
  for (final e in doc.querySelectorAll('p')) {
    final t = cleanText(e.text);
    if (t.isNotEmpty) ps.add(t);
  }
  if (ps.isNotEmpty) return ps;
  final t = cleanText(doc.body?.text ?? '');
  return t.isEmpty ? <String>[] : [t];
}

/// `书名_作者【状态】` 形式的标题拆分（52书库）。
({String title, String? author}) splitTitleAuthor(String raw) {
  var s = raw.trim();
  // 去掉开头的序号 "12、" / "12. "
  s = s.replaceFirst(RegExp(r'^\s*\d+\s*[、.．,，]\s*'), '');
  String? author;
  final i = s.indexOf('_');
  if (i > 0) {
    author = s.substring(i + 1).trim();
    s = s.substring(0, i).trim();
    // 作者后面的【完结】等状态并入 status 时直接保留在作者里不合适，剔除
    final br = author.indexOf('【');
    if (br >= 0) author = author.substring(0, br).trim();
    if (author.isEmpty) author = null;
  }
  return (title: s, author: author);
}
