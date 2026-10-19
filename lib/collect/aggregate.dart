// 跨书源聚合层：同名书去重合并 / 排行榜多维聚合 / 首页交错推荐。
//
// 排行口径（与设计方案 §4.3 一致）：
//  - 热销 / 新书 / 完结：按源内名次加权（越靠前分越高），同名书跨源累加；
//  - 口碑：多源共同收录数优先（收录它的源越多越靠前），并列再比名次分。
// 榜单分类不从书名猜 —— 只认书源自己的榜单标签（不造假字段）。
library;

import 'dart:math';

import '../feed_cache.dart';
import '../models.dart';
import '../sources/local_source.dart';
import '../sources/registry.dart';
import '../sources/source.dart';

/// 书名 + 作者规范化（去空白与常见标点），跨源同名书合并键。
/// 书名/作者的归一化正则（P2：原来每次调用都 new 一个 RegExp）。
final RegExp _kBookKeyNoise = RegExp(
    r'''[\s·・,，。！!？?、:：;；"'“”‘’《》<>【】\[\]()（）\-—_…~～]''');

String bookKeyOf(Book b) {
  String norm(String s) => s.toLowerCase().replaceAll(_kBookKeyNoise, '');
  return '${norm(b.title)}|${norm(b.author ?? '')}';
}

/// 合并后的一条书：同一个 [bookKeyOf] 的全部来源条目。
class MergedBook {
  MergedBook(this.book);

  /// 展示用主条目（首个到达的源）。
  final Book book;

  /// 全部来源条目（首个在前）。
  final List<(NovelSource, Book)> entries = [];

  int get sourceCount => entries.length;

  /// 主来源名（榜单行右缘 / 搜索行来源药丸）。
  NovelSource get primary => entries.first.$1;
}

/// 把 (源, 书) 序列按 [bookKeyOf] 合并，保持首见顺序。
List<MergedBook> mergeBooks(Iterable<(NovelSource, Book)> items) {
  final map = <String, MergedBook>{};
  final order = <String>[];
  for (final (s, b) in items) {
    final k = bookKeyOf(b);
    final m = map[k];
    if (m == null) {
      map[k] = MergedBook(b)..entries.add((s, b));
      order.add(k);
    } else {
      m.entries.add((s, b));
    }
  }
  return [for (final k in order) map[k]!];
}

/// 参与聚合的书源（本地书源没有线上榜单 / 搜索，排除）。
List<NovelSource> collectSources() =>
    [for (final s in allSources) if (s.id != LocalSource.sourceId) s];

// ---------------------------------------------------------------- 排行聚合

/// 榜单口径。
enum RankBoard {
  hot('热销榜'),
  fresh('新书榜'),
  done('完结榜'),
  praise('口碑榜');

  const RankBoard(this.label);
  final String label;

  List<String> get keywords => switch (this) {
        RankBoard.hot => const ['热销', '畅销', '热门', '人气', '点击'],
        RankBoard.fresh => const ['新书', '最新', '新品'],
        RankBoard.done => const ['完结', '完本', '全本'],
        RankBoard.praise => const ['口碑', '好评', '评分', '收藏'],
      };
}

/// 排行分类（「全部」+ 9 个分类）。
const List<String> kRankCategories = [
  '全部',
  '玄幻',
  '都市',
  '仙侠',
  '历史',
  '科幻',
  '悬疑',
  '言情',
  '游戏',
  '竞技',
];

/// 聚合后的一条榜单书。
class AggRankEntry {
  AggRankEntry(this.book);

  final Book book;

  /// sourceId → 该源内最好名次（0 起）。
  final Map<String, int> _ranks = {};
  int _score = 0;

  int get sourceCount => _ranks.length;
  int get score => _score;

  void add(String sourceId, int index) {
    final prev = _ranks[sourceId];
    if (prev != null && prev <= index) return;
    if (prev != null) _score -= _weight(prev);
    _ranks[sourceId] = index;
    _score += _weight(index);
  }

  static int _weight(int index) => (30 - index * 2).clamp(1, 30);
}

/// 有并发上限的工作池。一次把几十个源同时拉网，手机端网络 + UI 线程
/// 会被「响应到达即同步解析」的尖峰打满（切换页面就卡的主因），
/// 因此每个源完成后再补下一个，把尖峰摊平。
Future<void> runPooled(List<Future<void> Function()> jobs,
    {int maxParallel = 6}) async {
  var next = 0;
  Future<void> worker() async {
    while (true) {
      final i = next++; // 事件循环单线程：读改写之间无 await，不会重入
      if (i >= jobs.length) return;
      await jobs[i]();
    }
  }

  final n = maxParallel < jobs.length ? maxParallel : jobs.length;
  await Future.wait([for (var i = 0; i < n; i++) worker()]);
}

