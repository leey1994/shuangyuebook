import 'dart:async';

import 'package:flutter/material.dart';

import '../feed_cache.dart';
import '../models.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../widgets.dart';
import 'book_detail_screen.dart';
import 'booklist_screen.dart';

/// 发现：推荐 / 排行榜 / 书单。
/// 三个 tab 均聚合全部书源，不再按书源分类。
class DiscoverScreen extends StatefulWidget {
  const DiscoverScreen({super.key});

  @override
  State<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends State<DiscoverScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 3, vsync: this);

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('发现'),
        bottom: TabBar(
          controller: _tabs,
          tabs: const [Tab(text: '推荐'), Tab(text: '排行'), Tab(text: '书单')],
        ),
      ),
      body: TabBarView(
        controller: _tabs,
        children: const [
          _HomeTab(),
          _RankTab(),
          _BooklistTab(),
        ],
      ),
    );
  }
}

/// 各源标题列表轮询交错合并（每个源都露头，避免被单一源刷屏）。
List<Book> _interleave(List<List<Book>> perSource) {
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

/// 并行取全部书源的首页推荐（带缓存，单源失败返回空）。
Future<List<List<Book>>> _fetchAllHomes() => Future.wait(allSources.map((s) async {
      try {
        return await FeedCache.reach(
            FeedCache.key(['home', s.id]), s.fetchHome);
      } catch (_) {
        return <Book>[];
      }
    }));

/// 并行取全部书源的排行标签。
Future<List<(NovelSource, List<RankTab>)>> _fetchAllRankTabs() =>
    Future.wait(allSources.map((s) async {
      try {
        final t = await FeedCache.reach(
            FeedCache.key(['rankTabs', s.id]), s.fetchRankTabs);
        return (s, t);
      } catch (_) {
        return (s, <RankTab>[]);
      }
    }));

// ---------------------------------------------------------------- 推荐 tab

/// 聚合推荐：自动轮播横幅 + 横向书架 + 排行精选 + 竖向更多。
class _HomeTab extends StatefulWidget {
  const _HomeTab();

  @override
  State<_HomeTab> createState() => _HomeTabState();
}

class _HomeTabState extends State<_HomeTab> with AutomaticKeepAliveClientMixin {
  List<Book> _home = [];
  List<Book> _rank = [];
  bool _loading = true;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final homesF = _fetchAllHomes();
      final tabsF = _fetchAllRankTabs();
      final perSource = await homesF;
      List<Book> rank = [];
      try {
        final tabs = await tabsF;
        final pages = await Future.wait(tabs.where((x) => x.$2.isNotEmpty).map(
            (x) async {
          try {
            final p = await FeedCache.reach(
              FeedCache.key(['rank', x.$1.id, x.$2.first.url]),
              () => x.$1.fetchRank(x.$2.first),
            );
            return p.items;
          } catch (_) {
            return <Book>[];
          }
        }));
        rank = _interleave(pages);
      } catch (_) {
        // 排行榜失败不影响推荐展示
      }
      if (!mounted) return;
      setState(() {
        _home = _interleave(perSource);
        _rank = rank;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  Future<void> _reload() async {
    for (final s in allSources) {
      FeedCache.invalidate(['home', s.id]);
      FeedCache.invalidate(['rankTabs', s.id]);
    }
    setState(() => _loading = true);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_home.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error == null ? '暂无推荐' : '加载失败：$_error'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }

    final banners =
        _home.where((b) => b.cover != null && b.cover!.isNotEmpty).take(6).toList();
    final bannerBooks = banners.isEmpty ? _home.take(6).toList() : banners;
    final row1 = _home.take(36).toList();
    final row2 = _rank.take(36).toList();
    final rest = _home.length > 36 ? _home.sublist(36) : const <Book>[];

    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _reload,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          if (bannerBooks.isNotEmpty) _AutoBanner(books: bannerBooks),
          if (row1.isNotEmpty)
            _Shelf(title: '热门推荐', books: row1, showRank: false),
          if (row2.isNotEmpty)
            _Shelf(title: '排行榜精选', books: row2, showRank: true),
          if (rest.isNotEmpty) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
              child: Text('更多推荐', style: theme.textTheme.titleMedium),
            ),
            for (final b in rest)
              BookTile(
                book: b,
                showSource: true,
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BookDetailScreen(book: b))),
              ),
          ],
        ],
      ),
    );
  }
}

