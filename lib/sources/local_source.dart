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
import 'dart:isolate';

import '../dom.dart';
import '../local/epub_parser.dart';
import '../local/txt_parser.dart';
import '../models.dart';
import 'source.dart';

/// 一本已解析好的本地书。
///
/// 正文按需取：TXT 只留「整篇文本 + 各章字符区间」，EPUB 只留「各章文本」。
/// 旧实现在解析时就把每章切成段落列表，等于把整本书在内存里存了两份；
/// 现在 [chapterParagraphs] 每次现切一章（几 KB，微秒级）。
class LocalBookData {
  LocalBookData._({
    required this.title,
    required this.author,
    required this.intro,
    required this.chapters,
    required this.coverPath,
    this.chapterDepths,
    String? text,
    List<int>? starts,
    List<int>? ends,
    List<String>? chapterTexts,
  })  : _text = text,
        _starts = starts,
        _ends = ends,
        _chapterTexts = chapterTexts;

  final String title;
  final String author;
  final String intro;

  /// 章节标题（与正文同序）。
  final List<String> chapters;

  /// 章节层级（EPUB 多级目录：0=卷，>0=章；null=不分层）。
  final List<int>? chapterDepths;

  /// 封面图片本地路径（无封面时为空串）。
  final String coverPath;

  final String? _text;
  final List<int>? _starts;
  final List<int>? _ends;
  final List<String>? _chapterTexts;

  static const String _ls = '\n';

  /// 第 [i] 章的段落（越界返回空）。
  List<String> chapterParagraphs(int i) {
    final t = _text;
    if (t != null) {
      final starts = _starts!;
      if (i < 0 || i >= starts.length) return const [];
      return t.substring(starts[i], _ends![i]).split(_ls);
    }
    final cs = _chapterTexts!;
    if (i < 0 || i >= cs.length) return const [];
    return cs[i].split(_ls);
  }
}

/// 本地书源：把文件系统里的 TXT / EPUB 变成可读的书。
class LocalSource extends NovelSource {
  LocalSource({Directory? cacheDir}) : _cacheDir = cacheDir;

  /// 解析结果缓存：路径 → 解析好的书。EPUB 解压很贵，必须缓存。
  ///
  /// ponytail: 只留最近 3 本，够覆盖「当前书 + 书架里来回切」；
  /// 真要同时读更多，换成按访问时间淘汰的 LinkedHashMap 即可。
  final Map<String, LocalBookData> _cache = {};
  static const int _cacheMax = 3;

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
          Chapter(
            title: data.chapters[i],
            url: chapterUrl(book.url, i),
            depth: data.chapterDepths?[i],
          ),
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
    return cleanParas(data.chapterParagraphs(chapterIndexOf(chapter.url)));
  }

  /// 解析（或复用缓存）。
  ///
  /// 解压 / 解码 / 分章都在分身里做：一本 5 MB 的 TXT 光解码 + 切章就能卡住
  /// 首帧几百毫秒，EPUB 更久；不搬到后台，导入和首次打开都像「点不动」。
  Future<LocalBookData> load(String path) async {
    final hit = _cache[path];
    if (hit != null) return hit;
    final file = File(path);
    if (!await file.exists()) {
      throw Exception('文件不存在：${_fileName(path)}');
    }
    // 只跨 isolate 传字符串：Directory / File 不能发。
    final dirPath = _cacheDir?.path;
    final data = await Isolate.run(() => parseLocalBookFile((path, dirPath)));
    _cache[path] = data;
    while (_cache.length > _cacheMax) {
      _cache.remove(_cache.keys.first);
    }
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

  /// 由文件路径造一个 [Book]（导入时用）。
  static Book bookForPath(String path, {String? title, String? cover}) => Book(
        sourceId: sourceId,
        id: path,
        url: path,
        title: title ?? _fileName(path),
        cover: cover,
      );

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

}

