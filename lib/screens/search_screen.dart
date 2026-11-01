// 搜索：全屏多源实时聚合。
//
// 进度实时（已从 X/Y 源返回）、结果先到先上屏、同名书自动合并；
// 空态给搜索历史 + 热词（热词只用「已缓存的首页推荐」，绝不为此单独拉网）。
import 'package:flutter/material.dart';

import '../collect/aggregate.dart';
import '../feed_cache.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../theme.dart';
import '../ui/brand.dart';
import 'book_detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key, this.initialQuery});

  /// 非空时进入即自动搜索（书架外跳转用）。
  final String? initialQuery;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();

  /// 增量合并结果：新源返回时只并入新条目，不在 build 里重算整表。
  ///
  /// 旧实现每次 build 都 `mergeBooks(_all)`（去空白 + 大正则归一化 × 全部行），
  /// 源一多就是几百上千次正则 —— 而且每来一个源都要再跑一遍。现在合并只在
  /// 「数据变化」时做一次，build 只读缓存。
  final Map<String, MergedBook> _merged = {};
  final List<MergedBook> _order = [];
  List<MergedBook>? _view; // 当前筛选下的视图缓存
  String? _viewFilter;
  int _stamp = 0; // 数据版本（合并 / 清空时自增）
  int _viewStamp = -1;

  final Set<String> _returned = {};
  String? _filter; // 来源筛选（null = 全部来源）
  String _query = '';
  int _done = 0;
  int _total = 0;
  int _gen = 0;
  bool _searching = false;
  List<String> _hotWords = [];

  @override
  void initState() {
    super.initState();
    final q = widget.initialQuery?.trim();
    if (q != null && q.isNotEmpty) {
      _controller.text = q;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _search(q);
      });
    } else {
      _loadHotWords();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 热词 = 已缓存的首页推荐书名（没有缓存就整块不显示，不空等网络）。
  Future<void> _loadHotWords() async {
    final sources = collectSources();
    final homes = await Future.wait([
      for (final s in sources)
        FeedCache.getAsync<List<Book>>(FeedCache.key(['home', s.id])),
    ]);
    final titles = <String>[];
    outer:
    for (final home in homes) {
      if (home == null) continue;
      for (final b in home.take(4)) {
        final t = b.title;
        if (t.length >= 2 && t.length <= 12) titles.add(t);
        if (titles.length >= 16) break outer;
      }
    }
    final uniq = <String>[];
    for (final t in titles) {
      if (!uniq.contains(t)) uniq.add(t);
    }
    if (mounted && uniq.isNotEmpty) {
      setState(() => _hotWords = uniq.take(9).toList());
    }
  }

  Future<void> _search(String raw) async {
    final q = raw.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    _controller.text = q;
    AppStore.I.pushSearch(q);
    PetStore.I.emit(PetAction.search);
    final targets = collectSources();
    final gen = ++_gen;
    setState(() {
      _query = q;
      _searching = true;
      _resetMerged();
      _returned.clear();
      _filter = null;
      _done = 0;
      _total = targets.length;
    });
    // 分池并发（上限 6）：每个源返回即上屏（慢源不拖住整页），但同时在跑的
    // 源数受控 —— 一次扇出全部源会在结果集中到达时把主 isolate 打满。
    final jobs = <Future<void> Function()>[];
    for (final s in targets) {
      jobs.add(() async {
        List<Book> r = const [];
        try {
          r = await FeedCache.reach(
            FeedCache.key(['search', s.id, q]),
            () => s.search(q),
            skipEmpty: true, // 源抽风返回空 ≠ 没有这本书，别缓存住整个 TTL
          );
        } catch (_) {
          r = const [];
        }
        if (!mounted || gen != _gen) return;
        setState(() {
          _done++;
          _returned.add(s.id);
          if (r.isNotEmpty) _mergeIn(s, r);
        });
      });
    }
    await runPooled(jobs);
    if (!mounted || gen != _gen) return;
    setState(() => _searching = false);
    if (_merged.isNotEmpty) PetStore.I.emit(PetAction.searchOpen);
  }

  void _resetMerged() {
    _merged.clear();
    _order.clear();
    _view = null;
    _viewStamp = -1;
    _stamp++;
  }

  /// 把一个源的结果并入合并表（O(新增条目)）。
  void _mergeIn(NovelSource s, List<Book> books) {
    for (final b in books) {
      final k = bookKeyOf(b);
      final m = _merged[k];
      if (m == null) {
        final e = MergedBook(b)..entries.add((s, b));
        _merged[k] = e;
        _order.add(e);
      } else {
        m.entries.add((s, b));
      }
    }
    _stamp++;
  }

  /// 当前筛选下的行（数据或筛选变了才重算）。
  List<MergedBook> get _visible {
    final cached = _view;
    if (cached != null && _viewFilter == _filter && _viewStamp == _stamp) {
      return cached;
    }
    final f = _filter;
    List<MergedBook> v;
    if (f == null) {
      v = _order;
    } else {
      v = [];
      for (final m in _order) {
        final es = [
          for (final e in m.entries)
            if (e.$1.id == f) e,
        ];
        if (es.isEmpty) continue;
        // 筛选视图只看该源这一条，来源药丸才对得上
        v.add(MergedBook(es.first.$2)..entries.addAll(es));
      }
    }
    _view = v;
    _viewFilter = f;
    _viewStamp = _stamp;
    return v;
  }

  void _clearInput() {
    _controller.clear();
    _gen++; // 作废在途结果
    setState(() {
      _query = '';
      _searching = false;
      _resetMerged();
      _returned.clear();
      _filter = null;
    });
  }

  void _openBook(Book b) {
    PetStore.I.emit(PetAction.searchOpen);
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BookDetailScreen(book: b)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _topBar(theme),
            if (_query.isNotEmpty) _progressCard(theme),
            if (_query.isNotEmpty) _sourceChips(theme),
            Expanded(child: _query.isEmpty ? _idle(theme) : _results(theme)),
          ],
        ),
      ),
    );
  }

  Widget _topBar(ThemeData theme) {
    return SizedBox(
      height: 56,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, size: 21, color: theme.hintColor),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            Expanded(
              child: Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: 13),
                decoration: BoxDecoration(
                  color: Brand.card(context),
                  border: Border.all(color: Brand.hair(context)),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Row(
                  children: [
                    Icon(Icons.search, size: 17, color: Brand.fg3(context)),
                    const SizedBox(width: 9),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        style: theme.textTheme.bodyMedium
                            ?.copyWith(fontSize: 14),
                        decoration: InputDecoration(
                          isDense: true,
                          border: InputBorder.none,
                          hintText: '搜书名 / 作者 / 内容',
                          hintStyle: theme.textTheme.bodySmall?.copyWith(
                              fontSize: 13, color: Brand.fg3(context)),
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 10),
                        ),
                        onChanged: (_) => setState(() {}),
                        onSubmitted: _search,
                      ),
                    ),
                    if (_controller.text.isNotEmpty)
                      GestureDetector(
                        onTap: _clearInput,
                        child: Icon(Icons.cancel,
                            size: 17, color: Brand.fg3(context)),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Text('取消',
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Brand.green)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 进度卡：已从 X/Y 源返回 + 细进度条。
  Widget _progressCard(ThemeData theme) {
    final done = _done.clamp(0, _total);
    final text = _searching
        ? '已从 $done/$_total 个源返回 · 持续上屏中…'
        : '已汇总 $_total 个源 · 同名书已自动合并';
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (_searching) ...[
                const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(text,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11.5, color: Brand.fg3(context))),
              ),
            ],
          ),
          const SizedBox(height: 7),
          ProgBar(_total == 0 ? 0 : done / _total, height: 3),
        ],
      ),
    );
  }

  /// 来源筛选：全部 + 每个源（已返回的打 ✓）。
  ///
  /// 药丸分两行铺开、整体横向滑动 —— 导入的书源一多，
  /// 单行横排根本看不全（69 个源排一行要划半天）。
  Widget _sourceChips(ThemeData theme) {
    final sources = collectSources();
    final chips = <Widget>[
      PillChip('全部来源',
          selected: _filter == null,
          onTap: () => setState(() => _filter = null)),
      for (final s in sources)
        PillChip(
          '${s.name}${_returned.contains(s.id) ? ' ✓' : ''}',
          selected: _filter == s.id,
          onTap: () => setState(() => _filter = _filter == s.id ? null : s.id),
        ),
    ];
    // 按原顺序切两半：第一行是「全部来源 + 前一半」，第二行是后半，
    // 两行共享一个横向滚动条（内置源照旧排在最前，位置不变）。
    final half = (chips.length + 1) ~/ 2;
    Widget row(List<Widget> items) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in items)
              Padding(padding: const EdgeInsets.only(right: 8), child: c),
          ],
        );
    return SizedBox(
      height: 80,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            row(chips.take(half).toList()),
            const SizedBox(height: 6),
            row(chips.skip(half).toList()),
          ],
        ),
      ),
    );
  }

  /// 空态：搜索历史 + 大家都在搜。
  Widget _idle(ThemeData theme) {
    final history = AppStore.I.searchHistory;
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 24),
      children: [
        if (history.isNotEmpty) ...[
          SectionHead('搜索历史',
              padding: const EdgeInsets.fromLTRB(0, 10, 0, 9),
              action: '清空',
              grayAction: true,
              onAction: () {
                AppStore.I.clearSearchHistory();
                PetStore.I.emit(PetAction.searchClear);
                setState(() {});
              }),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final q in history.take(12))
                PillChip(q, onTap: () => _search(q)),
            ],
          ),
          const SizedBox(height: 18),
        ],
        if (_hotWords.isNotEmpty) ...[
          const SectionHead('大家都在搜',
              padding: EdgeInsets.fromLTRB(0, 0, 0, 9)),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final q in _hotWords)
                PillChip(q, onTap: () => _search(q)),
            ],
          ),
        ],
        if (history.isEmpty && _hotWords.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 90),
            child: Column(
              children: [
                const Mascot(size: 60),
                const SizedBox(height: 16),
                Text('输入书名 / 作者 / 内容开始搜索',
                    style: theme.textTheme.bodyMedium),
                const SizedBox(height: 6),
                Text('一次搜索全部可用书源 · 同名书自动合并',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Brand.fg3(context))),
              ],
            ),
          ),
      ],
    );
  }

  Widget _results(ThemeData theme) {
    final merged = _visible;
    if (merged.isEmpty) {
      if (_searching) {
        return const Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        );
      }
      return Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            const Mascot(size: 56),
            const SizedBox(height: 14),
            Text('没有找到「$_query」相关的书\n换个关键词，或到「我的 → 书源管理」导入更多书源',
                textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          ],
        ),
      );
    }
    // 懒构建：源一多时结果可能上千行，一次性建出来会卡住首帧。
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      itemCount: merged.length + 1,
      itemBuilder: (context, i) {
        if (i < merged.length) return _resultRow(merged[i], theme);
        return Padding(
          padding: const EdgeInsets.only(top: 14),
          child: Text('同名书自动合并 · 共 ${merged.length} 本 · 没搜到？试试导入更多书源',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontSize: 11, color: Brand.fg3(context))),
        );
      },
    );
  }

  Widget _resultRow(MergedBook m, ThemeData theme) {
    final b = m.book;
    final meta = [
      if (b.author?.isNotEmpty ?? false) b.author!,
      if (b.status?.isNotEmpty ?? false) b.status!,
    ].join(' · ');
    return GestureDetector(
      onTap: () => _openBook(b),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(b, width: 44, height: 60, radius: 8),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  MarkedTitle(
                    b.title,
                    _query,
                    style: theme.textTheme.bodyMedium?.copyWith(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w700,
                        height: 1.2),
                  ),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5, color: Brand.fg3(context))),
                  ],
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      if (m.sourceCount > 1)
                        SrcPill('${m.sourceCount} 个来源', accent: true)
                      else
                        SrcPill(sourceNameOf(b.sourceId)),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