/// 自动轮播横幅（4 秒一页，点击进详情）。
class _AutoBanner extends StatefulWidget {
  final List<Book> books;
  const _AutoBanner({required this.books});

  @override
  State<_AutoBanner> createState() => _AutoBannerState();
}

class _AutoBannerState extends State<_AutoBanner> {
  final _ctrl = PageController(viewportFraction: 0.92);
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!mounted || widget.books.length < 2 || !_ctrl.hasClients) return;
      _index = (_index + 1) % widget.books.length;
      _ctrl.animateToPage(_index,
          duration: const Duration(milliseconds: 400), curve: Curves.easeOut);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 210,
      child: Stack(
        children: [
          PageView.builder(
            controller: _ctrl,
            itemCount: widget.books.length,
            onPageChanged: (i) => setState(() => _index = i),
            itemBuilder: (context, i) {
              final b = widget.books[i];
              final srcName = sourceById(b.sourceId)?.name ?? '';
              return GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => BookDetailScreen(book: b))),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    gradient: const LinearGradient(
                      colors: [Color(0xFF2B3A55), Color(0xFF111827)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (b.cover != null && b.cover!.isNotEmpty)
                        CoverImage(
                          url: b.cover,
                          width: null,
                          height: null,
                          cacheWidth: 900,
                          placeholder: const SizedBox.shrink(),
                        ),
                      Align(
                        alignment: Alignment.bottomLeft,
                        child: Container(
                          width: double.infinity,
                          padding: const EdgeInsets.fromLTRB(14, 24, 14, 12),
                          decoration: const BoxDecoration(
                            gradient: LinearGradient(
                              colors: [Colors.transparent, Color(0xCC000000)],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                b.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.titleMedium?.copyWith(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                [
                                  if (b.author != null && b.author!.isNotEmpty)
                                    b.author!,
                                  if (srcName.isNotEmpty) srcName,
                                ].join(' · '),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodySmall
                                    ?.copyWith(color: Colors.white70),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          ),
          Positioned(
            right: 18,
            bottom: 16,
            child: Row(
              children: [
                for (var i = 0; i < widget.books.length; i++)
                  Container(
                    width: i == _index ? 16 : 6,
                    height: 6,
                    margin: const EdgeInsets.only(left: 4),
                    decoration: BoxDecoration(
                      color: i == _index ? Colors.white : Colors.white38,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 横向书架（封面卡片行）。
class _Shelf extends StatelessWidget {
  final String title;
  final List<Book> books;
  final bool showRank;
  const _Shelf({required this.title, required this.books, this.showRank = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(title, style: theme.textTheme.titleMedium),
        ),
        SizedBox(
          // 两行横向书架：行高 ~225（封面148+文字）×2 + 间距
          height: 476,
          child: HScrollView(
            builder: (context, controller) => GridView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2, // 两行
                mainAxisSpacing: 10,
                crossAxisSpacing: 10,
                mainAxisExtent: 124, // 列宽 = 卡片104 + 呼吸位
              ),
              itemCount: books.length,
              itemBuilder: (context, i) => Center(
                child: _BookCard(
                  book: books[i],
                  rank: showRank ? i + 1 : null,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 封面卡片（聚合来源显示所属书源）。
class _BookCard extends StatelessWidget {
  final Book book;
  final int? rank;
  const _BookCard({required this.book, this.rank});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final srcName = sourceById(book.sourceId)?.name ?? '';
    return SizedBox(
      width: 104,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => BookDetailScreen(book: book))),
            child: Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 104,
                    height: 148,
                    child: book.cover != null && book.cover!.isNotEmpty
                        ? CoverImage(
                            url: book.cover,
                            width: 104,
                            height: 148,
                            cacheWidth: 320,
                            placeholder: const _CoverPlaceholder(),
                          )
                        : const _CoverPlaceholder(),
                  ),
                ),
                if (rank != null)
                  Positioned(
                    left: 0,
                    top: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: const BoxDecoration(
                        color: Color(0xCCB03A2E),
                        borderRadius:
                            BorderRadius.only(topLeft: Radius.circular(8)),
                      ),
                      child: Text(
                        'TOP $rank',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            book.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodyMedium
                ?.copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            [
              if (book.author != null && book.author!.isNotEmpty)
                book.author!,
              if (srcName.isNotEmpty) srcName,
            ].join(' · '),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall
                ?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
    );
  }
}

class _CoverPlaceholder extends StatelessWidget {
  const _CoverPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF2B3A55),
      alignment: Alignment.center,
      child: const Icon(Icons.menu_book, color: Colors.white54, size: 34),
    );
  }
}

// ---------------------------------------------------------------- 分页列表（排行用）

/// 分页列表页（排行 tab 用，带名次徽标）。
class _PagedList extends StatefulWidget {
  final Future<Paged<Book>> Function({String? nextUrl}) fetch;
  final bool ranked;
  const _PagedList({super.key, required this.fetch, this.ranked = false});

  @override
  State<_PagedList> createState() => _PagedListState();
}

class _PagedListState extends State<_PagedList>
    with AutomaticKeepAliveClientMixin {
  List<Book>? _items;
  String? _next;
  Object? _error;
  bool _loading = false;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool more = false}) async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final r = await widget.fetch(nextUrl: more ? _next : null);
      if (!mounted) return;
      setState(() {
        _items = [...?_items, ...r.items];
        _next = r.nextUrl;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_items == null && _error == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null && (_items == null || _items!.isEmpty)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('加载失败：$_error'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final items = _items ?? [];
    return ListView.builder(
      itemCount: items.length + 1,
      itemBuilder: (context, i) {
        if (i == items.length) {
          if (_next == null) {
            return Padding(
              padding: const EdgeInsets.all(16),
              child: Center(
                  child: Text('— 共 ${items.length} 本 —',
                      style: Theme.of(context).textTheme.bodySmall)),
            );
          }
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Center(
              child: _loading
                  ? const CircularProgressIndicator()
                  : OutlinedButton(
                      onPressed: () => _load(more: true),
                      child: const Text('加载更多'),
                    ),
            ),
          );
        }
        final b = items[i];
        return BookTile(
          book: b,
          showSource: true,
          trailingText: widget.ranked ? '${i + 1}' : null,
          onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => BookDetailScreen(book: b))),
        );
      },
    );
  }
}

// ---------------------------------------------------------------- 排行 tab（聚合）

/// 聚合后的排行标签：带上所属书源。
class _AggRankTab {
  final NovelSource source;
  final RankTab tab;
  _AggRankTab(this.source, this.tab);
}

class _RankTab extends StatefulWidget {
  const _RankTab();

  @override
  State<_RankTab> createState() => _RankTabState();
}

class _RankTabState extends State<_RankTab> with AutomaticKeepAliveClientMixin {
  List<_AggRankTab>? _tabs;
  _AggRankTab? _current;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _loadTabs();
  }

  Future<void> _loadTabs() async {
    setState(() {
      _tabs = null;
      _current = null;
    });
    final perSource = await _fetchAllRankTabs();
    final agg = <_AggRankTab>[];
    for (final (src, tabs) in perSource) {
      for (final t in tabs) {
        agg.add(_AggRankTab(src, t));
      }
    }
    if (!mounted) return;
    setState(() {
      _tabs = agg;
      _current = agg.isEmpty ? null : agg.first;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (_tabs == null) return const Center(child: CircularProgressIndicator());
    if (_tabs!.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('排行榜加载失败'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _loadTabs, child: const Text('重试')),
          ],
        ),
      );
    }
    final cur = _current!;
    return Column(
      children: [
        SizedBox(
          // 榜单标签两行横向网格，滚轮/拖拽/滚动条均可右划
          height: 96,
          child: HScrollView(
            builder: (context, controller) => GridView.builder(
              controller: controller,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 6,
                crossAxisSpacing: 6,
                mainAxisExtent: 150,
              ),
              itemCount: _tabs!.length,
              itemBuilder: (context, i) {
                final t = _tabs![i];
                return ChoiceChip(
                  label: Text('${t.source.name}·${t.tab.title}',
                      maxLines: 1, overflow: TextOverflow.ellipsis),
                  selected: identical(t, cur),
                  onSelected: (_) => setState(() => _current = t),
                );
              },
            ),
          ),
        ),
        Expanded(
          child: _PagedList(
            key: ValueKey('${cur.source.id}|${cur.tab.url}'),
            ranked: true,
            fetch: ({nextUrl}) {
              if (nextUrl != null) {
                return cur.source.fetchRank(cur.tab, nextUrl: nextUrl);
              }
              return FeedCache.reach(
                FeedCache.key(['rank', cur.source.id, cur.tab.url]),
                () => cur.source.fetchRank(cur.tab),
              );
            },
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- 书单 tab（聚合）

class _BooklistTab extends StatefulWidget {
  const _BooklistTab();

  @override
  State<_BooklistTab> createState() => _BooklistTabState();
}

class _BooklistTabState extends State<_BooklistTab>
    with AutomaticKeepAliveClientMixin {
  final List<(NovelSource, BooklistEntry)> _items = [];
  final Map<String, String?> _next = {}; // sourceId -> 下一页地址
  bool _loading = false;
  bool _inited = false;
  Object? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// 首屏：并行拉全部书源第一页。
  Future<void> _load() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final results = await Future.wait(allSources.map((s) async {
      try {
        final r = await FeedCache.reach(
            FeedCache.key(['booklists', s.id]), s.fetchBooklists);
        return (s, r, null);
      } catch (e) {
        return (s, null, e);
      }
    }));
    if (!mounted) return;
    setState(() {
      _items.clear();
      Object? firstErr;
      for (final (s, r, e) in results) {
        if (r != null) {
          for (final entry in r.items) {
            _items.add((s, entry));
          }
          _next[s.id] = r.nextUrl;
        } else {
          firstErr ??= e;
        }
      }
      _inited = true;
      _loading = false;
      _error = _items.isEmpty ? firstErr : null;
    });
  }

  /// 加载更多：所有还有下一页的源并行翻页。
  Future<void> _loadMore() async {
    if (_loading) return;
    final pending = allSources
        .where((s) => (_next[s.id] ?? '').isNotEmpty)
        .toList();
    if (pending.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    final results = await Future.wait(pending.map((s) async {
      try {
        final r = await FeedCache.reach(
          FeedCache.key(['booklists', s.id, _next[s.id]]),
          () => s.fetchBooklists(nextUrl: _next[s.id]),
        );
        return (s, r, null);
      } catch (e) {
        return (s, null, e);
      }
    }));
    if (!mounted) return;
    setState(() {
      Object? firstErr;
      for (final (s, r, e) in results) {
        if (r != null) {
          for (final entry in r.items) {
            _items.add((s, entry));
          }
          _next[s.id] = r.nextUrl;
        } else {
          firstErr ??= e;
        }
      }
      _loading = false;
      _error = firstErr;
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (!_inited) return const Center(child: CircularProgressIndicator());
    if (_items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error == null ? '暂无书单' : '加载失败：$_error'),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
          ],
        ),
      );
    }
    final hasMore = allSources.any((s) => (_next[s.id] ?? '').isNotEmpty);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.builder(
        itemCount: _items.length + 1,
        itemBuilder: (context, i) {
          if (i == _items.length) {
            if (!hasMore) return const SizedBox(height: 24);
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: _loading
                    ? const CircularProgressIndicator()
                    : OutlinedButton(
                        onPressed: _loadMore,
                        child: const Text('加载更多'),
                      ),
              ),
            );
          }
          final (s, e) = _items[i];
          // 卡片化：卡片边界 + 间距区分不同书单
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            child: Card(
              margin: EdgeInsets.zero,
              clipBehavior: Clip.antiAlias,
              child: ListTile(
                title: Text(e.title,
                    maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          TagPill(s.name),
                          if (e.date != null && e.date!.isNotEmpty)
                            TagPill(e.date!, dim: true),
                        ],
                      ),
                      if (e.intro != null && e.intro!.isNotEmpty) ...[
                        const SizedBox(height: 6),
                        Text(e.intro!,
                            maxLines: 2, overflow: TextOverflow.ellipsis),
                      ],
                    ],
                  ),
                ),
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => BooklistScreen(entry: e, source: s),
                )),
              ),
            ),
          );
        },
      ),
    );
  }
}