/// 分身前解析入口：(文件路径, 封面输出目录)。
///
/// 顶层函数 + 只收字符串，`Isolate.run` 才能原样把闭包发过去。
LocalBookData parseLocalBookFile((String, String?) args) {
  final (path, cacheDirPath) = args;
  final lower = path.toLowerCase();
  return lower.endsWith('.epub')
      ? _parseEpubFile(path, cacheDirPath)
      : _parseTxtFile(path);
}

LocalBookData _parseTxtFile(String path) {
  final r = TxtParser.parseBytes(File(path).readAsBytesSync());
  final head = r.text.substring(0, r.text.length.clamp(0, 4000));
  return LocalBookData._(
    title: LocalSource._fileName(path),
    author: LocalSource._guessField(head, '作者'),
    intro: LocalSource._guessField(head, '简介'),
    chapters: [for (final c in r.chapters) c.title],
    starts: [for (final c in r.chapters) c.start],
    ends: [for (final c in r.chapters) c.end],
    text: r.text,
    coverPath: '',
  );
}

LocalBookData _parseEpubFile(String path, String? cacheDirPath) {
  final r = EpubParser.parse(File(path).readAsBytesSync());
  var coverPath = '';
  final bytes = r.coverBytes;
  if (bytes != null && bytes.isNotEmpty && cacheDirPath != null) {
    coverPath = _writeCover(
        cacheDirPath, '${LocalSource._hash(path)}.${r.coverExtension}', bytes);
  }
  return LocalBookData._(
    title: r.meta.title.isEmpty ? LocalSource._fileName(path) : r.meta.title,
    author: r.meta.author,
    intro: r.meta.intro,
    chapters: [for (final c in r.chapters) c.title],
    chapterDepths: [for (final c in r.chapters) c.depth],
    chapterTexts: _chapterTexts(r.chapters, path, cacheDirPath),
    coverPath: coverPath,
  );
}

/// 每章正文里的插图：落盘后把占位标记改写成**本地绝对路径**，
/// 阅读器才能直接 `Image.file` 显示（标记格式见 [EpubParser.imageMarkerPrefix]）。
///
/// 文件名带章序号：不同章可能各有一张 `image001.jpg`，不带序号会互相覆盖，
/// 结果就是「翻到第 3 章却显示第 1 章的图」。
List<String> _chapterTexts(
    List<EpubChapter> chapters, String bookPath, String? cacheDirPath) {
  if (cacheDirPath == null) return [for (final c in chapters) c.text];
  final imgDir = '$cacheDirPath${Platform.pathSeparator}epub_img'
      '${Platform.pathSeparator}${LocalSource._hash(bookPath)}';
  final out = <String>[];
  for (var i = 0; i < chapters.length; i++) {
    final c = chapters[i];
    var t = c.text;
    for (final img in c.images) {
      final saved = _writeImage(imgDir, '${i}_${img.name}', img.bytes);
      if (saved.isEmpty) continue;
      t = t.replaceAll(
        '${EpubParser.imageMarkerPrefix}${img.name}${EpubParser.imageMarkerSuffix}',
        '${EpubParser.imageMarkerPrefix}$saved${EpubParser.imageMarkerSuffix}',
      );
    }
    out.add(t);
  }
  return out;
}

/// 插图落盘（分身里调用；失败就保留「［插图］」占位）。
String _writeImage(String dirPath, String name, List<int> bytes) {
  try {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final out = File('$dirPath${Platform.pathSeparator}$name');
    out.writeAsBytesSync(bytes, flush: true);
    return out.path;
  } catch (_) {
    return '';
  }
}

/// 封面落盘（分身里调用；写不出去不影响正文）。
String _writeCover(String dirPath, String name, List<int> bytes) {
  try {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final out = File('$dirPath/$name');
    out.writeAsBytesSync(bytes, flush: true);
    return out.path;
  } catch (_) {
    return '';
  }
}
