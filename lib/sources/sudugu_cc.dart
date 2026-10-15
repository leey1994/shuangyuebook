import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';

import '../dom.dart';
import '../models.dart';
import '../net.dart';
import 'shuku_cms.dart';
import 'source.dart';

/// 伪速读谷 www.sudugu.cc（速读谷同款模板；正文是站内 `_2.html` 分页，
/// 不像 suduguu.com 那样走外部脚本注入）。
///
/// - 搜索：GET `/modules/article/search.php?searchkey=&searchtype=articlename`；
/// - 卡片：`.itemtxt`（h3 书名 + li 作者/更新 + p 简介），首页同款；
/// - 详情：h1 书名 / `authorarticle` 链接作者 / 分类状态 span / `.des` 简介；
/// - 目录：`#list ul li a`（升序）；
/// - 正文：`.con`（`<br/>` 分段）；章内分页 `123_2.html` 茎护栏。
class SuduguCcSource extends NovelSource {
  @override
  String get id => 'sudugu_cc';
  @override
  String get name => '伪速读谷';
  @override
  String get baseUrl => 'https://www.sudugu.cc';

  /// 书籍地址形态：站点根下的纯数字（`/1776/`）。
  static final _bookUrlRe = RegExp(r'^https?://[^/]+/\d+/?$');

  List<Book> _cards(Document doc, String pageUrl) {
    final out = <Book>[];
    final seen = <String>{};
    for (final box in doc.querySelectorAll('.itemtxt')) {
      final a = box.querySelector('h3 a');
      final href = a?.attributes['href'];
      if (a == null || href == null || href.isEmpty) continue;
      final url = absUrl(pageUrl, href);
      if (!_bookUrlRe.hasMatch(url)) continue;
      if (!seen.add(url)) continue;
      String author = '';
      String latest = '';
      for (final li in box.querySelectorAll('ul li')) {
        final t = textOf(li);
        if (t.startsWith('作者：')) author = t.substring(3).trim();
        if (t.startsWith('更新')) latest = textOf(li.querySelector('a'));
      }
      var intro = textOf(box.querySelector('p'));
      if (intro.startsWith('简介：')) intro = intro.substring(3).trim();
      out.add(Book(
        sourceId: id,
        id: url,
        url: url,
        title: textOf(a),
        author: author.isEmpty ? null : author,
        latest: latest.isEmpty ? null : latest,
        intro: intro.isEmpty ? null : intro,
      ));
    }
    return out;
  }

  @override
  Future<List<Book>> fetchHome() async {
    final doc = await fetchDoc('$baseUrl/');
    return _cards(doc, baseUrl);
  }

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  @override
  Future<List<Book>> search(String query) async {
    final r = await Net.get(
      '$baseUrl/modules/article/search.php'
      '?searchkey=${Uri.encodeQueryComponent(query)}&searchtype=articlename',
      referer: '$baseUrl/',
    );
    if (r.status != 200) return [];
    final doc = parseHtml(r.body);
    // 杰奇搜索：命中唯一书名会 302 到书籍详情页，直接按书籍页解析一条结果
    final h1a = doc.querySelector('.itemtxt h1 a');
    if (h1a != null) {
      final href = (h1a.attributes['href'] ?? '').split('#').first;
      final url = absUrl(r.url, href);
      if (_bookUrlRe.hasMatch(url)) {
        final spans = doc.querySelectorAll('.itemtxt p span');
        final ulA = doc.querySelector('ul li a');
        final authorA = doc.querySelector('a[href*="authorarticle"]');
        final author = authorA == null ? '' : textOf(authorA);
        final img = doc.querySelector('.item img');
        final cover = img?.attributes['src'];
        return [
          Book(
            sourceId: id,
            id: url,
            url: url,
            title: textOf(h1a),
            author: author.isEmpty
                ? null
                : (author.startsWith('作者：')
                    ? author.substring(3).trim()
                    : author),
            cover: (cover == null || cover.isEmpty)
                ? null
                : absUrl(url, cover),
            intro: textOf(doc.querySelector('.des')),
            status: spans.isNotEmpty ? cleanText(spans.first.text) : null,
            latest: ulA == null ? null : textOf(ulA),
          ),
        ];
      }
    }
    return _cards(doc, r.url);
  }

  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final doc = await fetchDoc(book.url);
    final chapters =
        chapterLinks(doc, '#list ul li a, #list li a', book.url);
    final name = textOf(doc.querySelector('.itemtxt h1 a'));

    String? author;
    final authorA = doc.querySelector('a[href*="authorarticle"]');
    if (authorA != null) {
      final t = textOf(authorA);
      author = t.startsWith('作者：') ? t.substring(3).trim() : t;
    }
    final spans = doc.querySelectorAll('.itemtxt p span');
    final status = spans.isNotEmpty ? cleanText(spans.first.text) : null;

    final img = doc.querySelector('.item img');
    final cover = img?.attributes['src'];
    var intro = textOf(doc.querySelector('.des'));
    if (intro.isEmpty) intro = book.intro ?? '';

    return BookDetail(
      book: Book(
        sourceId: book.sourceId,
        id: book.id,
        url: book.url,
        title: name.isEmpty ? book.title : name,
        author: (author ?? '').isEmpty ? book.author : author,
        cover: (cover == null || cover.isEmpty)
            ? book.cover
            : absUrl(book.url, cover),
        intro: intro.isEmpty ? book.intro : intro,
        status: (status ?? '').isEmpty ? book.status : status,
        latest: chapters.isNotEmpty ? chapters.last.title : book.latest,
      ),
      chapters: chapters,
    );
  }

  static const _junk = [
    '一秒记住', '无弹窗', '请记住', '最新网址', '天才一秒', 'txt下载', '手机用户',
  ];

  /// 乱码特征字：UTF-8 字节被按 GBK 解出来的高频字（銆绗鈥锛…）。
  static final _mojibake = RegExp(r'[銆绗鈥锛鐨鏄鐞鎾]');

  /// 站点把正文存成了双重编码：真实文本 T → `gbk.decode(utf8.encode(T))`，
  /// 浏览器里直接看到「銆銆绗1绔」这种乱码（目录与书名是好的，只有正文坏，
  /// 且只有 1933 这类库内数据坏的书；/1776/ 等其他书是正常 UTF-8）。
  /// 逆变换即可还原：`utf8.decode(gbk.encode(mojibake))`。只对带乱码特征字
  /// 的段落动手；还原后特征字仍在就回退原文。若站点当年丢过字节，还原结果
  /// 会剩少量 \uFFFD 替换字——信息已失，救不回，但剩下的正文可读。
  static String _fixMojibake(String s) {
    if (!_mojibake.hasMatch(s)) return s;
    try {
      final back = utf8.decode(gbk.encode(s), allowMalformed: true);
      return _mojibake.hasMatch(back) ? s : back;
    } catch (_) {
      return s;
    }
  }

  @override
  List<String> contentOf(Document doc, String pageUrl) {
    final box = doc.querySelector('.con');
    return [
      for (final t in parasInContainer(box))
        if (!_junk.any(t.contains)) _fixMojibake(t),
    ];
  }

  @override
  bool allowFollow(String currentUrl, String nextUrl) =>
      ShukuCmsSource.sameStem(ShukuCmsSource.stem(currentUrl), nextUrl);
}
