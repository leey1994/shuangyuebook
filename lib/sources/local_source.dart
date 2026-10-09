// 本地书适配器：把 TXT / EPUB 文件包装成爽阅的 [NovelSource]。
//
// 为什么还是走 [NovelSource]：爽阅的搜索 / 书架 / 阅读器 / 换源 / 离线缓存
// 全都只认这个接口。只要本地书也长成 NovelSource，就自动继承
// 「读到哪缓存到哪」、预取后续章节、批量下载整本、书签、统计 —— 一行都不用改。
//
// 约定：
//   本地书的 [Book.url] 就是文件绝对路径，[Book.sourceId] 固定为 `local`；
//   同一路径只解析一次并缓存（EPUB 解压 + 分章不便宜，不能每次翻页重跑）。
import 'dart:io';

import '../dom.dart';
import '../local/epub_parser.dart';
import '../local/txt_parser.dart';
import '../models.dart';
import 'source.dart';

/// 一本已解析好的本地书（章节 → 段落）。
class LocalBookData {
  LocalBookData({
    required this.title,
    required this.author,
    required this.chapters,
    required this.paragraphs,
    required this.coverPath,
    this.intro = '',
  });

  final String title;
  final String author;
  final String intro;

  /// 章节标题（与 [chapters] 同序）。
  final List<String> chapters;

  /// 章节 → 段落列表。
  final List<List<String>> paragraphs;

  /// 封面图片本地路径（无封面时为空串）。
  final String coverPath;
}

/// 本地书源：把文件系统里的 TXT / EPUB 变成可读的书。
class LocalSource extends NovelSource {
  LocalSource({Directory? cacheDir}) : _cacheDir = cacheDir;

  /// 解析结果缓存：路径 → 解析好的书。EPUB 解压很贵，必须缓存。
  final Map<String, LocalBookData> _cache = {};

  /// 封面等衍生文件的存放目录（由 AppStore 注入；null 则不落盘）。
  final Directory? _cacheDir;

  static const String sourceId = 'local';

  /// 进程内共享实例（[syncImportedSources] 会把它并进 allSources）。
  static LocalSource? shared;

  @override
  String get id => sourceId;

  @override
  String get name => '本地书';

  @override
  String get baseUrl => '';

  /// 本地书没有站点首页。
  @override
  Future<List<Book>> fetchHome() async => const [];

  @override
  Future<List<RankTab>> fetchRankTabs() async => const [];

  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  /// 本地书按路径查书，不参与多源搜索。
  @override
  Future<List<Book>> search(String query) async => const [];

