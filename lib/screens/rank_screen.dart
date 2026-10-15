// 排行：4 个榜单 × 9 个分类的全源实时聚合。
//
// 口径（见设计稿 §4.3）：热销 / 新书 / 完结按各源站内名次加权；
// 口碑按多源共同收录数。书只能从「书源自己的榜单标签」进榜，
// 不做书名关键词分类 —— 不造数据。
import 'package:flutter/material.dart';

import '../collect/aggregate.dart';
import '../feed_cache.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../theme.dart';
import '../ui/brand.dart';
import 'book_detail_screen.dart';

class RankScreen extends StatefulWidget {
  const RankScreen({super.key, this.initialCategory = '全部'});

  final String initialCategory;

  @override
  State<RankScreen> createState() => _RankScreenState();
}

class _RankScreenState extends State<RankScreen>
    with AutomaticKeepAliveClientMixin {
  RankBoard _board = RankBoard.hot;
  late String _cat = widget.initialCategory;
  List<AggRankEntry>? _items;
  int _done = 0;
  int _total = 0;
  int _gen = 0;
  bool _loading = true;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final gen = ++_gen;
    setState(() {
      _loading = true;
      _items = null;
      _done = 0;
      _total = collectSources().length;
    });
    final list = await aggregateRank(
      _board,
      _cat,
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

  Future<void> _reload() async {
    FeedCache.invalidatePrefix('rank');
    if (mounted) setState(() => _loading = true);
    await _load();
    PetStore.I.emit(PetAction.discoverOpen);
  }

  void _openBook(AggRankEntry e) {
    Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => BookDetailScreen(book: e.book)));
  }

  void _openExplainSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => const SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
              child: Text('榜单口径',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.local_fire_department_outlined),
              title: Text('热销 / 新书 / 完结'),
              subtitle: Text('取各书源站内对应榜单，按名次加权合并；同名书跨源累加'),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.verified_outlined),
              title: Text('口碑'),
              subtitle: Text('按「多源共同收录数」排序 —— 被越多书源同时收录，排名越靠前'),
            ),
            ListTile(
              dense: true,
              leading: Icon(Icons.sync_outlined),
              title: Text('实时聚合'),
              subtitle: Text('所有排名均来自书源站内榜单的实时抓取，非本地人工编排'),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final items = _items;
    final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
    final body = ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 4, narrow ? 16 : 22, 28),
      children: [
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
                Text('这个分类暂时没拿到榜单数据\n换个分类，或到书源管理里体检一下书源',
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
          for (var i = 3; i < items.length; i++) _listRow(items[i], i + 1, theme),
          const SizedBox(height: 18),
          Text('数据来自各书源站内榜单实时抓取 · 下拉刷新',
              textAlign: TextAlign.center,
              style: theme.textTheme.labelSmall
                  ?.copyWith(fontSize: 11, color: Brand.fg3(context))),
        ],
      ],
    );
    return Column(
      children: [
        _appBar(theme, narrow: narrow),
        _boardTabs(theme),
        _categoryChips(narrow: narrow),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _reload,
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

  /// 4 个榜单大字 tab（绿色下划线）。
  Widget _boardTabs(ThemeData theme) {
    return SizedBox(
      height: 42,
      child: Row(
        children: [
          for (final b in RankBoard.values)
            Expanded(
              child: GestureDetector(
                onTap: () {
                  if (_board == b) return;
                  setState(() {
                    _board = b;
                    _items = null;
                  });
                  _load();
                },
                behavior: HitTestBehavior.opaque,
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Expanded(
                      child: Center(
                        child: Text(
                          b.label,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: _board == b
                                ? FontWeight.w800
                                : FontWeight.w500,
                            color: _board == b
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
                        color: _board == b
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
      ),
    );
  }

  Widget _caption(ThemeData theme) {
    final n = collectSources().length;
    return Text('4 个榜单 × 9 个分类 · $n 个书源实时聚合',
        style: theme.textTheme.labelSmall
            ?.copyWith(fontSize: 11, color: Brand.fg3(context)));
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

  /// TOP3 特写卡。
  Widget _top3(List<AggRankEntry> top, ThemeData theme) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < top.length; i++) ...[
          if (i > 0) const SizedBox(width: 12),
          Expanded(
            child: GestureDetector(
              onTap: () => _openBook(top[i]),
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
      onTap: () => _openBook(e),
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
            if (e.sourceCount > 1)
              SrcPill('${e.sourceCount} 个来源', accent: true)
            else
              SrcPill(sourceNameOf(b.sourceId)),
          ],
        ),
      ),
    );
  }
}
