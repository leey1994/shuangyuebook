// 书架：在线书架 / 本地书 分段 + 排序快捷 chips + 网格卡片 + 批量管理。
//
// 长按卡片进多选；「历史」收进右上角更多菜单（阅读历史页）。
import 'dart:async';

import 'package:flutter/material.dart';

import '../data/format.dart';
import '../data/shelf_sort.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/local_source.dart';
import '../store.dart';
import '../theme.dart';
import '../ui/brand.dart';
import 'local_import_page.dart';
import 'reader_screen.dart';

class ShelfScreen extends StatefulWidget {
  const ShelfScreen({super.key});

  @override
  State<ShelfScreen> createState() => _ShelfScreenState();
}

class _ShelfScreenState extends State<ShelfScreen> {
  /// 每个进程只自动补查一次；手动入口不受此限。
  static bool _sessionChecked = false;

  int _seg = 0; // 0 = 在线书架，1 = 本地书
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  void initState() {
    super.initState();
    // 首次进书架且距上次检查超过间隔：后台补一次，红点自己冒出来。
    // 延迟两秒避开启动高峰，不与公告/版本检查抢网。
    if (!_sessionChecked && AppStore.I.updateCheckDue) {
      _sessionChecked = true;
      Future.delayed(const Duration(seconds: 2), () {
        if (!mounted) return;
        unawaited(AppStore.I.checkShelfUpdates());
      });
    }
  }

  List<ShelfEntry> get _online => [
        for (final e in AppStore.I.shelf)
          if (e.book.sourceId != LocalSource.sourceId) e
      ];

  List<ShelfEntry> get _local => [
        for (final e in AppStore.I.shelf)
          if (e.book.sourceId == LocalSource.sourceId) e
      ];

  List<ShelfEntry> get _current => _seg == 0 ? _online : _local;

