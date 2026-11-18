// 排行：权威热读榜 + 书源站内榜。
//
// 页面分两组：
//   ① 权威榜（起点榜 / 番茄榜 / Owllook榜）：读 owllook 汇总的榜单整页 / 番茄官方榜，
//      再把书名拿回用户自己的可用书源里匹配 —— 「大家在看什么」和
//      「我能不能读」两件事都在这里解决。点进去直接是可读书的详情页；
//      没匹配上的给「去书源里搜」。
//   ② 书源榜（热销 / 新书 / 完结 / 口碑）：各书源站内榜单实时聚合。
//      口径见设计稿 §4.3：按源内名次加权，同名书跨源累加；口碑按多源收录数。
//
// 刷新：右上角刷新按钮，以及列表**滑到底部继续上滑**（不做下拉刷新）——
// 还有没落地的条目就先加载剩余，全部显示完了再上滑就整榜重拉。重拉同样要
// 先作废缓存（并等磁盘删完）—— 旧实现作废是异步的，紧接着的取数会把磁盘
// 旧值读回来，「刷了等于没刷」。
import 'package:flutter/material.dart';

import '../collect/aggregate.dart';
import '../collect/hot_board.dart';
import '../collect/hot_resolver.dart';
import '../feed_cache.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../theme.dart';
import '../ui/brand.dart';
import 'book_detail_screen.dart';
import 'search_screen.dart';

/// 页面页签。
enum _Tab {
  qidian('起点榜'),
  fanqie('番茄榜'),
  owllook('Owllook榜'),
  comic('漫画榜'),
  sales('热销榜'),
  fresh('新书榜'),
  done('完结榜'),
  praise('口碑榜');

  const _Tab(this.label);
  final String label;

  /// 权威榜对应的抓取定义（书源榜为 null）。
  HotBoard? get hotBoard => switch (this) {
        _Tab.qidian => HotBoard.owllookQidian,
        _Tab.fanqie => HotBoard.fanqieRank,
        _Tab.owllook => HotBoard.owllookHot,
        _ => null,
      };

  bool get isHot => hotBoard != null;

  /// 只聚合漫画书源（图片源）的站内发现页。
  bool get comicOnly => this == _Tab.comic;

  /// 书源榜对应的聚合口径。
  RankBoard? get srcBoard => switch (this) {
        _Tab.comic => RankBoard.hot,
        _Tab.sales => RankBoard.hot,
        _Tab.fresh => RankBoard.fresh,
        _Tab.done => RankBoard.done,
        _Tab.praise => RankBoard.praise,
        _ => null,
      };
}

class RankScreen extends StatefulWidget {
  const RankScreen({
    super.key,
    this.initialCategory = '全部',
    this.initialComic = false,
  });

  final String initialCategory;

  /// 从首页「漫画推荐 · 更多」进入时直接落在漫画榜页签。
  final bool initialComic;

  @override
  State<RankScreen> createState() => _RankScreenState();
}