  /// 基类 [NovelSource.fetchChapter] 的取文钩子 —— 本类已整体覆盖
  /// fetchChapter（走本地文件解析），此钩子走不到；留空仅为满足抽象接口。
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  /// 解析文件 → 目录。
  ///
  /// 章节 url 用 `<文件路径>#<序号>` 而不是裸路径：AppStore 的离线缓存以
  /// 章 url 为键，若所有章共用一个 url 会互相覆盖（只剩最后一章有内容）。
  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final data = await load(book.url);
    if (data.chapters.isEmpty) {
      throw Exception('这本书没有可读章节');
    }
    return BookDetail(
      book: Book(
        sourceId: sourceId,
        id: book.url,
        url: book.url,
        title: data.title.isEmpty ? _fileName(book.url) : data.title,
        author: data.author.isEmpty ? null : data.author,
        cover: data.coverPath.isEmpty ? null : data.coverPath,
        intro: data.intro.isEmpty ? null : data.intro,
      ),
      chapters: [
        for (var i = 0; i < data.chapters.length; i++)
          Chapter(title: data.chapters[i], url: chapterUrl(book.url, i)),
      ],
    );
  }

  /// 章节 url：`<文件路径>#<章节序号>`。
  static String chapterUrl(String bookPath, int index) => '$bookPath#$index';

  /// 从章节 url 反解出章节序号（取不到按 0）。
  static int chapterIndexOf(String chapterUrl) {
    final i = chapterUrl.lastIndexOf('#');
    if (i < 0) return 0;
    return int.tryParse(chapterUrl.substring(i + 1)) ?? 0;
  }

  /// 取章节正文：章节序号 → 段落。
  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    final data = await load(detail.book.url);
    final i = chapterIndexOf(chapter.url);
    if (i < 0 || i >= data.paragraphs.length) return const [];
    return cleanParas(data.paragraphs[i]);
  }

  /// 解析（或复用缓存）。
  Future<LocalBookData> load(String path) async {
    final hit = _cache[path];
    if (hit != null) return hit;
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在：${_fileName(path)}');
    }
    final lower = path.toLowerCase();
    final data = lower.endsWith('.epub')
        ? await _parseEpub(file)
        : await _parseTxt(file);
    _cache[path] = data;
    return data;
  }

  /// 清空解析缓存（导入新书 / 删书后调用，避免读到旧内容）。
  void invalidate([String? path]) {
    if (path == null) {
      _cache.clear();
    } else {
      _cache.remove(path);
    }
  }

  Future<LocalBookData> _parseTxt(File f) async {
    final bytes = await f.readAsBytes();
    final r = TxtParser.parseBytes(bytes);
    final paras = <List<String>>[
      for (final c in r.chapters)
        r.text.substring(c.start, c.end).split('\n')
    ];
    // 作者：正文前 20 行里找「作者：xxx」
    final head = r.text.substring(0, r.text.length.clamp(0, 4000));
    return LocalBookData(
      title: _fileName(f.path),
      author: _guessField(head, '作者'),
      intro: _guessField(head, '简介'),
      chapters: [for (final c in r.chapters) c.title],
      paragraphs: paras,
      coverPath: '',
    );
  }

  Future<LocalBookData> _parseEpub(File f) async {
    final r = EpubParser.parse(await f.readAsBytes());
    var coverPath = '';
    final bytes = r.coverBytes;
    if (bytes != null && bytes.isNotEmpty) {
      coverPath = await _writeCover(
          '${_hash(f.path)}.${r.coverExtension}', bytes);
    }
    return LocalBookData(
      title: r.meta.title.isEmpty ? _fileName(f.path) : r.meta.title,
      author: r.meta.author,
      intro: r.meta.intro,
      chapters: [for (final c in r.chapters) c.title],
      paragraphs: [for (final c in r.chapters) c.text.split('\n')],
      coverPath: coverPath,
    );
  }

  Future<String> _writeCover(String name, List<int> bytes) async {
    final dir = _cacheDir;
    if (dir == null) return '';
    try {
      if (!await dir.exists()) await dir.create(recursive: true);
      final out = File('${dir.path}/$name');
      await out.writeAsBytes(bytes, flush: true);
      return out.path;
    } catch (_) {
      return ''; // 封面写不出去不影响正文
    }
  }

  /// 正文头部找「作者：xxx」这类字段。
  static String _guessField(String head, String key) {
    final m = RegExp('$key\\s*[:：]\\s*(.{1,40})').firstMatch(head);
    if (m == null) return '';
    return m.group(1)!.trim();
  }

  static String _fileName(String path) {
    final i = path.lastIndexOf(RegExp(r'[/\\]'));
    final name = i >= 0 ? path.substring(i + 1) : path;
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(0, dot) : name;
  }

  /// FNV-1a，生成文件名安全的短哈希。
  static String _hash(String s) {
    var h = 0x811c9dc5;
    for (final b in s.codeUnits) {
      h ^= b;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }

  /// 由文件路径造一个 [Book]（导入时用）。
  static Book bookForPath(String path, {String? title, String? cover}) => Book(
        sourceId: sourceId,
        id: path,
        url: path,
        title: title ?? _fileName(path),
        cover: cover,
      );
}
