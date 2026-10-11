import 'package:flutter/material.dart';

import '../data/format.dart';
import '../models.dart';
import '../store.dart';
import 'reader_screen.dart';

/// 书签总览：汇总所有书里的书签，按时间倒序，点击跳回阅读位置。
class BookmarksPage extends StatelessWidget {
  const BookmarksPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('书签')),
      body: ListenableBuilder(
        listenable: AppStore.I,
        builder: (context, _) {
          final books = _bookLookup();
          final items = _collect();
          if (items.isEmpty) {
            return Center(
              child:
                  Text('还没有书签', style: Theme.of(context).textTheme.bodyLarge),
            );
          }
          return ListView.separated(
            itemCount: items.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) =>
                _row(context, items[i], books[items[i].url]),
          );
        },
      ),
    );
  }

  /// 书架 + 历史 → 书 url → Book。书签可能在两处都不存在（书被移出了）。
  static Map<String, Book> _bookLookup() {
    final map = <String, Book>{};
    for (final e in [...AppStore.I.shelf, ...AppStore.I.history]) {
      map[e.book.url] = e.book;
    }
    return map;
  }

  /// 展平全部书签并按创建时间倒序。保留各自在原列表里的下标，删除时要用。
  static List<({String url, int index, Bookmark bm})> _collect() {
    final out = <({String url, int index, Bookmark bm})>[];
    AppStore.I.bookmarks.forEach((url, list) {
      for (var i = 0; i < list.length; i++) {
        out.add((url: url, index: i, bm: list[i]));
      }
    });
    out.sort((a, b) => b.bm.createdAt.compareTo(a.bm.createdAt));
    return out;
  }

  Widget _row(BuildContext context, ({String url, int index, Bookmark bm}) item,
      Book? book) {
    final theme = Theme.of(context);
    final bm = item.bm;
    final gone = book == null;
    return ListTile(
      title: Text(
        gone ? '书籍已移出' : '《${book.title}》',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.titleMedium
            ?.copyWith(color: gone ? theme.disabledColor : null),
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(bm.chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium),
          if (bm.snippet.isNotEmpty) ...[
            const SizedBox(height: 2),
            Text(bm.snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall),
          ],
          const SizedBox(height: 2),
          Text(timeAgo(bm.createdAt.millisecondsSinceEpoch),
              style: theme.textTheme.labelSmall),
        ],
      ),
      isThreeLine: true,
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: '删除书签',
        onPressed: () => _confirmRemove(context, item),
      ),
      onTap: gone ? null : () => _open(context, item, book),
      onLongPress: () => _confirmRemove(context, item),
    );
  }

  void _open(BuildContext context, ({String url, int index, Bookmark bm}) item,
      Book book) {
    final nav = Navigator.of(context);
    nav.pop();
    nav.push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        book: book,
        chapterIndex: item.bm.chapterIndex,
        page: item.bm.page,
        paragraph: item.bm.paragraph,
      ),
    ));
  }

  Future<void> _confirmRemove(
      BuildContext context, ({String url, int index, Bookmark bm}) item) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除书签'),
        content: Text(item.bm.chapterTitle),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('取消')),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    AppStore.I.removeBookmark(item.url, item.index);
  }
}