class _RankScreenState extends State<RankScreen>
    with AutomaticKeepAliveClientMixin {
  _Tab _tab = _Tab.qidian;
  late String _cat = widget.initialCategory;

  @override
  void initState() {
    super.initState();
    if (widget.initialComic) _tab = _Tab.comic;
    _load();
  }

  // ---- 书源榜状态 ----
  List<AggRankEntry>? _items;
  int _done = 0;
  int _total = 0;

  // ---- 权威榜状态 ----
  HotBoardData? _hotData;
  List<HotRankEntry>? _hotEntries;
  int _hotDone = 0;
  int _hotTotal = 0;
  String? _hotError;

  /// 热榜一次落地多少本；滑到底部再上滑就加一档（榜单条目多于这个数时）。
  static const int _hotStep = 30;
  int _hotLimit = _hotStep;

  /// 上滑触发的节流时间戳（越界会连发十几条通知）。
  DateTime? _lastMoreAt;

  int _gen = 0;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  Future<void> _load() async {
    if (_tab.isHot) {
      await _loadHot();
    } else {
      await _loadSourceBoard();
    }
  }

  Future<void> _loadSourceBoard() async {
    final gen = ++_gen;
    final board = _tab.srcBoard!;
    final comicOnly = _tab.comicOnly;
    final sourceCount = comicOnly
        ? [for (final s in collectSources()) if (s.isImageBook) s].length
        : collectSources().length;
    setState(() {
      _loading = true;
      _items = null;
      _done = 0;
      _total = sourceCount;
    });
    final list = await aggregateRank(
      board,
      comicOnly ? '全部' : _cat, // 漫画源的分类名各家不同，不套书籍分类
      comicOnly: comicOnly,
      onProgress: (done, total) {
        if (!mounted || gen != _gen) return;
        setState(() {
          _done = done;
          _total = total;
        });
      },
      // 有源返回就立刻上屏（先到先显现，不等最慢的源）
      onPartial: (partial) {
        if (!mounted || gen != _gen || partial.isEmpty) return;
        setState(() {
          _items = partial;
          _loading = false;
        });
      },
    );
    if (!mounted || gen != _gen) return;
    setState(() {
      _items = list;
      _loading = false;
    });
  }

  /// 权威榜：先取榜单，再逐本落到可用书源（先到先上屏）。
  Future<void> _loadHot({bool keep = false}) async {
    final gen = ++_gen;
    final board = _tab.hotBoard!;
    setState(() {
      _loading = true;
      // keep：上滑加载更多时别把已经上屏的列表清空，否则整页闪一下
      if (!keep) {
        _hotData = null;
        _hotEntries = null;
      }
      _hotError = null;
      _hotDone = 0;
    });
    try {
      final data = await fetchHotBoard(board);
      if (!mounted || gen != _gen) return;
      setState(() {
        _hotData = data;
        _hotTotal = data.items.length;
      });
      final entries = await resolveHotItems(
        data.items,
        maxItems: _hotLimit,
        isCancelled: () => !mounted || gen != _gen,
        onProgress: (done, total) {
          if (!mounted || gen != _gen) return;
          setState(() {
            _hotDone = done;
            _hotTotal = total;
          });
        },
        onPartial: (partial) {
          if (!mounted || gen != _gen) return;
          setState(() {
            _hotEntries = partial;
            _loading = false;
          });
        },
      );
      if (!mounted || gen != _gen) return;
      setState(() {
        _hotEntries = entries;
        _loading = false;
      });
    } catch (e) {
      if (!mounted || gen != _gen) return;
      setState(() {
        _hotError = e.toString().replaceFirst('Exception: ', '');
        _loading = false;
      });
    }
  }

  /// 列表滑到底部后继续上滑：还有没落地的条目就加载剩余，没有就整榜重拉。
  bool _onScroll(ScrollNotification n) {
    if (n is! OverscrollNotification || n.overscroll <= 0) return false;
    if (n.metrics.extentAfter > 0) return false; // 还没到底
    final now = DateTime.now();
    if (_lastMoreAt != null &&
        now.difference(_lastMoreAt!) < const Duration(milliseconds: 900)) {
      return false;
    }
    _lastMoreAt = now;
    _loadMore();
    return false;
  }

  Future<void> _loadMore() async {
    if (_loading) return;
    if (_tab.isHot) {
      final total = _hotData?.items.length ?? 0;
      final shown = _hotEntries?.length ?? 0;
      if (total > shown) {
        // 榜单条目比已落地的多（番茄榜 40 本、默认只落地 30）→ 继续落地剩余。
        _hotLimit = shown + _hotStep;
        await _loadHot(keep: true);
        return;
      }
    }
    await _reload();
  }

  Future<void> _reload() async {
    if (mounted) setState(() => _loading = true);
    _hotLimit = _hotStep;
    if (_tab.isHot) {
      // 榜单自己缓存 10 分钟，刷新时连匹配记忆一起作废 —— 用户按刷新就是
      // 想看到「现在的榜单 + 现在的可读情况」，不是再看一遍十年前的结论。
      HotBoardCache.clear(_tab.hotBoard!.id);
      HotMatchCache.clear();
    } else {
      // 必须 await：内存清掉后 reach() 会去磁盘兜底，磁盘删除是异步的
      await FeedCache.invalidatePrefixAsync('rank');
    }
    if (!mounted) return;
    await _load();
    PetStore.I.emit(PetAction.discoverOpen);
  }

  void _openSourceBook(AggRankEntry e) {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BookDetailScreen(book: e.book)));
  }

  /// 热榜条目：匹配到就进能读的那本书，没匹配到就去搜（仍走可用书源池）。
  void _openHotEntry(HotRankEntry e) {
    final b = e.book;
    if (b != null) {
      Navigator.of(context)
          .push(MaterialPageRoute(builder: (_) => BookDetailScreen(book: b)));
      return;
    }
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => SearchScreen(initialQuery: hotSearchKeyword(e.item))));
  }

  void _openExplainSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                child: Text('榜单口径',
                    style:
                        TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
              ),
              for (final b in HotBoard.all)
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.local_fire_department_outlined),
                  title: Text('${b.label} · ${b.site}'),
                  subtitle: Text(b.note),
                ),
              const ListTile(
                dense: true,
                leading: Icon(Icons.link_outlined),
                title: Text('权威榜怎么变成「能读的书」'),
                subtitle: Text('拿榜单书名回你启用的书源里搜一遍，命中才给「xx 源可读」；'
                    '没命中的点一下就是去书源里搜，不会跳到别的网站'),
              ),
              const ListTile(
                dense: true,
                leading: Icon(Icons.sync_outlined),
                title: Text('书源榜（热销 / 新书 / 完结）'),
                subtitle: Text('取各书源站内对应榜单，按名次加权合并；同名书跨源累加'),
              ),
              const ListTile(
                dense: true,
                leading: Icon(Icons.verified_outlined),
                title: Text('口碑榜'),
                subtitle: Text('按「多源共同收录数」排序 —— 被越多书源同时收录，排名越靠前'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
    final body = _tab.isHot ? _hotBody(theme) : _sourceBody(theme);
    return Column(
      children: [
        _appBar(theme, narrow: narrow),
        _boardTabs(theme),
        _tab.isHot
            ? _hotStatusBar(theme, narrow: narrow)
            : (_tab.comicOnly
                ? _comicStatusBar(theme, narrow: narrow)
                : _categoryChips(narrow: narrow)),
        Expanded(
          // 不做下拉刷新：滑到底部继续上滑才加载 / 刷新（见 [_onScroll]）。
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScroll,
            child: narrow
                ? body
                : Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 900),
                      child: body,
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  // ------------------------------------------------------------ 书源榜

  Widget _sourceBody(ThemeData theme) {
    final items = _items;
    final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
    final head = <Widget>[
      _caption(theme),
      if (_loading)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text('正在聚合 $_done/$_total 个书源…',
                  style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      const SizedBox(height: 12),
      if (items != null && items.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 60),
          child: Column(
            children: [
              const Mascot(size: 56),
              const SizedBox(height: 14),
              Text(_tab.comicOnly
                      ? '还没有可用的漫画书源\n到「我的 → 书源管理」导入图片书源（漫画源）'
                      : '这个分类暂时没拿到榜单数据\n换个分类，或到书源管理里体检一下书源',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              BrandBtn('重新聚合',
                  style: BrandBtnStyle.outline, onTap: () => _load()),
            ],
          ),
        ),
      if (items != null && items.isNotEmpty) ...[
        _top3(items.take(3).toList(), theme),
        const SizedBox(height: 6),
      ],
    ];
    final rows = (items != null && items.isNotEmpty)
        ? (items.length > 3 ? items.length - 3 : 0)
        : 0;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 4, narrow ? 16 : 22, 28),
      itemCount: head.length + rows + (rows > 0 ? 2 : 0),
      itemBuilder: (context, i) {
        if (i < head.length) return head[i];
        final r = i - head.length;
        if (r < rows) return _listRow(items![r + 3], r + 4, theme);
        if (r == rows) return const SizedBox(height: 18);
        return Text('数据来自各书源站内榜单实时抓取 · 上滑加载更多 / 到底再上滑刷新',
            textAlign: TextAlign.center,
            style: theme.textTheme.labelSmall
                ?.copyWith(fontSize: 11, color: Brand.fg3(context)));
      },
    );
  }

  Widget _caption(ThemeData theme) {
    if (_tab.comicOnly) {
      final n =
          [for (final s in collectSources()) if (s.isImageBook) s].length;
      return Text('漫画榜 · $n 个漫画书源站内发现页实时聚合 · 与小说榜分开排',
          style: theme.textTheme.labelSmall
              ?.copyWith(fontSize: 11, color: Brand.fg3(context)));
    }
    final n = collectSources().length;
    return Text('书源榜 · 4 个榜单 × 9 个分类 · $n 个书源实时聚合',
        style: theme.textTheme.labelSmall
            ?.copyWith(fontSize: 11, color: Brand.fg3(context)));
  }

  /// 漫画榜顶端状态条：替代书籍分类 chips（漫画源分类名各家不同）。
  Widget _comicStatusBar(ThemeData theme, {required bool narrow}) {
    return SizedBox(
      height: 46,
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 10, 16, 10),
        child: Row(
          children: [
            const SrcPill('漫画'),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                  '只聚合图片书源（漫画）的站内榜单 · 点进去走漫画阅读器',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 11, color: Brand.fg3(context))),
            ),
            if (_items != null)
              Text('${_items!.length} 部',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: Brand.green)),
          ],
        ),
      ),
    );
  }

  // ------------------------------------------------------------ 权威榜

  Widget _hotBody(ThemeData theme) {
    final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
    final entries = _hotEntries;
    final data = _hotData;
    final matched = entries?.where((e) => e.readable).length ?? 0;

    final head = <Widget>[
      if (data != null) _hotCaption(theme, data, matched),
      if (_loading)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            children: [
              const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2)),
              const SizedBox(width: 10),
              Text(
                data == null
                    ? '正在取「${_tab.hotBoard!.site}」榜单…'
                    : '正在书源里找这 $_hotTotal 本书… $_hotDone/$_hotTotal',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      if (_hotError != null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(
            children: [
              const Mascot(size: 56),
              const SizedBox(height: 14),
              Text(_hotError!, textAlign: TextAlign.center,
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 12),
              BrandBtn('重试',
                  style: BrandBtnStyle.outline, onTap: () => _reload()),
              const SizedBox(height: 8),
              Text('也可以先看「热销 / 新书 / 完结」这些书源榜',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 11, color: Brand.fg3(context))),
            ],
          ),
        ),
      const SizedBox(height: 8),
      if (entries != null && entries.isNotEmpty) ...[
        _hotTop3(entries.take(3).toList(), theme),
        const SizedBox(height: 6),
      ],
    ];

    final rows = (entries != null && entries.length > 3)
        ? entries.length - 3
        : 0;
    return ListView.builder(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 4, narrow ? 16 : 22, 28),
      itemCount: head.length + rows + 1,
      itemBuilder: (context, i) {
        if (i < head.length) return head[i];
        final r = i - head.length;
        if (r < rows) return _hotRow(entries![r + 3], r + 4, theme);
        return Text(
          entries == null || entries.isEmpty
              ? '榜单来自 ${_tab.hotBoard!.site} 的公开数据'
              : '榜单来自 ${_tab.hotBoard!.site} · 继续上滑加载剩余 / 到底再上滑刷新',
          textAlign: TextAlign.center,
          style: theme.textTheme.labelSmall
              ?.copyWith(fontSize: 11, color: Brand.fg3(context)),
        );
      },
    );
  }

  Widget _hotCaption(ThemeData theme, HotBoardData data, int matched) {
    final total = data.items.length;
    final time = _hm(data.fetchedAt);
    return Text(
      '${data.board.site} · $total 本 · $matched 本可读 · $time 抓取'
      '${data.siteUpdated == null ? '' : ' · 站内更新 ${data.siteUpdated}'}',
      style: theme.textTheme.labelSmall
          ?.copyWith(fontSize: 11, color: Brand.fg3(context)),
    );
  }

  /// 权威榜顶端的状态条：来源 + 匹配进度（替代分类筛选）。
  Widget _hotStatusBar(ThemeData theme, {required bool narrow}) {
    final board = _tab.hotBoard!;
    final entries = _hotEntries;
    final matched = entries?.where((e) => e.readable).length ?? 0;
    final total = entries?.length ?? 0;
    return SizedBox(
      height: 46,
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 10, 16, 10),
        child: Row(
          children: [
            SrcPill(board.site),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                board.id == HotBoard.owllookQidian.id
                    ? '起点官方榜单汇总 · 月票 / 畅销 / 阅读指数'
                    : board.id == HotBoard.fanqieRank.id
                        ? '番茄官方榜 · 男频 / 女频 × 阅读 / 新书'
                        : 'owllook 站内搜索次数榜 · 大家都在搜',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall
                    ?.copyWith(fontSize: 11, color: Brand.fg3(context)),
              ),
            ),
            if (total > 0)
              Text('$matched/$total 可读',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: matched > 0 ? Brand.green : Brand.fg3(context))),
          ],
        ),
      ),
    );
  }

  Widget _hotTop3(List<HotRankEntry> top, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < top.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () => _openHotEntry(top[i]),
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AspectRatio(
                        aspectRatio: 0.74,
                        child: BookCover(_coverBook(top[i]),
                            width: double.infinity, radius: 12),
                      ),
                      Positioned(
                        left: -7,
                        top: -7,
                        child: Container(
                          width: 27,
                          height: 27,
                          decoration: BoxDecoration(
                            color: Brand.rank(i + 1),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: theme.scaffoldBackgroundColor, width: 2),
                            boxShadow: [
                              BoxShadow(
                                  color: Brand.rank(i + 1)
                                      .withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3)),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text('${i + 1}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(top[i].item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium?.copyWith(
                          fontSize: 12.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (top[i].item.author?.isNotEmpty ?? false)
                        top[i].item.author!,
                      if (top[i].readable)
                        sourceNameOf(top[i].source!.id)
                      else
                        '未匹配到可读源',
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: 10.5, color: Brand.fg3(context)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _hotRow(HotRankEntry e, int rank, ThemeData theme) {
    final item = e.item;
    final meta = [
      if (item.author?.isNotEmpty ?? false) item.author!,
      if (item.category?.isNotEmpty ?? false) item.category!,
      if (item.status?.isNotEmpty ?? false) item.status!,
      if (item.hint?.isNotEmpty ?? false) '搜索 ${item.hint}',
    ].join(' · ');
    return GestureDetector(
      onTap: () => _openHotEntry(e),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            RankNum(rank),
            const SizedBox(width: 10),
            BookCover(_coverBook(e), width: 40, height: 54, radius: 7),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5, color: Brand.fg3(context))),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (e.readable)
              SrcPill(sourceNameOf(e.source!.id), accent: true)
            else
              const SrcPill('去搜索'),
          ],
        ),
      ),
    );
  }

  /// 展示用书对象：未匹配到时用榜单自带的书名/作者/封面兜底（不可点读）。
  Book _coverBook(HotRankEntry e) {
    final b = e.book;
    if (b != null) return b;
    return Book(
      sourceId: '',
      id: '',
      url: '',
      title: e.item.title,
      author: e.item.author,
      cover: e.item.cover,
      status: e.item.status,
    );
  }

  // ------------------------------------------------------------ 公共

  Widget _appBar(ThemeData theme, {required bool narrow}) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 6, narrow ? 8 : 14, 0),
        child: Row(
          children: [
            Text('排行',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontSize: 20, fontWeight: FontWeight.w800)),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.refresh, size: 20, color: theme.hintColor),
              tooltip: '刷新榜单',
              onPressed: _reload,
            ),
            IconButton(
              icon: Icon(Icons.info_outline, size: 20, color: theme.hintColor),
              tooltip: '榜单口径',
              onPressed: _openExplainSheet,
            ),
          ],
        ),
      ),
    );
  }

  /// 7 个榜单页签：权威榜 / 漫画榜 / 书源榜之间加细分隔线。
  Widget _boardTabs(ThemeData theme) {
    const tabs = _Tab.values;
    return SizedBox(
      height: 44,
      // 8 个页签平分屏宽时，大字体 / 窄屏会把「Owllook榜」「口碑榜」截断
      // （真机截图确认）。改为横向滚动 + 固定宽度，每个标签都完整显示。
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < tabs.length; i++) ...[
              if (i == 3 || i == 4)
                Container(
                  width: 1,
                  height: 16,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  color: theme.dividerColor.withValues(alpha: 0.5),
                ),
              GestureDetector(
                onTap: () {
                  if (_tab == tabs[i]) return;
                  setState(() {
                    _tab = tabs[i];
                    _items = null;
                    _hotEntries = null;
                    _hotData = null;
                    _hotError = null;
                    _hotLimit = _hotStep;
                  });
                  _load();
                },
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: tabs[i].label.length > 5 ? 108 : 84,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Center(
                          child: Text(
                            tabs[i].label,
                            maxLines: 1,
                            textScaler: TextScaler.noScaling,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: _tab == tabs[i]
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: _tab == tabs[i]
                                  ? theme.colorScheme.onSurface
                                  : Brand.fg3(context),
                            ),
                          ),
                        ),
                      ),
                      Container(
                        height: 2.5,
                        width: 26,
                        decoration: BoxDecoration(
                          color: _tab == tabs[i]
                              ? Brand.green
                              : Colors.transparent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 5),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _categoryChips({required bool narrow}) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 8, 16, 10),
        children: [
          for (final c in kRankCategories)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChip(c,
                  selected: _cat == c,
                  onTap: () {
                    if (_cat == c) return;
                    setState(() {
                      _cat = c;
                      _items = null;
                    });
                    _load();
                  }),
            ),
        ],
      ),
    );
  }

  /// TOP3 特写卡（书源榜）。
  Widget _top3(List<AggRankEntry> top, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < top.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () => _openSourceBook(top[i]),
              behavior: HitTestBehavior.opaque,
              child: Column(
                children: [
                  Stack(
                    clipBehavior: Clip.none,
                    children: [
                      AspectRatio(
                        aspectRatio: 0.74,
                        child: BookCover(top[i].book,
                            width: double.infinity, radius: 12),
                      ),
                      Positioned(
                        left: -7,
                        top: -7,
                        child: Container(
                          width: 27,
                          height: 27,
                          decoration: BoxDecoration(
                            color: Brand.rank(i + 1),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: theme.scaffoldBackgroundColor, width: 2),
                            boxShadow: [
                              BoxShadow(
                                  color: Brand.rank(i + 1)
                                      .withValues(alpha: 0.4),
                                  blurRadius: 8,
                                  offset: const Offset(0, 3)),
                            ],
                          ),
                          alignment: Alignment.center,
                          child: Text('${i + 1}',
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 7),
                  Text(top[i].book.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (top[i].book.author?.isNotEmpty ?? false)
                        top[i].book.author!,
                      if (top[i].sourceCount > 1)
                        '${top[i].sourceCount} 源收录'
                      else
                        sourceNameOf(top[i].book.sourceId),
                    ].join(' · '),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall
                        ?.copyWith(fontSize: 10.5, color: Brand.fg3(context)),
                  ),
                ],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _listRow(AggRankEntry e, int rank, ThemeData theme) {
    final b = e.book;
    final meta = [
      if (b.author?.isNotEmpty ?? false) b.author!,
      if (b.status?.isNotEmpty ?? false) b.status!,
    ].join(' · ');
    return GestureDetector(
      onTap: () => _openSourceBook(e),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            RankNum(rank),
            const SizedBox(width: 10),
            BookCover(b, width: 40, height: 54, radius: 7),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  if (meta.isNotEmpty) ...[
                    const SizedBox(height: 3),
                    Text(meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodySmall?.copyWith(
                            fontSize: 11.5, color: Brand.fg3(context))),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            if (isComicBook(b))
              const SrcPill('漫画')
            else if (e.sourceCount > 1)
              SrcPill('${e.sourceCount} 个来源', accent: true)
            else
              SrcPill(sourceNameOf(b.sourceId)),
          ],
        ),
      ),
    );
  }

  /// 「刚刚 / 3 分钟前」。
  static String _hm(DateTime t) {
    final d = DateTime.now().difference(t);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inHours < 1) return '${d.inMinutes} 分钟前';
    return '${t.month}-${t.day} ${t.hour.toString().padLeft(2, '0')}:'
        '${t.minute.toString().padLeft(2, '0')}';
  }
}