/// 聚合指定榜单 × 分类；[onProgress] 每有一个源返回调用一次（done, total），
/// [onPartial] 每次拿到「当前已合并」的部分榜单 —— 先到先上屏，不等最慢的源。
Future<List<AggRankEntry>> aggregateRank(
  RankBoard board,
  String category, {
  void Function(int done, int total)? onProgress,
  void Function(List<AggRankEntry> partial)? onPartial,
  int maxParallel = 6,
}) async {
  final sources = collectSources();
  final total = sources.length;
  var done = 0;
  final map = <String, AggRankEntry>{};
  final order = <String>[];

  void mergeAll(List<(NovelSource, int, Book)> list) {
    for (final (s, i, b) in list) {
      final k = bookKeyOf(b);
      var e = map[k];
      if (e == null) {
        e = AggRankEntry(b);
        map[k] = e;
        order.add(k);
      }
      e.add(s.id, i);
    }
  }

  List<AggRankEntry> snapshot() {
    final entries = [for (final k in order) map[k]!];
    if (board == RankBoard.praise) {
      entries.sort((a, b) {
        final c = b.sourceCount.compareTo(a.sourceCount);
        return c != 0 ? c : b.score.compareTo(a.score);
      });
    } else {
      entries.sort((a, b) => b.score.compareTo(a.score));
    }
    return entries;
  }

  await runPooled([
    for (final s in sources)
      () async {
        final out = <(NovelSource, int, Book)>[];
        try {
          final tabs = await FeedCache.reach(
              FeedCache.key(['rankTabs', s.id]), s.fetchRankTabs);
          final pick = _pickTab(tabs, board, category);
          if (pick != null) {
            final p = await FeedCache.reach(
                FeedCache.key(['rank', s.id, pick.url]),
                () => s.fetchRank(pick));
            for (var i = 0; i < p.items.length; i++) {
              out.add((s, i, p.items[i]));
            }
          }
        } catch (_) {
          // 单源失败不拖垮整榜
        }
        done++;
        mergeAll(out);
        onProgress?.call(done, total);
        onPartial?.call(snapshot());
      },
  ], maxParallel: maxParallel);

  return snapshot();
}

RankTab? _pickTab(List<RankTab> tabs, RankBoard board, String category) {
  RankTab? best;
  var bestScore = 0;
  for (final t in tabs) {
    final sc = _tabScore(t.title, board, category);
    if (sc > bestScore) {
      bestScore = sc;
      best = t;
    }
  }
  if (best == null && board == RankBoard.praise && category == '全部') {
    // 口碑榜不是所有源都有：没有时退回该源首个榜单，
    // 收录面照样参与「多源共同收录数」统计。
    return tabs.isEmpty ? null : tabs.first;
  }
  return best;
}

int _tabScore(String title, RankBoard board, String category) {
  var score = 0;
  for (final k in board.keywords) {
    if (title.contains(k)) score += 2;
  }
  if (category != '全部') {
    // 分类必须由榜单标签给出（如「玄幻榜」「玄幻小说排行榜」）
    if (!title.contains(category)) return 0;
    score += 4;
  } else {
    // 「全部」优先不挑分类的通榜，避免单一分类霸屏
    for (var i = 1; i < kRankCategories.length; i++) {
      if (title.contains(kRankCategories[i])) score -= 5;
    }
  }
  return score;
}

// ---------------------------------------------------------------- 首页推荐

/// 各源标题列表轮询交错合并（每个源都露头，避免被单一源刷屏）。
List<Book> interleaveBooks(List<List<Book>> perSource) {
  final out = <Book>[];
  final seen = <String>{};
  final lists = perSource.where((l) => l.isNotEmpty).toList();
  var idx = 0;
  var progress = true;
  while (progress) {
    progress = false;
    for (final l in lists) {
      if (idx < l.length) {
        progress = true;
        if (seen.add(l[idx].url)) out.add(l[idx]);
      }
    }
    idx++;
  }
  return out;
}

/// 每次刷新随机抽一个子集：先洗牌，再取 [ceil(len/2), len] 条。
List<Book> sampleBooks(List<Book> books, Random rng) {
  if (books.length < 3) return books;
  final pool = [...books]..shuffle(rng);
  final minN = (pool.length + 1) ~/ 2;
  return pool.take(minN + rng.nextInt(pool.length - minN + 1)).toList();
}
