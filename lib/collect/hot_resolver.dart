// 热榜落地：把权威榜单上的书名，拿回用户自己的可用书源里搜一遍。
//
// 这是「排行榜能读」的关键一步：榜单站（百度热搜 / 17K）只是告诉我们
// 「大家在看什么」，正文还得从用户装了的书源里取。命中就把书换成该书源里
// 的那一条，点进去直接是能读的详情页；没命中也不拦着用户 —— UI 给
// 「去书源里搜」的入口，仍然只在可用书源池里搜。
//
// 成本控制：每本书只试前 [sourcesPerItem] 个可用源（内置源在前，命中率最高），
// 命中即停；搜索结果复用 [FeedCache] 的 `search|<源>|<词>` 键，跟搜索页
// 共享缓存，用户随后自己搜同一本书时是秒开的。
library;

import '../feed_cache.dart';
import '../models.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import 'aggregate.dart';
import 'hot_board.dart';
import 'usable_sources.dart';

/// 热榜条目在「我的可用书源」里的落地结果。
class HotRankEntry {
  HotRankEntry(this.item);

  final HotItem item;

  /// 命中的可读书（未命中为 null）。
  Book? book;

  /// 命中所在书源。
  NovelSource? source;

  bool get readable => book != null;

  HotRankEntry clone() => HotRankEntry(item)
    ..book = book
    ..source = source;
}

/// 命中门槛：书名完全一致 1.0 / 前缀 0.9 / 包含 0.85，作者对上再加分。
const double kHotMatchThreshold = 0.84;

/// 榜单书名归一化：去尾部省略号（17K 会截断长书名），再走统一的去标点归一。
String normHotTitle(String raw) => normBookText(
      raw.replaceFirst(RegExp(r'\s*(\.{2,}|…+)\s*$'), ''),
    );

/// 实际送去书源搜索的词：原书名去掉排版省略号。
String hotSearchKeyword(HotItem item) =>
    item.title.replaceFirst(RegExp(r'\s*(\.{2,}|…+)\s*$'), '').trim();

/// 书名 + 作者匹配打分（0~1）。
///
/// 前缀/包含都要求「较短一侧 ≥ 4 字」：两个字的书名（「青山」「剑来」）
/// 做前缀匹配会把《青山依旧》《剑来2》都算命中，宁可漏也不要串书。
double hotMatchScore(HotItem item, Book b) {
  final h = normHotTitle(item.title);
  final t = normBookText(b.title);
  if (h.isEmpty || t.isEmpty) return 0;

  var score = 0.0;
  if (h == t) {
    score = 1.0;
  } else {
    final shorter = h.length <= t.length ? h : t;
    final longer = h.length <= t.length ? t : h;
    final ratio = longer.isEmpty ? 0.0 : shorter.length / longer.length;
    if (shorter.length >= 4 && longer.startsWith(shorter) && ratio >= 0.5) {
      score = 0.9;
    } else if (shorter.length >= 4 &&
        longer.contains(shorter) &&
        ratio >= 0.6) {
      score = 0.85;
    }
  }
  if (score == 0) return 0;

  // 作者门：两边都署了名、又明显不是同一人（互不包含）→ 同名也是别的书，
  // 直接拒绝（《诡秘之主》 vs 《诡秘之主同人：别册》就是栽在前缀匹配上）。
  // 互为包含算别名/简署（「乌贼」 ⊂ 「爱潜水的乌贼」），不冲突。
  final ha = normHotTitle(item.author ?? '');
  final ba = normBookText(b.author ?? '');
  if (ha.isNotEmpty && ba.isNotEmpty) {
    if (ha != ba && !ha.contains(ba) && !ba.contains(ha)) return 0;
    score += 0.1; // 作者对上：压过「书名像但署名缺失」的候选
  }
  return score.clamp(0, 1);
}

/// 匹配记忆：同一进程内不重复搜同一本书（切榜单 / 来回切页很常见）。
class HotMatchCache {
  HotMatchCache._();

  static const Duration ttl = Duration(minutes: 30);

  static final Map<String, (Book?, String?, DateTime)> _m = {};

  static (Book?, String?)? get(String title) {
    final e = _m[title];
    if (e == null) return null;
    if (DateTime.now().difference(e.$3) > ttl) {
      _m.remove(title);
      return null;
    }
    return (e.$1, e.$2);
  }

