// 首页：全源实时聚合推荐（横幅 / 分类快捷 / 热榜速览 / 今日推荐）。
//
// 与旧「发现页」的区别：内容来自全部可用源（内置 + 已启用导入源）
// 实时聚合，先到先上屏（不等最慢的源）；下拉刷新整批作废重拉。
// 宽屏（Windows）为主区 + 右栏三栏布局，窄屏为单列。
import 'dart:async';
import 'dart:math';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../collect/aggregate.dart';
import '../feed_cache.dart';
import '../legado/source_store.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../theme.dart';
import '../ui/brand.dart';
import '../ui/source/source_manager_page.dart';
import 'book_detail_screen.dart';
import 'local_import_page.dart';
import 'rank_screen.dart';
import 'reader_screen.dart';
import 'search_screen.dart';

/// 首页参与聚合的来源：全部可用源，按用户「推荐来源」勾选过滤。
List<NovelSource> _homeSources() =>
    collectSources().where((s) => AppStore.I.recommendOn(s.id)).toList();

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with AutomaticKeepAliveClientMixin {
  final _rng = Random();
  final Map<String, List<Book>> _bySource = {};
  List<Book> _rec = [];
  List<AggRankEntry> _hot = [];

  /// 推荐流来源筛选（null = 全部）——交互对齐搜索页的来源药丸。
  String? _filter;
  int _done = 0;
  int _total = 0;
  int _gen = 0;
  int _batch = 0;
  bool _loading = true;
  String? _emptyMsg;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    // 勾选推荐来源是「首页自己」的事：只听这一个信号，
    // 书架进度之类的无关通知不触发重新拉网。
    AppStore.I.recommendChanged.addListener(_onRecommendChanged);
    // 书源仓库变化（导入 / 启用 / 删除）也要刷新：
    // 搜索栏的「N 源聚合」和推荐流都以它为口径，否则导入完
    // 书源首页数字纹丝不动，像没导进去。
    SourceStore.shared?.addListener(_onSourcesChanged);
    _load();
  }

  @override
  void dispose() {
    AppStore.I.recommendChanged.removeListener(_onRecommendChanged);
    SourceStore.shared?.removeListener(_onSourcesChanged);
    super.dispose();
  }

  void _onSourcesChanged() {
    if (mounted) _load();
  }

  void _onRecommendChanged() {
    if (mounted) _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    final sources = _homeSources();
    setState(() {
      _loading = true;
      _emptyMsg = null;
      _rec = [];
      _hot = [];
      _bySource.clear();
      _done = 0;
      _total = sources.length;
    });
    if (sources.isEmpty) {
      setState(() {
        _loading = false;
        _emptyMsg = '还没勾选推荐来源\n去「我的 → 书源管理」里挑几个书源即可';
      });
      return;
    }

    // ---- 推荐流：并发上限内拉取，每个源一回来就上屏 ----
    final recTask = runPooled([
      for (final s in sources)
        () async {
          List<Book> books = const [];
          try {
            books = await FeedCache.reach(
                FeedCache.key(['home', s.id]), s.fetchHome);
          } catch (_) {
            books = const []; // 单源失败只少几本，不影响整体
          }
          if (!mounted || gen != _gen) return;
          setState(() {
            _done++;
            // 随机子集 + 交错：每次刷新各源贡献的条数和书目都不同
            _bySource[s.id] = sampleBooks(books, _rng);
            _rec = interleaveBooks(_bySource.values.toList());
            if (_rec.isNotEmpty) _loading = false;
          });
        },
    ]);

    // ---- 热榜速览：与推荐并行，失败不影响推荐；有源返回即填充 ----
    final hotTask = aggregateRank(
      RankBoard.hot,
      '全部',
      onPartial: (partial) {
        if (!mounted || gen != _gen || partial.isEmpty) return;
        setState(() => _hot = partial.take(9).toList());
      },
    ).then((list) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _hot = list.take(9).toList();
        _loading = false;
      });
    }).catchError((_) {});

    await Future.wait([recTask, hotTask]);
    if (mounted && gen == _gen) setState(() => _loading = false);
  }

  Future<void> _reload() async {
    for (final s in collectSources()) {
      FeedCache.invalidate(['home', s.id]);
    }
    FeedCache.invalidatePrefix('rank');
    if (mounted) {
      setState(() {
        _loading = true;
        _batch = 0;
      });
    }
    await _load();
    PetStore.I.emit(PetAction.discoverOpen);
  }

  void _openBook(Book b) {
    PetStore.I.emit(PetAction.discoverOpen);
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BookDetailScreen(book: b)));
  }

  void _startReading(Book b) {
    PetStore.I.emit(PetAction.openBook);
    final e = AppStore.I.shelfEntry(b.url);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        book: b,
        chapterIndex: e?.chapterIndex ?? 0,
        page: e?.page ?? 0,
        paragraph: e?.paragraph ?? 0,
      ),
    ));
  }

  void _addShelf(Book b) {
    if (AppStore.I.inShelf(b.url)) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('已在书架里了')));
      return;
    }
    AppStore.I.addToShelf(b);
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('已把《${b.title}》加入书架')));
  }

  void _toggleTheme() {
    AppStore.I.setTheme(AppStore.I.prefs.theme == AppThemes.black
        ? AppThemes.white
        : AppThemes.black);
  }

  void _openMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('导入本地书'),
              subtitle: const Text('TXT / EPUB'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const LocalImportPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.layers_outlined),
              title: const Text('书源管理'),
              subtitle: Text('${builtinSources.length} 内置 · '
                  '${SourceStore.shared?.sources.length ?? 0} 导入'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const SourceManagerPage()));
              },
            ),
          ],
        ),
      ),
    );
  }

  /// 横幅书目：热榜有货用热榜（章首即「今日热榜 TOP N」），否则用推荐流。
  List<Book> get _bannerBooks {
    final rec = _filteredRec;
    return _hot.isNotEmpty
        ? _hot.take(5).map((e) => e.book).toList()
        : rec.take(5).toList();
  }

  /// 推荐流按选中源过滤（null = 全部）。
  List<Book> get _filteredRec =>
      _filter == null ? _rec : (_bySource[_filter] ?? const []);

  /// 来源筛选药丸行（与搜索页同款交互）。
  Widget _sourceChipsRow(ThemeData theme) {
    final sources = _homeSources();
    if (sources.length <= 1) return const SizedBox.shrink();
    final chips = <Widget>[
      PillChip('全部来源',
          selected: _filter == null,
          onTap: () => setState(() => _filter = null)),
      for (final s in sources)
        PillChip(
          '${s.name}${_bySource.containsKey(s.id) ? ' ✓' : ''}',
          selected: _filter == s.id,
          onTap: () =>
              setState(() => _filter = _filter == s.id ? null : s.id),
        ),
    ];
    Widget row(List<Widget> items) => Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final c in items)
              Padding(padding: const EdgeInsets.only(right: 8), child: c),
          ],
        );
    final half = (chips.length + 1) ~/ 2;
    return SizedBox(
      height: 80,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 7, 16, 9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            row(chips.sublist(0, half.clamp(0, chips.length))),
            row(chips.sublist(half.clamp(0, chips.length))),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
    return narrow ? _mobile() : _desktop();
  }

  // ---------------------------------------------------------------- 窄屏

  Widget _mobile() {
    final theme = Theme.of(context);
    return Column(
      children: [
        _brandRow(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: _SearchField(onTap: _openSearch),
        ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.only(bottom: 24),
              children: [
                _progressRow(theme),
                if (_rec.isEmpty && _hot.isEmpty && _loading)
                  const Padding(
                    padding: EdgeInsets.all(48),
                    child: Center(child: CircularProgressIndicator()),
                  )
                else if (_rec.isEmpty && _hot.isEmpty)
                  _emptyState(theme),
                if (_bannerBooks.isNotEmpty)
                  _HeroBanner(
                    books: _bannerBooks,
                    fromHot: _hot.isNotEmpty,
                    onTap: _openBook,
                  ),
                _categoryChips(),
                if (_hot.isNotEmpty) ...[
                  SectionHead('热榜速览',
                      action: '全源聚合 · 更多 ›',
                      onAction: () => Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const RankScreen()))),
                  for (var i = 0; i < _hot.take(3).length; i++)
                    _hotRow(_hot[i], i + 1, theme),
                ],
                if (_filteredRec.isNotEmpty) ...[
                  _sourceChipsRow(theme),
                  SectionHead('今日推荐',
                      action: '换一批',
                      actionIcon: const Icon(Icons.refresh,
                          size: 13, color: Brand.green),
                      onAction: () => setState(() => _batch++)),
                  _recGrid(theme, narrow: true),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------- 宽屏

  Widget _desktop() {
    final theme = Theme.of(context);
    return Column(
      children: [
        // dtop：全局搜索 + 快捷动作
        SizedBox(
          height: 58,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 22),
            child: Row(
              children: [
                SizedBox(width: 440, child: _SearchField(onTap: _openSearch)),
                const Spacer(),
                IconButton(
                  icon: Icon(Icons.dark_mode_outlined, color: theme.hintColor),
                  tooltip: AppStore.I.prefs.theme == AppThemes.black
                      ? '切到锦绣白'
                      : '切到极光黑',
                  onPressed: _toggleTheme,
                ),
                IconButton(
                  icon: Icon(Icons.download_outlined, color: theme.hintColor),
                  tooltip: '导入本地书',
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => const LocalImportPage())),
                ),
                IconButton(
                  icon: Icon(Icons.more_horiz, color: theme.hintColor),
                  tooltip: '更多',
                  onPressed: _openMoreSheet,
                ),
              ],
            ),
          ),
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: _desktopMain(theme)),
              SizedBox(width: 300, child: _desktopSide(theme)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _desktopMain(ThemeData theme) {
    return RefreshIndicator(
      onRefresh: _reload,
      child: ScrollConfiguration(
        // 桌面默认鼠标不能拖滚动 → 下拉刷新够不着；这里打开鼠标拖拽。
        behavior: ScrollConfiguration.of(context)
            .copyWith(dragDevices: PointerDeviceKind.values.toSet()),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(22, 0, 22, 24),
          children: [
            _progressRow(theme),
            if (_rec.isEmpty && _hot.isEmpty && _loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_rec.isEmpty && _hot.isEmpty)
              _emptyState(theme),
            if (_bannerBooks.isNotEmpty)
              _HeroBanner(
                books: _bannerBooks,
                fromHot: _hot.isNotEmpty,
                onTap: _openBook,
                desktop: true,
                onRead: _startReading,
                onShelf: _addShelf,
              ),
            const SizedBox(height: 18),
            if (_hot.isNotEmpty) _hotCard(theme),
            const SizedBox(height: 18),
            if (_filteredRec.isNotEmpty) ...[
              _sourceChipsRow(theme),
              SectionHead('今日推荐',
                  padding: const EdgeInsets.fromLTRB(0, 0, 0, 10),
                  action: '换一批',
                  actionIcon:
                      const Icon(Icons.refresh, size: 13, color: Brand.green),
                  onAction: () => setState(() => _batch++)),
              _recGrid(theme, narrow: false),
            ],
          ],
        ),
      ),
    );
  }

  Widget _desktopSide(ThemeData theme) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(0, 0, 22, 24),
      children: [
        _continueCard(theme),
        const SizedBox(height: 14),
        if (_hot.isNotEmpty) _rankSideCard(theme),
        const SizedBox(height: 14),
        _petCard(theme),
      ],
    );
  }

  // ---------------------------------------------------------------- 公共块

  /// 品牌行（安卓）：小墨 + 爽阅 + 主题 / 更多。
  Widget _brandRow() {
    final theme = Theme.of(context);
    return SizedBox(
      height: 46,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            const Mascot(size: 27),
            const SizedBox(width: 8),
            Text('爽阅',
                style: theme.textTheme.titleLarge?.copyWith(
                    fontSize: 21,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.02)),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.dark_mode_outlined,
                  size: 20, color: theme.hintColor),
              tooltip: AppStore.I.prefs.theme == AppThemes.black
                  ? '切到锦绣白'
                  : '切到极光黑',
              onPressed: _toggleTheme,
            ),
            IconButton(
              icon: Icon(Icons.more_horiz, size: 20, color: theme.hintColor),
              tooltip: '更多',
              onPressed: _openMoreSheet,
            ),
          ],
        ),
      ),
    );
  }

  void _openSearch() => Navigator.of(context)
      .push(MaterialPageRoute(builder: (_) => const SearchScreen()));

  Widget _progressRow(ThemeData theme) {
    if (!_loading || _total == 0 || _done >= _total) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 2),
      child: Row(
        children: [
          const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          Text('正在汇总 $_total 个书源…已完成 $_done',
              style: theme.textTheme.bodySmall),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        children: [
          const Mascot(size: 56),
          const SizedBox(height: 14),
          Text(_emptyMsg ?? '暂时没有拿到推荐',
              textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 10),
          BrandBtn('重新加载',
              style: BrandBtnStyle.outline, onTap: () => _load()),
        ],
      ),
    );
  }

  /// 分类快捷：点击跳「排行」对应分类。
  Widget _categoryChips() {
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 13),
        children: [
          for (final c in kRankCategories.skip(1).take(6))
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChip(c,
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(
                      builder: (_) => RankScreen(initialCategory: c)))),
            ),
        ],
      ),
    );
  }

  Widget _hotRow(AggRankEntry e, int rank, ThemeData theme) {
    final b = e.book;
    final meta = [
      if (b.author?.isNotEmpty ?? false) b.author!,
      if (b.status?.isNotEmpty ?? false) b.status!,
    ].join(' · ');
    return GestureDetector(
      onTap: () => _openBook(b),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            RankNum(rank),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 14.5, fontWeight: FontWeight.w700)),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(fontSize: 11.5, color: Brand.fg3(context))),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (e.sourceCount > 1)
              SrcPill('${e.sourceCount} 个来源', accent: true)
            else
              SrcPill(e.book.sourceId.isEmpty
                  ? ''
                  : sourceNameOf(e.book.sourceId)),
          ],
        ),
      ),
    );
  }

  Widget _recGrid(ThemeData theme, {required bool narrow}) {
    final rec = _filteredRec;
    // 推荐池去掉已在横幅露脸的书，不足 6 本就不再剔除（宁可爱重复也要有内容）
    final pool = rec.length > 6
        ? rec.where((b) => !_bannerBooks.any((x) => x.url == b.url)).toList()
        : rec;
    final src = pool.length >= 6 ? pool : rec;
    if (src.isEmpty) return const SizedBox.shrink();
    final start = (_batch * 6) % src.length;
    final items = [for (var i = 0; i < 6 && i < src.length; i++) src[(start + i) % src.length]];
    return Padding(
      padding: narrow
          ? const EdgeInsets.symmetric(horizontal: 16)
          : EdgeInsets.zero,
      child: GridView.count(
        crossAxisCount: narrow ? 3 : 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 14,
        crossAxisSpacing: 12,
        childAspectRatio: 0.5,
        children: [
          for (final b in items)
            _RecCard(book: b, onTap: () => _openBook(b)),
        ],
      ),
    );
  }

  Widget _hotCard(ThemeData theme) {
    final list = _hot.take(6).toList();
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
      decoration: BoxDecoration(
        color: Brand.card(context),
        border: Border.all(color: Brand.hair(context)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('热榜速览',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const RankScreen())),
                child: Text('全源聚合 · 更多 ›',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: 11, color: Brand.fg3(context))),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // 两列三行
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (var col = 0; col < 2; col++)
                Expanded(
                  child: Column(
                    children: [
                      for (var i = col * 3;
                          i < (col + 1) * 3 && i < list.length;
                          i++)
                        _sideHotRow(list[i], i + 1, theme),
                    ],
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sideHotRow(AggRankEntry e, int rank, ThemeData theme) {
    return GestureDetector(
      onTap: () => _openBook(e.book),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            RankNum(rank, size: 14),
            const SizedBox(width: 6),
            Expanded(
              child: Text(e.book.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                      fontSize: 13,
                      color: theme.colorScheme.onSurface,
                      fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 6),
            if (e.sourceCount > 1)
              SrcPill('${e.sourceCount} 源', accent: true)
            else
              SrcPill(sourceNameOf(e.book.sourceId)),
          ],
        ),
      ),
    );
  }

  /// 继续阅读（历史第一本，退而求其次书架第一本）。
  Widget _continueCard(ThemeData theme) {
    final e = AppStore.I.history.isNotEmpty
        ? AppStore.I.history.first
        : (AppStore.I.shelf.isNotEmpty ? AppStore.I.shelf.first : null);
    final card = Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
        color: Brand.card(context),
        border: Border.all(color: Brand.hair(context)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: e == null
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('继续阅读',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 10),
                Text('还没有阅读记录\n去首页挑一本开始吧',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: Brand.fg3(context))),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('继续阅读',
                    style: theme.textTheme.titleSmall
                        ?.copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
                const SizedBox(height: 12),
                Row(
                  children: [
                    BookCover(e.book, width: 46, height: 64, radius: 8),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(e.book.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyMedium?.copyWith(
                                  fontSize: 13.5, fontWeight: FontWeight.w700)),
                          const SizedBox(height: 3),
                          Text(
                              '第 ${e.chapterIndex + 1} 章'
                              '${e.chapterTitle.isEmpty ? '' : ' · ${e.chapterTitle}'}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 11, color: Brand.fg3(context))),
                          const SizedBox(height: 8),
                          ProgBar(_progressOf(e)),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 13),
                BrandBtn('继续阅读',
                    height: 34,
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ReaderScreen(
                            book: e.book,
                            chapterIndex: e.chapterIndex,
                            page: e.page,
                            paragraph: e.paragraph)))),
              ],
            ),
    );
    return card;
  }

  Widget _rankSideCard(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(15, 14, 15, 8),
      decoration: BoxDecoration(
        color: Brand.card(context),
        border: Border.all(color: Brand.hair(context)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('榜单速览',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontSize: 14, fontWeight: FontWeight.w800)),
              const Spacer(),
              GestureDetector(
                onTap: () => Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RankScreen())),
                child: Text('去排行 ›',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: 11, color: Brand.fg3(context))),
              ),
            ],
          ),
          for (var i = 0; i < _hot.take(5).length; i++)
            _sideHotRow(_hot[i], i + 1, theme),
        ],
      ),
    );
  }

  /// 小墨卡片。
  Widget _petCard(ThemeData theme) {
    final pet = PetStore.I;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: theme.brightness == Brightness.dark
              ? const [Color(0xFF1B2A22), Color(0xFF16211C)]
              : const [Color(0xFFE7F1E2), Color(0xFFF4F9F0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(
            color: theme.brightness == Brightness.dark
                ? const Color(0xFF2A3C31)
                : const Color(0xFFD8E6D2)),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const Mascot(size: 46),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
                  decoration: BoxDecoration(
                    color: Brand.card(context),
                    border: Border.all(color: Brand.hair(context)),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    pet.bubble ?? '小墨陪着你，一起翻两页？',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(fontSize: 12, height: 1.5),
                  ),
                ),
                const SizedBox(height: 6),
                Text('小墨 · ${pet.stage.label} · 陪伴 ${pet.companionDays} 天',
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: 10.5, color: Brand.fg3(context))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 书架进度：章节位置占总章数的比例（无章数时按 0 处理）。
double _progressOf(ShelfEntry e) {
  if (e.chapterCount <= 0) return 0;
  return ((e.chapterIndex + 1) / e.chapterCount).clamp(0.0, 1.0);
}

// ---------------------------------------------------------------- 搜索框

class _SearchField extends StatelessWidget {
  const _SearchField({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: 15),
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
              child: Text('搜书名 / 作者 / 内容',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(fontSize: 13, color: Brand.fg3(context))),
            ),
            SrcPill('${collectSources().length} 源聚合'),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------- 横幅

/// 自动轮播横幅（5 秒一页；热榜书目带「今日热榜 TOP N」徽记）。
class _HeroBanner extends StatefulWidget {
  const _HeroBanner({
    required this.books,
    required this.fromHot,
    required this.onTap,
    this.desktop = false,
    this.onRead,
    this.onShelf,
  });

  final List<Book> books;
  final bool fromHot;
  final void Function(Book) onTap;
  final bool desktop;
  final void Function(Book)? onRead;
  final void Function(Book)? onShelf;

  @override
  State<_HeroBanner> createState() => _HeroBannerState();
}

class _HeroBannerState extends State<_HeroBanner> {
  final _ctrl = PageController();
  Timer? _timer;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
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
    final desktop = widget.desktop;
    return SizedBox(
      height: desktop ? 150 : 130,
      child: PageView.builder(
        controller: _ctrl,
        itemCount: widget.books.length,
        onPageChanged: (i) => setState(() => _index = i),
        itemBuilder: (context, i) {
          final b = widget.books[i];
          final srcName = sourceNameOf(b.sourceId);
          final meta = [
            if (b.author?.isNotEmpty ?? false) b.author!,
            if (b.status?.isNotEmpty ?? false) b.status!,
            srcName,
          ].join(' · ');
          final intro = (b.intro ?? '')
              .replaceAll(RegExp(r'\s+'), ' ')
              .trim();
          return GestureDetector(
            onTap: () => widget.onTap(b),
            child: Container(
              margin: EdgeInsets.symmetric(horizontal: desktop ? 0 : 16),
              padding: EdgeInsets.all(desktop ? 18 : 14),
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  stops: [0, 0.55, 1],
                  colors: [
                    Color(0xFF14352A),
                    Color(0xFF204B36),
                    Color(0xFF2E6B44),
                  ],
                ),
                borderRadius: BorderRadius.circular(desktop ? 18 : 16),
              ),
              child: Stack(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      BookCover(b, width: desktop ? 76 : 62, height: desktop ? 104 : 86),
                      SizedBox(width: desktop ? 18 : 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 9, vertical: 2),
                              decoration: BoxDecoration(
                                color: Brand.gold.withValues(alpha: 0.14),
                                border: Border.all(
                                    color:
                                        Brand.gold.withValues(alpha: 0.4)),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                  widget.fromHot
                                      ? '今日热榜 TOP${i + 1}'
                                      : '多源推荐',
                                  style: const TextStyle(
                                      fontSize: 10,
                                      color: Brand.gold,
                                      fontWeight: FontWeight.w600)),
                            ),
                            SizedBox(height: desktop ? 9 : 7),
                            Text(b.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                    fontSize: desktop ? 23 : 19,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.04,
                                    color: Colors.white)),
                            if (meta.isNotEmpty) ...[
                              const SizedBox(height: 4),
                              Text(meta,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: desktop ? 12 : 11.5,
                                      color:
                                          Colors.white.withValues(alpha: 0.72))),
                            ],
                            if (intro.isNotEmpty) ...[
                              SizedBox(height: desktop ? 9 : 8),
                              Text(intro,
                                  maxLines: desktop ? 2 : 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      fontSize: desktop ? 12 : 11.5,
                                      height: 1.5,
                                      color: Colors.white
                                          .withValues(alpha: 0.88))),
                            ],
                          ],
                        ),
                      ),
                      if (desktop && widget.onRead != null) ...[
                        const SizedBox(width: 18),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            BrandBtn(
                              '立即阅读',
                              onTap: () => widget.onRead!(b),
                              height: 36,
                            ),
                          ],
                        ),
                        const SizedBox(width: 10),
                        Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            GestureDetector(
                              onTap: () => widget.onShelf?.call(b),
                              child: Container(
                                height: 36,
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16),
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  border: Border.all(
                                      color: Colors.white
                                          .withValues(alpha: 0.5)),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text('加入书架',
                                    style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w600,
                                        color: Colors.white)),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                  if (desktop)
                    const Positioned(
                      right: -16,
                      bottom: -26,
                      child: Opacity(
                        opacity: 0.24,
                        child: Mascot(size: 128),
                      ),
                    ),
                  Positioned(
                    right: desktop ? 110 : 4,
                    bottom: 0,
                    child: Row(
                      children: [
                        for (var d = 0; d < widget.books.length; d++)
                          Container(
                            width: d == _index ? 14 : 5,
                            height: 3.5,
                            margin: const EdgeInsets.only(left: 4),
                            decoration: BoxDecoration(
                              color: d == _index
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.38),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 推荐卡（封面 + 书名 + 作者 · 来源）。
class _RecCard extends StatelessWidget {
  const _RecCard({required this.book, required this.onTap});

  final Book book;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sub = [
      if (book.author?.isNotEmpty ?? false) book.author!,
      if (book.sourceId.isNotEmpty) sourceNameOf(book.sourceId),
    ].join(' · ');
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: BookCover(book, width: double.infinity)),
          const SizedBox(height: 6),
          Text(book.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface,
                  fontWeight: FontWeight.w600)),
          if (sub.isNotEmpty) ...[
            const SizedBox(height: 1),
            Text(sub,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 10.5, color: Brand.fg3(context))),
          ],
        ],
      ),
    );
  }
}