  Future<void> _manualCheck() async {
    final (updated, newCh, failed) = await AppStore.I.checkShelfUpdates();
    if (!mounted) return;
    final msg = updated > 0
        ? '$updated 本书更新了 $newCh 章'
        : (failed > 0 ? '暂无新章节（$failed 本检查失败）' : '暂无新章节');
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 2),
    ));
  }

  void _exitSelect() => setState(() {
        _selecting = false;
        _selected.clear();
      });

  Future<void> _removeSelected() async {
    final n = _selected.length;
    if (n == 0) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移出书架'),
        content: Text('确定把选中的 $n 本书移出书架吗？\n（阅读进度仍在阅读历史里，可随时找回）'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('移出')),
        ],
      ),
    );
    if (ok != true) return;
    for (final url in _selected) {
      AppStore.I.removeFromShelf(url);
    }
    PetStore.I.emit(PetAction.shelfRemove);
    if (mounted) _exitSelect();
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
              leading: AppStore.I.checkingUpdates
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              title: const Text('检查更新'),
              subtitle: const Text('抓取书架里每本书的最新章节'),
              onTap: () {
                Navigator.of(ctx).pop();
                if (!AppStore.I.checkingUpdates) _manualCheck();
              },
            ),
            ListTile(
              leading: const Icon(Icons.checklist),
              title: const Text('批量管理'),
              onTap: () {
                Navigator.of(ctx).pop();
                setState(() {
                  _selecting = true;
                  _selected.clear();
                });
              },
            ),
            ListTile(
              leading: const Icon(Icons.history),
              title: const Text('阅读历史'),
              onTap: () {
                Navigator.of(ctx).pop();
                Navigator.of(context).push(MaterialPageRoute(
                    builder: (_) => const HistoryPage()));
              },
            ),
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('导入本地书'),
              subtitle: const Text('TXT / EPUB'),
              onTap: () {
                Navigator.of(ctx).pop();
                showLocalImport(context);
              },
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSort() async {
    final store = AppStore.I;
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in ShelfSortMode.values)
              ListTile(
                title: Text(m.label),
                trailing: store.shelfSort == m
                    ? const Icon(Icons.check, color: Brand.green)
                    : null,
                onTap: () {
                  store.setShelfSort(m);
                  PetStore.I.emit(PetAction.shelfSort);
                  Navigator.of(ctx).pop();
                },
              ),
            const Divider(height: 1),
            ListTile(
              leading: Icon(store.shelfAscending
                  ? Icons.arrow_upward
                  : Icons.arrow_downward),
              title: Text(store.shelfAscending ? '当前：正序' : '当前：倒序'),
              onTap: () {
                store.setShelfAscending(!store.shelfAscending);
                PetStore.I.emit(PetAction.shelfSort);
                Navigator.of(ctx).pop();
              },
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final narrow = MediaQuery.sizeOf(context).width < kNarrowBreakpoint;
    return ListenableBuilder(
      listenable: AppStore.I,
      builder: (context, _) {
        // 按设置里的排序方式就地整理（默认「最近阅读」即原顺序）
        AppStore.I.applyShelfSort();
        final online = _online;
        final local = _local;
        final list = _current;
        return Column(
          children: [
            _appBar(theme, narrow: narrow, onlineCount: online.length),
            if (!_selecting) ...[
              _segmented(theme, online: online.length, local: local.length),
              if (_seg == 0) _sortChips(theme),
            ] else
              _selectHeader(theme, list),
            Expanded(
              child: list.isEmpty
                  ? _emptyState(theme)
                  : _grid(theme, list, narrow: narrow),
            ),
            if (_selecting) _selectBar(theme),
          ],
        );
      },
    );
  }

  // ---------------------------------------------------------------- 头部

  Widget _appBar(ThemeData theme,
      {required bool narrow, required int onlineCount}) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: EdgeInsets.fromLTRB(narrow ? 16 : 22, 6, narrow ? 8 : 14, 0),
        child: Row(
          children: [
            Text('书架',
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontSize: 20, fontWeight: FontWeight.w800)),
            const SizedBox(width: 7),
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: Text('$onlineCount 本',
                  style: theme.textTheme.labelSmall
                      ?.copyWith(fontSize: 11.5, color: Brand.fg3(context))),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.sort, size: 20, color: theme.hintColor),
              tooltip: '排序方式',
              onPressed: _pickSort,
            ),
            IconButton(
              icon: Icon(
                AppStore.I.shelfView == ShelfViewMode.square
                    ? Icons.grid_view_rounded
                    : Icons.view_agenda_outlined,
                size: 20,
                color: theme.hintColor,
              ),
              tooltip: '切换视图（${AppStore.I.shelfView.label}）',
              onPressed: () {
                AppStore.I.cycleShelfView();
                PetStore.I.emit(PetAction.shelfView);
              },
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

  Widget _segmented(ThemeData theme,
      {required int online, required int local}) {
    final dark = theme.brightness == Brightness.dark;
    final bg = dark ? const Color(0xFF1A2226) : const Color(0xFFE9EFE6);
    final card = Brand.card(context);
    Widget cell(String label, int i) {
      final on = _seg == i;
      return Expanded(
        child: GestureDetector(
          onTap: () => setState(() => _seg = i),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 140),
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: on ? card : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              boxShadow: on
                  ? [
                      BoxShadow(
                          color: Colors.black.withValues(alpha: 0.06),
                          blurRadius: 6,
                          offset: const Offset(0, 2))
                    ]
                  : null,
            ),
            child: Text(label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: on ? FontWeight.w700 : FontWeight.w500,
                  color: on ? Brand.green : theme.hintColor,
                )),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 0),
      child: Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            cell('在线书架', 0),
            cell('本地书 · $local', 1),
          ],
        ),
      ),
    );
  }

  /// 排序快捷 chips（效果图：最近阅读 / 进度 / 添加时间 / 字数）。
  Widget _sortChips(ThemeData theme) {
    const quick = [
      ShelfSortMode.recentRead,
      ShelfSortMode.progress,
      ShelfSortMode.addedTime,
      ShelfSortMode.chars,
    ];
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 9),
        children: [
          for (final m in quick)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: PillChip(m.label,
                  selected: AppStore.I.shelfSort == m,
                  onTap: () {
                    AppStore.I.setShelfSort(m);
                    PetStore.I.emit(PetAction.shelfSort);
                  }),
            ),
        ],
      ),
    );
  }

  Widget _selectHeader(ThemeData theme, List<ShelfEntry> list) {
    final all = _selected.length == list.length && list.isNotEmpty;
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 16, 0),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.close, size: 20),
              tooltip: '退出批量管理',
              onPressed: _exitSelect,
            ),
            Text('已选 ${_selected.length} 本',
                style: theme.textTheme.titleSmall
                    ?.copyWith(fontWeight: FontWeight.w700)),
            const Spacer(),
            TextButton(
              onPressed: () => setState(() {
                if (all) {
                  _selected.clear();
                } else {
                  _selected
                    ..clear()
                    ..addAll(list.map((e) => e.book.url));
                }
              }),
              child: Text(all ? '取消全选' : '全选'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _selectBar(ThemeData theme) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          16, 9, 16, 9 + MediaQuery.viewPaddingOf(context).bottom),
      decoration: BoxDecoration(
        color: Brand.card(context),
        border: Border(top: BorderSide(color: Brand.hair(context))),
      ),
      child: Row(
        children: [
          Text('已选 ${_selected.length} 本',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: Brand.fg3(context))),
          const Spacer(),
          BrandBtn('移出书架',
              style: BrandBtnStyle.outline,
              onTap: _selected.isEmpty ? null : _removeSelected),
        ],
      ),
    );
  }

  Widget _emptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Mascot(size: 60),
          const SizedBox(height: 14),
          Text(_seg == 0 ? '书架空空的，去首页找一本吧' : '还没有本地书',
              style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          BrandBtn('导入本地书 TXT / EPUB',
              style: BrandBtnStyle.outline,
              onTap: () => showLocalImport(context)),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------- 网格

  Widget _grid(ThemeData theme, List<ShelfEntry> entries,
      {required bool narrow}) {
    const gap = 12.0;
    final edge = narrow ? 16.0 : 22.0;
    final square = AppStore.I.shelfView == ShelfViewMode.square;
    return LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxWidth - edge * 2;
        // 长卡片一行一卡：书名长的才显示得全（正方形卡片维持多列密度）。
        final cols = square ? (narrow ? 3 : (avail / 176).floor().clamp(3, 6)) : 1;
        final tileW = (avail - gap * (cols - 1)) / cols;
        // 「导入本地书」虚线块只跟在在线书架后面（本地书段顶部单独放）
        final tiles = <Widget>[
          for (final e in entries)
            _tile(theme, e, tileW, square: square),
          if (_seg == 0 && !_selecting) _importTile(theme),
        ];
        return GridView.builder(
          padding: EdgeInsets.fromLTRB(edge, 6, edge, 28),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            mainAxisSpacing: 16,
            crossAxisSpacing: gap,
            mainAxisExtent: square ? tileW * 1.34 + 34 : 112,
          ),
          itemCount: tiles.length,
          itemBuilder: (context, i) => tiles[i],
        );
      },
    );
  }

  Widget _tile(ThemeData theme, ShelfEntry e, double w,
      {required bool square}) {
    final selected = _selected.contains(e.book.url);
    final upd = AppStore.I.shelfUpdates[e.book.url] ?? 0;
    final isLocal = e.book.sourceId == LocalSource.sourceId;
    final pct = (shelfProgressOf(e) * 100).round();

    Widget body;
    if (square) {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: AspectRatio(
                    aspectRatio: 1.05,
                    child: BookCover(e.book,
                        width: double.infinity, radius: 9),
                  ),
                ),
                if (upd > 0)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: Brand.red,
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(upd > 99 ? '更新 99+' : '更新 +$upd',
                          style: const TextStyle(
                              fontSize: 9.5,
                              fontWeight: FontWeight.w700,
                              color: Colors.white)),
                    ),
                  ),
                if (_selecting)
                  Positioned(
                    left: 5,
                    top: 5,
                    child: _checkDot(selected),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          ProgBar(shelfProgressOf(e), height: 4),
          const SizedBox(height: 5),
          Row(
            children: [
              Expanded(
                child: Text(e.book.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelMedium?.copyWith(
                        fontSize: 11.5, fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 4),
              Text(
                e.finished ? '读完' : '$pct%',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: e.finished ? Brand.fg3(context) : Brand.green,
                ),
              ),
            ],
          ),
        ],
      );
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: square ? 58 : 78,
            child: AspectRatio(
              aspectRatio: 0.74,
              child:
                  BookCover(e.book, width: double.infinity, radius: 6),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(e.book.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontSize: 13.5)),
                    ),
                    if (upd > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: Brand.red,
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text('更新 +$upd',
                            style: const TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Colors.white)),
                      ),
                  ],
                ),
                if ((e.book.author ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(e.book.author!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(
                          fontSize: 11, color: Brand.fg3(context))),
                ],
                const Spacer(),
                ProgBar(shelfProgressOf(e), height: 4),
                const SizedBox(height: 4),
                Text(
                  e.finished
                      ? '已读完'
                      : e.chapterCount > 0
                          ? '${e.chapterIndex + 1}/${e.chapterCount} 章 · $pct%'
                          : (e.chapterIndex > 0 ? '已读第 ${e.chapterIndex + 1} 章' : '未开始'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10.5, color: Brand.fg3(context)),
                ),
              ],
            ),
          ),
        ],
      );
    }

    return GestureDetector(
      onTap: () {
        if (_selecting) {
          setState(() {
            if (!_selected.remove(e.book.url)) _selected.add(e.book.url);
          });
          return;
        }
        Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => ReaderScreen(
            book: e.book,
            chapterIndex: e.chapterIndex,
            page: e.page,
            paragraph: e.paragraph,
          ),
        ));
      },
      onLongPress: isLocal || _selecting
          ? null
          : () => setState(() {
                _selecting = true;
                _selected
                  ..clear()
                  ..add(e.book.url);
              }),
      behavior: HitTestBehavior.opaque,
      child: body,
    );
  }

  Widget _checkDot(bool selected) {
    return Container(
      width: 20,
      height: 20,
      decoration: BoxDecoration(
        color: selected ? Brand.green : Colors.white.withValues(alpha: 0.9),
        shape: BoxShape.circle,
        border: Border.all(
            color: selected ? Brand.green : const Color(0xFFB9C6B4), width: 1.5),
      ),
      child: selected
          ? const Icon(Icons.check, size: 13, color: Colors.white)
          : null,
    );
  }

  /// 「导入本地书」虚线块（效果图 .dashed）。
  Widget _importTile(ThemeData theme) {
    return GestureDetector(
      onTap: () => showLocalImport(context),
      behavior: HitTestBehavior.opaque,
      child: CustomPaint(
        painter: _DashedBorderPainter(
          color: Brand.hair(context),
          radius: 10,
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add, size: 22, color: Brand.fg3(context)),
              const SizedBox(height: 6),
              Text('导入本地书',
                  style: theme.textTheme.labelMedium?.copyWith(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w600,
                      color: theme.hintColor)),
              const SizedBox(height: 2),
              Text('TXT / EPUB',
                  style: theme.textTheme.labelSmall?.copyWith(
                      fontSize: 10, color: Brand.fg3(context))),
            ],
          ),
        ),
      ),
    );
  }
}

