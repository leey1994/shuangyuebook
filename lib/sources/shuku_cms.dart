import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'source.dart';

/// 神文小说 / 智能书库 共用的同款 CMS 基类。
///
/// - 搜索：POST `/search.html` 表单 `{s}`（智能书库需多轮 JS 种 cookie 解锁，
///   神文未登录会 302 到登录页 → 搜索优雅返回 `[]`）；
/// - 正文：段落以 `xx.yy('BASE64')` 写入页面 → [parasFromB64Writes]；
/// - 目录/章内翻页：文案 ∈ {下一页, 下页, 下一章} + 文件名茎护栏
///   （末页的「下一页」常指回目录，茎不同即不跟）。
abstract class ShukuCmsSource extends NovelSource {
  /// 卡片（首页/排行/搜索共用）：标题链接 + 作者/简介/封面。
  List<Book> parseCards(Document doc, String pageUrl);

  @override
  Future<List<Book>> search(String query) async {
    final r = await Net.postForm(
      '$baseUrl/search.html',
      {'s': query},
      referer: '$baseUrl/',
    );
    if (r.status != 200) return [];
    // 登录墙：302 后落地 /login.html 或页面上直接是登录表单
    if (r.body.contains('login.html') &&
        !r.body.contains('search') &&
        r.body.length < 8000) {
      return [];
    }
    final doc = parseHtml(r.body);
    final out = parseCards(doc, r.url);
    if (out.isEmpty && r.body.contains('login.html')) return [];
    return out;
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    // base64 写入型
    final b64 = parasFromB64Writes(doc.documentElement?.innerHtml ?? '');
    if (b64.isNotEmpty) return b64;
    // 兜底：常规正文容器
    final box = doc.querySelector('#content, #chaptercontent, .content');
    if (box != null) return parasInContainer(box);
    // 序/楔子等无 b64 章：正文直排 .info_dv1 p（滤二维码/手打中等提示行）
    final out = <String>[];
    for (final p in doc.querySelectorAll('.info_dv1 p')) {
      final t = cleanText(p.text);
      if (t.isEmpty ||
          t.contains('扫描二维码') ||
          t.contains('正在手打中') ||
          t.contains('请关闭浏览器阅读模式') ||
          t.contains('内容更新后')) {
        continue;
      }
      out.add(t);
    }
    return out;
  }

  @override
  String? pageNextUrl(Document doc, String currentUrl) {
    final curStem = stem(currentUrl);
    for (final a in doc.querySelectorAll('a[href]')) {
      final t = cleanText(a.text);
      if (t != '下一页' && t != '下页' && t != '下一章') continue;
      final href = a.attributes['href'];
      if (href == null || href.isEmpty || href.startsWith('javascript')) {
        continue;
      }
      final next = absUrl(currentUrl, href);
      if (next == currentUrl) continue;
      if (!sameStem(curStem, next)) continue; // 末页常指回目录 → 茎护栏
      return next;
    }
    return null;
  }

  /// URL 最后一段的「数字茎」：`123.html` → `123`，`12_2.html` → `12`；
  /// 无数字茎返回 null（不设护栏，放行）。
  static String? stem(String url) {
    final path = Uri.parse(url).path;
    final seg = path.split('/').last;
    final m = RegExp(r'^(\d+)(_\d+)?\.html?$').firstMatch(seg);
    return m?.group(1);
  }

  /// 章内翻页茎护栏（子类覆盖 pageNextUrl 时复用）。
  static bool sameStem(String? cur, String next) {
    if (cur == null) return true;
    final ns = stem(next);
    if (ns == null) return false; // 下一页不是分页文件形态 → 不跟
    return ns == cur; // 章内分页必须同茎；指回目录（茎不同）→ 不跟
  }

  /// 列表分页「下一页」：文案含 下一页/下页 + [next] 以 [root] 开头 + ≠当前页
  /// + 末段页码递增（pageOf：尾段剥 `.html` 取尾数字；cp null 放行、np null 拒）。
  static String? listNext(Document doc, String currentUrl, String root) {
    for (final a in doc.querySelectorAll('a[href]')) {
      final t = cleanText(a.text);
      if (!t.contains('下一页') && !t.contains('下页')) continue;
      final href = a.attributes['href'];
      if (href == null || href.isEmpty || href.startsWith('javascript')) {
        continue;
      }
      final next = absUrl(currentUrl, href);
      if (next == currentUrl) continue;
      if (!Uri.parse(next).path.startsWith(root)) continue;
      final cp = pageOf(currentUrl);
      final np = pageOf(next);
      if (np == null) continue; // 下一页无页码 → 拒
      if (cp != null && np <= cp) continue;
      return next;
    }
    return null;
  }

  /// 路径末段页码：`/c/xuanhuan_2.html` → 2；`/xuanhuan/` → null。
  static int? pageOf(String url) {
    final seg = Uri.parse(url).path.split('/').last;
    final m = RegExp(r'(\d+)(?:\.\w+)?$').firstMatch(seg);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  /// 目录路径（rank 分页护栏用）：`/xuanhuan/2/` → `/xuanhuan/`。
  static String dirOf(String url) {
    final p = Uri.parse(url).path;
    return p.substring(0, p.lastIndexOf('/') + 1);
  }

  // ---------- 首页 / 排行（子类按站实现） ----------

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return parseCards(doc, '$baseUrl/');
  }

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);
}
