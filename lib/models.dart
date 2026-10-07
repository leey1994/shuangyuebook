/// 数据模型：书籍、章节、排行、书单等。
library;

class Book {
  final String sourceId;
  final String id;
  final String url;
  final String title;
  final String? author;
  final String? cover;
  final String? intro;
  final String? status;
  final String? latest;

  const Book({
    required this.sourceId,
    required this.id,
    required this.url,
    required this.title,
    this.author,
    this.cover,
    this.intro,
    this.status,
    this.latest,
  });

  Map<String, dynamic> toJson() => {
        'sourceId': sourceId,
        'id': id,
        'url': url,
        'title': title,
        'author': author,
        'cover': cover,
        'intro': intro,
        'status': status,
        'latest': latest,
      };

  factory Book.fromJson(Map<String, dynamic> j) => Book(
        sourceId: j['sourceId'] as String,
        id: j['id'] as String,
        url: j['url'] as String,
        title: j['title'] as String,
        author: j['author'] as String?,
        cover: j['cover'] as String?,
        intro: j['intro'] as String?,
        status: j['status'] as String?,
        latest: j['latest'] as String?,
      );
}

class Chapter {
  final String title;
  final String url;
  const Chapter({required this.title, required this.url});

  Map<String, dynamic> toJson() => {'title': title, 'url': url};
  factory Chapter.fromJson(Map<String, dynamic> j) =>
      Chapter(title: j['title'] as String, url: j['url'] as String);
}

class BookDetail {
  final Book book;
  final List<Chapter> chapters;
  final String? nextChaptersUrl; // 章节目录还有下一页
  const BookDetail({
    required this.book,
    required this.chapters,
    this.nextChaptersUrl,
  });
}

/// 带分页链接的列表结果；nextUrl 为 null 表示没有更多。
class Paged<T> {
  final List<T> items;
  final String? nextUrl;
  const Paged({required this.items, this.nextUrl});
}

class RankTab {
  final String title;
  final String url;
  const RankTab({required this.title, required this.url});

  Map<String, dynamic> toJson() => {'title': title, 'url': url};
  factory RankTab.fromJson(Map<String, dynamic> j) =>
      RankTab(title: j['title'] as String, url: j['url'] as String);
}

class BooklistEntry {
  final String title;
  final String url;
  final String? intro;
  final String? date;
  const BooklistEntry({
    required this.title,
    required this.url,
    this.intro,
    this.date,
  });

  Map<String, dynamic> toJson() =>
      {'title': title, 'url': url, 'intro': intro, 'date': date};
  factory BooklistEntry.fromJson(Map<String, dynamic> j) => BooklistEntry(
        title: j['title'] as String,
        url: j['url'] as String,
        intro: j['intro'] as String?,
        date: j['date'] as String?,
      );
}

class Booklist {
  final String title;
  final List<String> paragraphs;
  final List<Book> books;
  const Booklist({
    required this.title,
    required this.paragraphs,
    required this.books,
  });
}

/// 书架/历史条目。
class ShelfEntry {
  Book book;
  int chapterIndex;
  int chapterCount; // 已知总章节数（打开详情后写入，0 = 未知）
  String chapterTitle;
  int page; // 章内页码（滚动模式恒为 0）
  int paragraph; // 滚动模式锚点段落
  DateTime updatedAt;
  bool finished;

  ShelfEntry({
    required this.book,
    this.chapterIndex = 0,
    this.chapterCount = 0,
    this.chapterTitle = '',
    this.page = 0,
    this.paragraph = 0,
    DateTime? updatedAt,
    this.finished = false,
  }) : updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'book': book.toJson(),
        'chapterIndex': chapterIndex,
        'chapterCount': chapterCount,
        'chapterTitle': chapterTitle,
        'page': page,
        'paragraph': paragraph,
        'updatedAt': updatedAt.toIso8601String(),
        'finished': finished,
      };

  factory ShelfEntry.fromJson(Map<String, dynamic> j) => ShelfEntry(
        book: Book.fromJson(j['book'] as Map<String, dynamic>),
        chapterIndex: j['chapterIndex'] as int? ?? 0,
        chapterCount: j['chapterCount'] as int? ?? 0,
        chapterTitle: j['chapterTitle'] as String? ?? '',
        page: j['page'] as int? ?? 0,
        paragraph: j['paragraph'] as int? ?? 0,
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? '') ??
            DateTime.now(),
        finished: j['finished'] as bool? ?? false,
      );
}

class Bookmark {
  final int chapterIndex;
  final int page;
  final int paragraph;
  final String chapterTitle;
  final String snippet;
  final DateTime createdAt;
  Bookmark({
    required this.chapterIndex,
    this.page = 0,
    this.paragraph = 0,
    required this.chapterTitle,
    required this.snippet,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  Map<String, dynamic> toJson() => {
        'chapterIndex': chapterIndex,
        'page': page,
        'paragraph': paragraph,
        'chapterTitle': chapterTitle,
        'snippet': snippet,
        'createdAt': createdAt.toIso8601String(),
      };

  factory Bookmark.fromJson(Map<String, dynamic> j) => Bookmark(
        chapterIndex: j['chapterIndex'] as int,
        page: j['page'] as int? ?? 0,
        paragraph: j['paragraph'] as int? ?? 0,
        chapterTitle: j['chapterTitle'] as String? ?? '',
        snippet: j['snippet'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ??
            DateTime.now(),
      );
}