  static void put(String title, Book? book, String? sourceId) {
    _m[title] = (book, sourceId, DateTime.now());
  }

  static void clear() => _m.clear();
}

/// 把榜单条目逐条落回可用书源。
///
/// [sourcesPerItem]：每本书最多试几个源（内置源在前，命中即停）。
/// [onPartial]：每完成一条（节流 200ms）回一次快照，UI 先到先上屏。
/// [isCancelled]：翻页 / 切榜单时作废在途结果，避免白白跑完几十个请求。
Future<List<HotRankEntry>> resolveHotItems(
  List<HotItem> items, {
  int maxItems = 30,
  int sourcesPerItem = 5,
  int parallel = 6,
  List<NovelSource>? sources,
  bool Function()? isCancelled,
  void Function(int done, int total)? onProgress,
  void Function(List<HotRankEntry> partial)? onPartial,
}) async {
  final pool = sources ?? usableSources();
  final picked = items.take(maxItems).toList();
  final entries = [for (final i in picked) HotRankEntry(i)];
  final total = entries.length;
  var done = 0;
  var lastEmit = 0;

  void emit() {
    done++;
    onProgress?.call(done, total);
    if (onPartial == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (done == total || now - lastEmit >= 200) {
      lastEmit = now;
      onPartial([for (final e in entries) e.clone()]);
    }
  }

  await runPooled([
    for (final e in entries)
      () async {
        if (isCancelled?.call() ?? false) return;
        await resolveOneHotEntry(
          e,
          pool,
          sourcesPerItem: sourcesPerItem,
          isCancelled: isCancelled,
        );
        emit();
      },
  ], maxParallel: parallel);

  return entries;
}

/// 单条落地（独立出来便于单测 / 复用）。
Future<void> resolveOneHotEntry(
  HotRankEntry e,
  List<NovelSource> pool, {
  int sourcesPerItem = 5,
  bool Function()? isCancelled,
}) async {
  final memKey = normHotTitle(e.item.title);
  final memo = HotMatchCache.get(memKey);
  if (memo != null) {
    final (book, sourceId) = memo;
    if (book != null) {
      e.book = book;
      e.source = sourceId == null
          ? null
          : (sourceById(sourceId) ??
              _findInPool(pool, sourceId));
    }
    return;
  }

  final keyword = hotSearchKeyword(e.item);
  if (keyword.isEmpty) return;

  for (final s in pool.take(sourcesPerItem)) {
    if (isCancelled?.call() ?? false) return;
    // 聚合搜索型源（owllook）：书名即定位，直接构造条目，零网络请求。
    // 权威榜 30 本 × 1 次搜索 = 30 个 100~250KB 页面，是切榜卡顿的主因。
    if (s.resolvesByTitle) {
      final direct = s.bookFromTitle(keyword, author: e.item.author);
      if (direct != null) {
        e.book = direct;
        e.source = s;
        HotMatchCache.put(memKey, direct, s.id);
        return;
      }
      continue;
    }
    List<Book> found;
    try {
      found = await FeedCache.reach<List<Book>>(
        FeedCache.key(['search', s.id, keyword]),
        () => s.search(keyword),
        skipEmpty: true, // 源抽风返回空不写缓存，下次还能再试
      );
    } catch (_) {
      continue; // 这个源搜不动就换下一个
    }
    final best = pickHotMatch(e.item, found);
    if (best != null) {
      e.book = best;
      e.source = s;
      HotMatchCache.put(memKey, best, s.id);
      return;
    }
  }
  // 记下「搜过但没有」：同一本书不用在每次切榜单时再跑一遍
  HotMatchCache.put(memKey, null, null);
}

/// 在一批搜索结果里挑最像的一本（低于门槛返回 null）。
Book? pickHotMatch(HotItem item, List<Book> candidates) {
  Book? best;
  var bestScore = 0.0;
  for (final b in candidates) {
    final s = hotMatchScore(item, b);
    if (s > bestScore) {
      bestScore = s;
      best = b;
    }
  }
  return bestScore >= kHotMatchThreshold ? best : null;
}

NovelSource? _findInPool(List<NovelSource> pool, String id) {
  for (final s in pool) {
    if (s.id == id) return s;
  }
  return null;
}
