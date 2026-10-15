// 书内全文搜索：在**已缓存**的章节正文里找一段文字。
//
// 纯函数，不碰 IO —— 缓存读取在 AppStore.cachedTexts，界面在
// BookSearchSheet。这样搜索逻辑能脱离 Flutter 直接单测。
library;

import '../models.dart';

/// 一处命中：第 [chapterIndex] 章第 [paraIndex] 段；[snippet] 里
/// [matchStart] 起 [matchLen] 个字符即查询词（用于高亮）。
class BookHit {
  const BookHit({
    required this.chapterIndex,
    required this.paraIndex,
    required this.chapterTitle,
    required this.snippet,
    required this.matchStart,
    required this.matchLen,
  });

  final int chapterIndex;
  final int paraIndex;
  final String chapterTitle;
  final String snippet;
  final int matchStart;
  final int matchLen;
}

/// 在缓存正文里搜 [query]，返回最多 [limit] 处命中（按章节顺序）。
///
/// [texts]：chapterUrl → 段落数组（AppStore 缓存格式）。章节标题命中
/// 也算一处（跳到该章开头，paraIndex = 0）。大小写不敏感。
List<BookHit> searchBookTexts({
  required List<Chapter> chapters,
  required Map<String, List<String>> texts,
  required String query,
  int limit = 100,
}) {
  final q = query.trim();
  if (q.isEmpty || chapters.isEmpty) return const [];
  final ql = q.toLowerCase();
  final out = <BookHit>[];

  for (var i = 0; i < chapters.length && out.length < limit; i++) {
    final ch = chapters[i];
    // 标题命中：跳到章首
    final ti = ch.title.toLowerCase().indexOf(ql);
    if (ti >= 0) {
      out.add(BookHit(
        chapterIndex: i,
        paraIndex: 0,
        chapterTitle: ch.title,
        snippet: ch.title,
        matchStart: ti,
        matchLen: q.length,
      ));
      if (out.length >= limit) break;
    }
    final paras = texts[ch.url];
    if (paras == null) continue;
    for (var pi = 0; pi < paras.length && out.length < limit; pi++) {
      final para = paras[pi];
      final idx = para.toLowerCase().indexOf(ql);
      if (idx < 0) continue;
      // 每段只取第一处：同一个词刷一整段没有增量价值
      out.add(_snippetHit(ch.title, i, pi, para, idx, q.length));
    }
  }
  return out;
}

BookHit _snippetHit(
    String title, int ci, int pi, String para, int idx, int len) {
  var s = idx - 24;
  if (s < 0) s = 0;
  var e = idx + len + 24;
  if (e > para.length) e = para.length;
  var text = para.substring(s, e);
  var ms = idx - s;
  if (s > 0) {
    text = '…$text';
    ms++;
  }
  if (e < para.length) text = '$text…';
  return BookHit(
    chapterIndex: ci,
    paraIndex: pi,
    chapterTitle: title,
    snippet: text,
    matchStart: ms,
    matchLen: len,
  );
}
