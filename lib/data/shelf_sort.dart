// 书架排列：排序方式 / 显示方式 定义 + 比较与排序工具。
//
// 数据源是爽阅自己的 [ShelfEntry]（不是樱读的 Book）：书架条目已经带
// 阅读进度、更新时间与累计字数，直接拿来排序即可，不必再维护一份书籍模型。
import '../models.dart';
import 'natural_sort.dart';

/// 书架排序方式。
enum ShelfSortMode {
  recentRead('最近阅读'),
  addedTime('添加时间'),
  title('书名'),
  author('作者'),
  progress('阅读进度'),
  chars('字数');

  const ShelfSortMode(this.label);

  final String label;

  /// 该方式的默认排序方向（true = 正序 / 升序）。
  ///
  /// - 最近阅读 / 添加时间：新的在前 → 降序；
  /// - 书名 / 作者：A→Z 顺读 → 升序；
  /// - 阅读进度 / 字数：多的在前 → 降序。
  bool get defaultAscending => switch (this) {
        ShelfSortMode.recentRead => false,
        ShelfSortMode.addedTime => false,
        ShelfSortMode.title => true,
        ShelfSortMode.author => true,
        ShelfSortMode.progress => false,
        ShelfSortMode.chars => false,
      };
}

/// 书架卡片样式：长卡片 / 正方形卡片。
enum ShelfViewMode {
  wide('长卡片'),
  square('正方形卡片');

  const ShelfViewMode(this.label);

  final String label;
}

/// 存储字符串 → 排序方式（未知 / 空回退「最近阅读」）。
ShelfSortMode shelfSortModeFrom(String? value) => switch (value) {
      'addedTime' => ShelfSortMode.addedTime,
      'title' => ShelfSortMode.title,
      'author' => ShelfSortMode.author,
      'progress' => ShelfSortMode.progress,
      'chars' => ShelfSortMode.chars,
      _ => ShelfSortMode.recentRead,
    };

/// 存储字符串 → 显示方式（未知 / 空回退「长卡片」）。
ShelfViewMode shelfViewModeFrom(String? value) => switch (value) {
      'square' => ShelfViewMode.square,
      _ => ShelfViewMode.wide,
    };

/// 进度比例（0~1）。总章数未知时按已读章数封顶，至少给一点进度。
double shelfProgressOf(ShelfEntry e) {
  if (e.finished) return 1;
  if (e.chapterCount <= 0) return e.chapterIndex > 0 ? 0.02 : 0;
  return ((e.chapterIndex + 1) / e.chapterCount).clamp(0.0, 1.0);
}

/// 按 [mode] 的升序语义比较两条书架记录（负值 = a 在前）。
///
/// 升 / 降序由调用方统一翻转（见 [sortShelf]）。
int compareShelf(ShelfEntry a, ShelfEntry b, ShelfSortMode mode) {
  switch (mode) {
    case ShelfSortMode.recentRead:
      // 没读过的新书用「添加时间」兜底
      final x = a.updatedAt;
      final y = b.updatedAt;
      return x.compareTo(y);
    case ShelfSortMode.addedTime:
      return a.addedAt.compareTo(b.addedAt);
    case ShelfSortMode.title:
      return naturalCompare(a.book.title, b.book.title);
    case ShelfSortMode.author:
      final aAuthor = a.book.author ?? '';
      final bAuthor = b.book.author ?? '';
      // 佚名（无作者）偏后
      final aEmpty = aAuthor.trim().isEmpty;
      final bEmpty = bAuthor.trim().isEmpty;
      if (aEmpty != bEmpty) return aEmpty ? 1 : -1;
      final c = naturalCompare(aAuthor, bAuthor);
      return c != 0 ? c : naturalCompare(a.book.title, b.book.title);
    case ShelfSortMode.progress:
      final c = shelfProgressOf(a).compareTo(shelfProgressOf(b));
      return c != 0 ? c : naturalCompare(a.book.title, b.book.title);
    case ShelfSortMode.chars:
      final c = a.charCount.compareTo(b.charCount);
      return c != 0 ? c : naturalCompare(a.book.title, b.book.title);
  }
}

/// 按 [mode] + 方向排序书架列表（原地）。
void sortShelf(
  List<ShelfEntry> entries,
  ShelfSortMode mode, {
  required bool ascending,
}) {
  entries.sort((a, b) {
    final c = compareShelf(a, b, mode);
    return ascending ? c : -c;
  });
}
