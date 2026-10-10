import 'package:flutter/material.dart';

import '../data/shelf_sort.dart';
import '../models.dart';
import '../store.dart';
import '../widgets.dart';
import 'local_import_page.dart';
import 'reader_screen.dart';

/// 书架 + 阅读历史。
class ShelfScreen extends StatelessWidget {
  const ShelfScreen({super.key});

  static const _viewIcons = {
    ShelfViewMode.wide: Icons.view_agenda_outlined,
    ShelfViewMode.square: Icons.grid_on_outlined,
  };

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书架'),
          actions: [
            IconButton(
              tooltip: '切换视图（${AppStore.I.shelfView.label}）',
              icon: Icon(_viewIcons[AppStore.I.shelfView]),
              onPressed: AppStore.I.cycleShelfView,
            ),
            IconButton(
              tooltip: '导入本地书',
              icon: const Icon(Icons.folder_open_outlined),
              onPressed: () => showLocalImport(context),
            ),
          ],
          bottom: const TabBar(tabs: [Tab(text: '书架'), Tab(text: '历史')]),
        ),
        body: ListenableBuilder(
          listenable: AppStore.I,
          builder: (context, _) {
            // 按设置里的排序方式就地整理（默认「最近阅读」即原顺序）
            AppStore.I.applyShelfSort();
            return TabBarView(
              children: [
                _EntryList(
                  entries: AppStore.I.shelf,
                  emptyHint: '还没有书，去「发现」找一本吧',
                  onOpen: (e) => _openReader(context, e),
                  onRemove: (e) => AppStore.I.removeFromShelf(e.book.url),
                  removeLabel: '移出书架',
                ),
                _EntryList(
                  entries: AppStore.I.history,
                  emptyHint: '暂无阅读历史',
                  onOpen: (e) => _openReader(context, e),
                  onRemove: (e) => AppStore.I.removeFromHistory(e.book.url),
                  removeLabel: '删除记录',
                  headerAction: AppStore.I.history.isEmpty
                      ? null
                      : TextButton(
                          onPressed: () => AppStore.I.clearHistory(),
                          child: const Text('清空'),
                        ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static void _openReader(BuildContext context, ShelfEntry e) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        book: e.book,
        chapterIndex: e.chapterIndex,
        page: e.page,
        paragraph: e.paragraph,
      ),
    ));
  }
}

class _EntryList extends StatelessWidget {
  final List<ShelfEntry> entries;
  final String emptyHint;
  final void Function(ShelfEntry) onOpen;
  final void Function(ShelfEntry) onRemove;
  final String removeLabel;
  final Widget? headerAction;

  const _EntryList({
    required this.entries,
    required this.emptyHint,
    required this.onOpen,
    required this.onRemove,
    required this.removeLabel,
    this.headerAction,
  });

  /// 网格 / 小图 / 列表（设置页可切）。
  ShelfViewMode get _view => AppStore.I.shelfView;

  /// 长按 → 确认对话框 → 移出。
  Future<void> _confirmRemove(BuildContext context, ShelfEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(removeLabel),
        content: Text('《${e.book.title}》'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(removeLabel),
          ),
        ],
      ),
    );
    if (ok == true) onRemove(e);
  }

  @override
  Widget build(BuildContext context) {
    if (entries.isEmpty) {
      return Center(
        child: Text(emptyHint, style: Theme.of(context).textTheme.bodyLarge),
      );
    }
    // 「清空」之类的头部操作，两种卡片样式都放在顶部右对齐
    return _grid(context, headerAction);
  }

  /// 卡片网格：长卡片 / 正方形卡片。
  ///
  /// 列宽与间距是**算出来**的，不是写死的：先按理想卡宽定列数，再把
  /// 剩余宽度均摊回卡片，保证「卡片间距 = 两侧留白」，横向永远正好铺满，
  /// 不会出现右边多一截空白或卡片被挤扁。
  Widget _grid(BuildContext context, Widget? top) {
    const gap = 10.0;
    const edge = 12.0;
    final square = _view == ShelfViewMode.square;

    return LayoutBuilder(
      builder: (context, box) {
        final avail = box.maxWidth - edge * 2;
        // 正方形卡片想放多大；长卡片一列占满整行
        final ideal =
            square ? (avail / 3.2).clamp(96.0, 168.0) : double.infinity;
        // 反推行数：卡片数 + 缝隙数 = 列数 + 1（两侧各一条）
        final cols = square ? (avail / (ideal + gap)).floor().clamp(1, 6) : 1;
        // 把富余/不足均摊到每张卡片，保证边距与间距完全相等
        final tileW = cols == 1 ? avail : (avail - gap * (cols - 1)) / cols;
        final tileH = square ? tileW * 1.34 : 96.0;

        return CustomScrollView(
          slivers: [
            if (top != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.only(right: 4),
                  child: Align(alignment: Alignment.centerRight, child: top),
                ),
              ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(edge, 4, edge, 28),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: cols,
                  mainAxisSpacing: gap,
                  crossAxisSpacing: gap,
                  mainAxisExtent: tileH,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) => _card(context, entries[i], tileW, square),
                  childCount: entries.length,
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 单张卡片。两种样式共用一套外壳，差别只在内部排布。
  Widget _card(BuildContext context, ShelfEntry e, double w, bool square) {
    final coverW = square ? w : 58.0;
    final coverH = square ? w * 1.16 : 78.0;
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => onOpen(e),
      onLongPress: () => _confirmRemove(context, e),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        decoration: BoxDecoration(
          color: square ? scheme.surface : scheme.surface,
          borderRadius: BorderRadius.circular(12),
          border:
              Border.all(color: scheme.outlineVariant.withValues(alpha: .5)),
        ),
        // 内边距随卡宽缩放，保证进度条两端始终离卡片边缘有余量，
        // 不会顶到边或溢出圆角
        padding: EdgeInsets.all(square ? 8 : 8),
        child: square
            ? _squareCard(context, e, coverW, coverH)
            : _wideCard(context, e, coverW, coverH),
      ),
    );
  }

  /// 正方形卡片：封面上、书名下、进度条压底。
  Widget _squareCard(BuildContext context, ShelfEntry e, double w, double h) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: CoverImage(
              url: e.book.cover,
              width: w,
              height: h,
              cacheWidth: (w * 2).round(),
              fallbackAsset: coverFallbackAsset(e.book.title),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          e.book.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.labelMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 3),
        _bar(context, e),
      ],
    );
  }

  /// 长卡片：左封面右信息，封面与正文两栏各自不透明，进度条只在右栏内。
  Widget _wideCard(BuildContext context, ShelfEntry e, double cw, double ch) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: CoverImage(
            url: e.book.cover,
            width: cw,
            height: ch,
            cacheWidth: (cw * 2.5).round(),
            fallbackAsset: coverFallbackAsset(e.book.title),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                e.book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall,
              ),
              if ((e.book.author ?? '').isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(
                  e.book.author!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 6),
              // 进度条放在 Expanded 里，右边界由卡片 padding 兜住
              _bar(context, e),
              const SizedBox(height: 3),
              Text(
                _progressLabel(e),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// 进度条：宽度受父级约束，末端再留 1px 视觉余量，避免贴死卡片边框。
  Widget _bar(BuildContext context, ShelfEntry e) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(
      builder: (context, box) {
        final w = (box.maxWidth - 1).clamp(0.0, box.maxWidth);
        return SizedBox(
          width: w,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: shelfProgressOf(e),
              minHeight: 4,
              backgroundColor: scheme.outlineVariant.withValues(alpha: .45),
            ),
          ),
        );
      },
    );
  }

  String _progressLabel(ShelfEntry e) {
    if (e.finished) return '已读完';
    if (e.chapterCount <= 0) {
      return e.chapterIndex > 0 ? '已读第 ${e.chapterIndex + 1} 章' : '未开始';
    }
    final pct = (shelfProgressOf(e) * 100).round();
    return '${e.chapterIndex + 1}/${e.chapterCount} 章 · $pct%';
  }
}