/// 圆角虚线边框（导入块用；不引第三方包）。
class _DashedBorderPainter extends CustomPainter {
  _DashedBorderPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.6, 0.6, size.width - 1.2, size.height - 1.2),
      Radius.circular(radius),
    );
    // 沿路径打虚线：8 实 6 虚
    final path = Path()..addRRect(rrect);
    const dash = 8.0, gap = 6.0;
    for (final metric in path.computeMetrics()) {
      var d = 0.0;
      while (d < metric.length) {
        final end = (d + dash).clamp(0.0, metric.length);
        canvas.drawPath(metric.extractPath(d, end), paint);
        d = end + gap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      old.color != color || old.radius != radius;
}

/// 阅读历史页（从书架「更多」进入）：跨书历史 + 一键清空。
class HistoryPage extends StatelessWidget {
  const HistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('阅读历史'),
        actions: [
          ListenableBuilder(
            listenable: AppStore.I,
            builder: (context, _) => AppStore.I.history.isEmpty
                ? const SizedBox.shrink()
                : TextButton(
                    onPressed: () {
                      AppStore.I.clearHistory();
                      PetStore.I.emit(PetAction.shelfClear);
                    },
                    child: const Text('清空'),
                  ),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: AppStore.I,
        builder: (context, _) {
          final list = AppStore.I.history;
          if (list.isEmpty) {
            return Center(
                child: Text('暂无阅读历史', style: theme.textTheme.bodyLarge));
          }
          return ListView.builder(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            itemCount: list.length,
            itemBuilder: (context, i) {
              final e = list[i];
              final pct = (shelfProgressOf(e) * 100).round();
              return GestureDetector(
                onTap: () => Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ReaderScreen(
                    book: e.book,
                    chapterIndex: e.chapterIndex,
                    page: e.page,
                    paragraph: e.paragraph,
                  ),
                )),
                onLongPress: () => AppStore.I.removeFromHistory(e.book.url),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Row(
                    children: [
                      BookCover(e.book, width: 44, height: 60, radius: 8),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(e.book.title,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                    fontSize: 14.5,
                                    fontWeight: FontWeight.w700)),
                            const SizedBox(height: 3),
                            Text(
                              '第 ${e.chapterIndex + 1} 章'
                              '${e.chapterTitle.isEmpty ? '' : ' · ${e.chapterTitle}'}'
                              ' · $pct%',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodySmall?.copyWith(
                                  fontSize: 11.5, color: Brand.fg3(context)),
                            ),
                            const SizedBox(height: 6),
                            Text(
                              timeAgo(e.updatedAt.millisecondsSinceEpoch),
                              style: theme.textTheme.labelSmall?.copyWith(
                                  fontSize: 10.5, color: Brand.fg3(context)),
                            ),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right,
                          size: 18, color: Brand.fg3(context)),
                    ],
                  ),
                ),
              );
            },
          );
        },
      ),
    );
  }
}
