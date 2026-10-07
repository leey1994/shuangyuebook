import 'package:flutter/material.dart';

import '../models.dart';
import '../store.dart';
import '../widgets.dart';
import 'reader_screen.dart';

/// 书架 + 阅读历史。
class ShelfScreen extends StatelessWidget {
  const ShelfScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('书架'),
          bottom: const TabBar(tabs: [Tab(text: '书架'), Tab(text: '历史')]),
        ),
        body: ListenableBuilder(
          listenable: AppStore.I,
          builder: (context, _) {
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

/// 阅读进度行：进度条 + 已读/总章数（总章数未知时只显示已读章）。
Widget _progressLine(BuildContext context, ShelfEntry e) {
  final theme = Theme.of(context);
  final read = e.chapterIndex + 1;
  if (e.finished) {
    return Text('已读完 · 共 $read 章',
        style: theme.textTheme.labelMedium
            ?.copyWith(color: theme.colorScheme.primary));
  }
  final total = e.chapterCount;
  final unread = e.chapterTitle.isEmpty && e.chapterIndex == 0;
  if (total <= 0) {
    if (unread) {
      return Text('未开始阅读',
          style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor));
    }
    final t = e.chapterTitle.isEmpty ? '' : ' · ${e.chapterTitle}';
    return Text('已读第 $read 章$t',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.labelMedium);
  }
  if (unread) {
    // 未开始：空进度条 + 总章数，不误显示「已读第 1 章」。
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: 0,
              minHeight: 6,
              backgroundColor: theme.hintColor.withValues(alpha: 0.18),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Text('共 $total 章 · 未开始', style: theme.textTheme.labelMedium),
      ],
    );
  }
  final pct = (read / total).clamp(0.0, 1.0);
  return Row(
    children: [
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 6,
            backgroundColor: theme.hintColor.withValues(alpha: 0.18),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('$read/$total 章 · ${(pct * 100).toStringAsFixed(0)}%',
          style: theme.textTheme.labelMedium
              ?.copyWith(color: theme.colorScheme.primary)),
    ],
  );
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
    return ListView.builder(
      itemCount: entries.length + (headerAction != null ? 1 : 0),
      itemBuilder: (context, i) {
        if (headerAction != null) {
          if (i == 0) {
            return Align(alignment: Alignment.centerRight, child: headerAction);
          }
          i -= 1;
        }
        final e = entries[i];
        return Dismissible(
          key: ValueKey(e.book.url),
          direction: DismissDirection.endToStart,
          background: Container(
            color: Colors.red.shade400,
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: 16),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) => onRemove(e),
          child: BookTile(
            book: e.book,
            extra: _progressLine(context, e),
            onTap: () => onOpen(e),
            onLongPress: () => _confirmRemove(context, e),
          ),
        );
      },
    );
  }
}
