import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/shelf_sort.dart';
import 'local/file_scan.dart';
import 'models.dart';
import 'sources/local_source.dart';
import 'sources/registry.dart';
import 'sources/source.dart';

/// 翻页方式。
enum PageMode {
  slide('滑动', '跟手横滑，惯性感'),
  cover('覆盖', '页面跟随手指推开，带前缘投影'),
  fade('淡入', '整页淡入淡出'),
  scroll('滚动', '上下滚动，长文更省事');

  const PageMode(this.label, this.hint);

  final String label;
  final String hint;

  static PageMode fromName(String? v) => PageMode.values
      .firstWhere((m) => m.name == v, orElse: () => PageMode.slide);
}

/// 阅读偏好。
class ReaderPrefs {
  double fontSize; // 逻辑像素
  double lineHeight; // 倍数
  int theme; // 0 锦绣白 1 极光黑
  PageMode pageMode; // 翻页方式（scroll = 上下滚动）
  int autoCache; // 自动缓存后续章节数（0 = 关闭）
  double ttsRate; // 听书语速
  double ttsPitch; // 听书音调（0.5~2.0）
  String ttsVoice; // 听书音色名（'' = 自动选中文）
  bool edgeNotice; // 在线朗读联网说明已读

  // ---- 排版（樱读融合）----
  double marginH; // 左右页边距（逻辑像素）
  double marginV; // 上下留白（逻辑像素）
  double letterSpacing; // 字距（逻辑像素）
  bool indentFirstLine; // 首行缩进两字
  int fontIndex; // 0 系统字体 1 霞鹜文楷
  bool showHeader; // 页眉：章节名
  bool showFooter; // 页脚：时间 / 页码 / 电量
  int bgIndex; // 阅读背景序号

  /// 兼容旧字段：`paginate=false` 等价于滚动模式。
  bool get paginate => pageMode != PageMode.scroll;

  ReaderPrefs({
    this.fontSize = 20,
    this.lineHeight = 1.7,
    this.theme = 0,
    this.pageMode = PageMode.slide,
    this.autoCache = 50,
    this.ttsRate = 0.5,
    this.ttsPitch = 1.0,
    this.ttsVoice = '',
    this.edgeNotice = false,
    this.marginH = 16,
    this.marginV = 12,
    this.letterSpacing = 0,
    this.indentFirstLine = false,
    this.fontIndex = 0,
    this.showHeader = true,
    this.showFooter = true,
    this.bgIndex = 0,
  });

  /// 排版相关字段变了就重排（阅读器据此决定是否重新分页）。
  String get layoutSignature =>
      '$fontSize|$lineHeight|$letterSpacing|$indentFirstLine|$fontIndex|'
      '$marginH|$marginV|${pageMode.name}|$bgIndex';
}

/// 全局状态：书架、历史、书签、偏好、章节离线缓存。
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore I = AppStore._();

  SharedPreferences? _sp;
  final ReaderPrefs prefs = ReaderPrefs();

  List<ShelfEntry> shelf = [];
  List<ShelfEntry> history = [];
  Map<String, List<Bookmark>> bookmarks = {};
  List<String> searchHistory = [];

  Directory? _cacheDir;
  bool inited = false;

  Future<void> init() async {
    if (inited) return;
    try {
      _sp = await SharedPreferences.getInstance();
    } catch (_) {
      _sp = null; // 持久化不可用时降级为内存态
    }
    final sp = _sp;
    if (sp != null) {
      prefs.fontSize = sp.getDouble('fontSize') ?? prefs.fontSize;
      prefs.lineHeight = sp.getDouble('lineHeight') ?? prefs.lineHeight;
      // 旧版三主题(0白天/1护眼/2夜间)迁移为两主题(0锦绣白/1极光黑)
      prefs.theme = (sp.getInt('theme') ?? 0) == 2 ? 1 : 0;
      // 翻页方式：新字段优先；老版本只有 paginate(bool)，false → 滚动
      final modeName = sp.getString('pageMode');
      if (modeName != null) {
        prefs.pageMode = PageMode.fromName(modeName);
      } else {
        prefs.pageMode =
            (sp.getBool('paginate') ?? true) ? PageMode.slide : PageMode.scroll;
      }
      prefs.autoCache = sp.getInt('autoCache') ?? prefs.autoCache;
      prefs.ttsRate = sp.getDouble('ttsRate') ?? prefs.ttsRate;
      prefs.ttsPitch = sp.getDouble('ttsPitch') ?? prefs.ttsPitch;
      prefs.ttsVoice = sp.getString('ttsVoice') ?? prefs.ttsVoice;
      prefs.edgeNotice = sp.getBool('edgeNotice') ?? prefs.edgeNotice;
      prefs.marginH = sp.getDouble('marginH') ?? prefs.marginH;
      prefs.marginV = sp.getDouble('marginV') ?? prefs.marginV;
      prefs.letterSpacing =
          sp.getDouble('letterSpacing') ?? prefs.letterSpacing;
      prefs.indentFirstLine =
          sp.getBool('indentFirstLine') ?? prefs.indentFirstLine;
      prefs.fontIndex = sp.getInt('fontIndex') ?? prefs.fontIndex;
      prefs.showHeader = sp.getBool('showHeader') ?? prefs.showHeader;
      prefs.showFooter = sp.getBool('showFooter') ?? prefs.showFooter;
      prefs.bgIndex = sp.getInt('bgIndex') ?? prefs.bgIndex;
      shelf = _loadList('shelf');
      history = _loadList('history');
      final bm = sp.getString('bookmarks');
      if (bm != null) {
        try {
          final m = jsonDecode(bm) as Map<String, dynamic>;
          bookmarks = m.map((k, v) => MapEntry(
              k, (v as List).map((e) => Bookmark.fromJson(e)).toList()));
        } catch (_) {}
      }
      searchHistory = sp.getStringList('searchHistory') ?? [];
      _shelfSort = shelfSortModeFrom(sp.getString('shelfSort'));
      _shelfAscending = sp.getBool('shelfAscending') ?? _shelfSort.defaultAscending;
      applyShelfSort();
    }
    try {
      _cacheDir = Directory(
          '${(await getApplicationSupportDirectory()).path}/novel_cache');
      if (!await _cacheDir!.exists()) {
        await _cacheDir!.create(recursive: true);
      }
    } catch (_) {
      _cacheDir = null;
    }
    inited = true;
  }

  List<ShelfEntry> _loadList(String key) {
    final s = _sp?.getString(key);
    if (s == null) return [];
    try {
      return (jsonDecode(s) as List)
          .map((e) => ShelfEntry.fromJson(e))
          .toList();
    } catch (_) {
      return [];
    }
  }

  void _save({
    bool notify = true,
    bool shelf = true,
    bool history = true,
    bool bookmarks = true,
  }) {
    // 按需编码：只写本次实际改动的键，避免滚动进度保存等高频路径
    // 每次都 jsonEncode + 写全部三份数据。
    // （同名参数遮蔽同名字段，静态方法体里通过闭包外的 getter 取实际列表）
    if (shelf) {
      _sp?.setString(
          'shelf', jsonEncode(this.shelf.map((e) => e.toJson()).toList()));
    }
    if (history) {
      _sp?.setString(
          'history', jsonEncode(this.history.map((e) => e.toJson()).toList()));
    }
    if (bookmarks) {
      _sp?.setString(
          'bookmarks',
          jsonEncode(this.bookmarks
              .map((k, v) => MapEntry(k, v.map((b) => b.toJson()).toList()))));
    }
    if (notify) notifyListeners();
  }

  // ---------- 书架排序 ----------

  ShelfSortMode _shelfSort = ShelfSortMode.recentRead;
  bool _shelfAscending = false;

  ShelfSortMode get shelfSort => _shelfSort;
  bool get shelfAscending => _shelfAscending;

  void setShelfSort(ShelfSortMode v) {
    _shelfSort = v;
    // 换排序方式时套用该方式的默认方向（书名升序、进度降序……）
    _shelfAscending = v.defaultAscending;
    _sp?.setString('shelfSort', v.name);
    _sp?.setBool('shelfAscending', _shelfAscending);
    notifyListeners();
  }

  void setShelfAscending(bool v) {
    _shelfAscending = v;
    _sp?.setBool('shelfAscending', v);
    notifyListeners();
  }

  /// 按当前排序设置整理书架（就地排序，不重新读盘）。
  void applyShelfSort() {
    sortShelf(shelf, _shelfSort, ascending: _shelfAscending);
    sortShelf(history, _shelfSort, ascending: _shelfAscending);
  }

  // ---------- 本地书 ----------
  /// 导入一本本地书（TXT / EPUB）。
  ///
  /// 解析文件拿到书名 / 作者 / 封面 / 章节数后进书架。返回 false 表示
  /// 解析失败或已在书架里 —— 调用方据此提示，不抛异常打断批量导入。
  Future<bool> importLocalBook(String path) async {
    if (inShelf(path)) return false;
    try {
      final data = await localSource.load(path);
      if (data.chapters.isEmpty) return false;
      final book = Book(
        sourceId: LocalSource.sourceId,
        id: path,
        url: path,
        title: data.title.isEmpty ? pathFileName(path) : data.title,
        author: data.author.isEmpty ? null : data.author,
        cover: data.coverPath.isEmpty ? null : data.coverPath,
        intro: data.intro.isEmpty ? null : data.intro,
      );
      addToShelf(book, chapterCount: data.chapters.length);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 丢弃本地书的解析缓存（文件被改动后调用，下次阅读重新解析）。
  void invalidateLocal([String? path]) => localSource.invalidate(path);

  // ---------- 阅读偏好 ----------


  void setFontSize(double v) {
    prefs.fontSize = v.clamp(12, 32).toDouble();
    _sp?.setDouble('fontSize', prefs.fontSize);
    notifyListeners();
  }

  void setLineHeight(double v) {
    prefs.lineHeight = v.clamp(1.2, 2.6).toDouble();
    _sp?.setDouble('lineHeight', prefs.lineHeight);
    notifyListeners();
  }

  void setTheme(int v) {
    prefs.theme = v == 1 ? 1 : 0;
    _sp?.setInt('theme', prefs.theme);
    notifyListeners();
  }

  void setPageMode(PageMode v) {
    prefs.pageMode = v;
    _sp?.setString('pageMode', v.name);
    // 旧字段同步写入，老版本回滚时仍能读懂
    _sp?.setBool('paginate', v != PageMode.scroll);
    notifyListeners();
  }

  /// 兼容旧调用点（设置页 / 阅读器面板的「翻页 ⇄ 滚动」开关）。
  void setPaginate(bool v) =>
      setPageMode(v ? PageMode.slide : PageMode.scroll);

  void setMarginH(double v) {
    prefs.marginH = v.clamp(0, 64).toDouble();
    _sp?.setDouble('marginH', prefs.marginH);
    notifyListeners();
  }

  void setMarginV(double v) {
    prefs.marginV = v.clamp(0, 160).toDouble();
    _sp?.setDouble('marginV', prefs.marginV);
    notifyListeners();
  }

  void setLetterSpacing(double v) {
    prefs.letterSpacing = v.clamp(-1, 8).toDouble();
    _sp?.setDouble('letterSpacing', prefs.letterSpacing);
    notifyListeners();
  }

  void setIndentFirstLine(bool v) {
    prefs.indentFirstLine = v;
    _sp?.setBool('indentFirstLine', v);
    notifyListeners();
  }

  void setFontIndex(int v) {
    prefs.fontIndex = v == 1 ? 1 : 0;
    _sp?.setInt('fontIndex', prefs.fontIndex);
    notifyListeners();
  }

  void setShowHeader(bool v) {
    prefs.showHeader = v;
    _sp?.setBool('showHeader', v);
    notifyListeners();
  }

  void setShowFooter(bool v) {
    prefs.showFooter = v;
    _sp?.setBool('showFooter', v);
    notifyListeners();
  }

  void setBgIndex(int v) {
    prefs.bgIndex = v;
    _sp?.setInt('bgIndex', v);
    notifyListeners();
  }

  void setAutoCache(int v) {
    prefs.autoCache = v;
    _sp?.setInt('autoCache', v);
    notifyListeners();
  }

  void setTtsRate(double v) {
    prefs.ttsRate = v.clamp(0.1, 1.0).toDouble();
    _sp?.setDouble('ttsRate', prefs.ttsRate);
    notifyListeners();
  }

  void setTtsPitch(double v) {
    prefs.ttsPitch = v.clamp(0.5, 2.0).toDouble();
    _sp?.setDouble('ttsPitch', prefs.ttsPitch);
    notifyListeners();
  }

  void setTtsVoice(String v) {
    prefs.ttsVoice = v;
    _sp?.setString('ttsVoice', v);
    notifyListeners();
  }

  void setEdgeNotice(bool v) {
    prefs.edgeNotice = v;
    _sp?.setBool('edgeNotice', v);
  }

  /// 听书在线合成音频缓存目录（<缓存>/tts）。
  /// clearCache 只删顶层文件，此子目录长期复用；失败返回 null。
  Future<Directory?> ttsAudioDir() async {
    final base = _cacheDir;
    if (base == null) return null;
    final d = Directory('${base.path}/tts');
    try {
      if (!await d.exists()) await d.create(recursive: true);
    } catch (_) {
      return null;
    }
    return d;
  }

  // ---------- 书架 / 历史 ----------

  ShelfEntry? shelfEntry(String bookUrl) {
    for (final e in shelf) {
      if (e.book.url == bookUrl) return e;
    }
    return null;
  }

  bool inShelf(String bookUrl) => shelfEntry(bookUrl) != null;

  void addToShelf(Book b, {int chapterCount = 0}) {
    if (inShelf(b.url)) return;
    final e = ShelfEntry(book: b);
    if (chapterCount > 0) e.chapterCount = chapterCount;
    shelf.insert(0, e);
    _save(history: false, bookmarks: false);
  }

  void removeFromShelf(String bookUrl) {
    shelf.removeWhere((e) => e.book.url == bookUrl);
    _save(history: false, bookmarks: false);
  }

  /// 记录已知总章节数（打开详情/目录翻页后调用，只增不减，防分页目录写入半截值）。
  void setChapterCount(String bookUrl, int count) {
    if (count <= 0) return;
    var changed = false;
    for (final list in [shelf, history]) {
      for (final e in list) {
        if (e.book.url == bookUrl && count > e.chapterCount) {
          e.chapterCount = count;
          changed = true;
        }
      }
    }
    if (changed) _save(bookmarks: false);
  }

  /// 更新阅读进度（同时写书架与历史）。
  /// [silent] = true 时不通知监听者（滚动中高频调用，避免整树重建）。
  void updateProgress(
    Book b, {
    required int chapterIndex,
    required String chapterTitle,
    int page = 0,
    int paragraph = 0,
    bool silent = false,
    int chapterCount = 0,
  }) {
    ShelfEntry upsert(List<ShelfEntry> list) {
      ShelfEntry? e;
      for (final x in list) {
        if (x.book.url == b.url) {
          e = x;
          break;
        }
      }
      e ??= ShelfEntry(book: b);
      if (chapterCount > e.chapterCount) e.chapterCount = chapterCount;
      e.book = b;
      e.chapterIndex = chapterIndex;
      e.chapterTitle = chapterTitle;
      e.page = page;
      e.paragraph = paragraph;
      e.updatedAt = DateTime.now();
      list.remove(e);
      list.insert(0, e);
      return e;
    }

    final h = upsert(history);
    final si = shelf.indexWhere((e) => e.book.url == b.url);
    if (si >= 0) {
      shelf.removeAt(si);
      shelf.insert(0, h);
    }
    if (history.length > 100) history.removeRange(100, history.length);
    _save(notify: !silent, bookmarks: false);
  }

  void clearHistory() {
    history.clear();
    _save(shelf: false, bookmarks: false);
  }

  void removeFromHistory(String bookUrl) {
    history.removeWhere((e) => e.book.url == bookUrl);
    _save(shelf: false, bookmarks: false);
  }

  // ---------- 搜索历史 ----------

  void pushSearch(String q) {
    q = q.trim();
    if (q.isEmpty) return;
    searchHistory.remove(q);
    searchHistory.insert(0, q);
    if (searchHistory.length > 20) searchHistory.removeRange(20, searchHistory.length);
    _sp?.setStringList('searchHistory', searchHistory);
    notifyListeners();
  }

  void clearSearchHistory() {
    searchHistory.clear();
    _sp?.setStringList('searchHistory', searchHistory);
    notifyListeners();
  }

  /// 外部直接改动列表后的手动刷新。
  void touch() => notifyListeners();

  // ---------- 书签 ----------

  List<Bookmark> bookmarksOf(String bookUrl) => bookmarks[bookUrl] ?? const [];

  void addBookmark(String bookUrl, Bookmark b) {
    final list = bookmarks.putIfAbsent(bookUrl, () => []);
    list.insert(0, b);
    _save(shelf: false, history: false);
  }

  void removeBookmark(String bookUrl, int index) {
    bookmarks[bookUrl]?.removeAt(index);
    _save(shelf: false, history: false);
  }

  // ---------- 章节离线缓存 ----------
  //
  // 每本书一个 JSON 文件：{detail..., "texts": {chapterUrl: [段落...]}}

  File? _bookFile(String bookUrl) {
    final dir = _cacheDir;
    if (dir == null) return null;
    final key = _hash(bookUrl);
    return File('${dir.path}/$key.json');
  }

  static String _hash(String s) {
    // FNV-1a 32bit，文件名安全
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }

  Future<Map<String, dynamic>> _loadBookJson(String bookUrl) async {
    final f = _bookFile(bookUrl);
    if (f == null || !await f.exists()) return {};
    try {
      return jsonDecode(await f.readAsString()) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveBookJson(String bookUrl, Map<String, dynamic> j) async {
    final f = _bookFile(bookUrl);
    if (f == null) return;
    try {
      await f.writeAsString(jsonEncode(j), flush: true);
    } catch (_) {}
  }

  /// 取章节正文：缓存优先，否则抓网并写缓存。
  Future<List<String>> chapterText(
    NovelSource src,
    BookDetail detail,
    Chapter ch,
  ) async {
    final j = await _loadBookJson(detail.book.url);
    final texts = (j['texts'] as Map<String, dynamic>?) ?? {};
    final hit = texts[ch.url];
    if (hit is List && hit.isNotEmpty) return hit.cast<String>();
    final paras = await src.fetchChapter(detail, ch);
    if (paras.isNotEmpty) texts[ch.url] = paras; // 空结果不入缓存（解析失败可重试）
    j['texts'] = texts;
    j['chapters'] = detail.chapters.map((c) => c.toJson()).toList();
    j['title'] = detail.book.title;
    await _saveBookJson(detail.book.url, j);
    return paras;
  }

  /// 已缓存的章节数。
  Future<int> cachedChapterCount(String bookUrl) async {
    final j = await _loadBookJson(bookUrl);
    final texts = (j['texts'] as Map<String, dynamic>?) ?? {};
    return texts.length;
  }

  /// 离线兜底：读取缓存的目录。
  Future<BookDetail?> cachedDetail(Book b) async {
    final j = await _loadBookJson(b.url);
    final chs = (j['chapters'] as List?)?.toList();
    if (chs == null || chs.isEmpty) return null;
    return BookDetail(
      book: b,
      chapters: chs
          .map((e) => Chapter.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  /// 下载整本书离线；[onProgress] (已完成, 总数)；返回是否全部完成。
  Future<bool> downloadBook(
    NovelSource src,
    BookDetail detail, {
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final j = await _loadBookJson(detail.book.url);
    final texts = (j['texts'] as Map<String, dynamic>?) ?? {};
    final total = detail.chapters.length;
    // ponytail: 目录/标题不变，循环外算一次；落盘每 5 章批量一次
    //（原每章整本 jsonEncode+flush，千章书 O(n²) 写放大），与 prefetchNext 一致。
    j['chapters'] = detail.chapters.map((c) => c.toJson()).toList();
    j['title'] = detail.book.title;
    for (var i = 0; i < total; i++) {
      if (cancelled?.call() ?? false) {
        j['texts'] = texts;
        await _saveBookJson(detail.book.url, j); // 取消时已下章节照常落盘
        return false;
      }
      final ch = detail.chapters[i];
      if (texts[ch.url] is List && (texts[ch.url] as List).isNotEmpty) {
        onProgress?.call(i + 1, total);
        continue;
      }
      try {
        final t = await src.fetchChapter(detail, ch);
        if (t.isNotEmpty) texts[ch.url] = t;
      } catch (_) {
        // 单章失败不中断整本下载
      }
      if (i % 5 == 4) {
        j['texts'] = texts;
        await _saveBookJson(detail.book.url, j);
      }
      onProgress?.call(i + 1, total);
    }
    j['texts'] = texts;
    await _saveBookJson(detail.book.url, j);
    return true;
  }

  // ---------- 自动预取后续章节 ----------

  int _prefetchGen = 0;

  /// 取消进行中的预取（切换章节/退出阅读器时调用）。
  void cancelPrefetch() => _prefetchGen++;

  /// 自动缓存从 [from] 章起的 [count] 章（仅抓未缓存的，网络失败即停）。
  /// ponytail: 预取与手动读章各自整本读改写同一 JSON，极端并发下可能互相覆盖，
  ///          单章丢失时重读一次即可，不引入文件锁。
  Future<void> prefetchNext(
    NovelSource src,
    BookDetail detail,
    int from,
    int count,
  ) async {
    if (count <= 0 || from >= detail.chapters.length) return;
    final gen = ++_prefetchGen;
    final j = await _loadBookJson(detail.book.url);
    final texts = (j['texts'] as Map<String, dynamic>?) ?? {};
    final end = (from + count).clamp(0, detail.chapters.length);
    for (var i = from; i < end; i++) {
      if (gen != _prefetchGen) return;
      final ch = detail.chapters[i];
      if (texts[ch.url] is List && (texts[ch.url] as List).isNotEmpty) {
        continue;
      }
      try {
        final t = await src.fetchChapter(detail, ch);
        if (t.isNotEmpty) texts[ch.url] = t;
      } catch (_) {
        return; // 网络中断/失败：停止预取，不刷屏重试
      }
      if (i % 5 == 4) {
        j['texts'] = texts;
        await _saveBookJson(detail.book.url, j); // 每5章落盘一次
      }
    }
    if (gen != _prefetchGen) return;
    j['texts'] = texts;
    j['chapters'] = detail.chapters.map((c) => c.toJson()).toList();
    j['title'] = detail.book.title;
    await _saveBookJson(detail.book.url, j);
  }

  /// 缓存目录占用字节数。
  Future<int> cacheSize() async {
    final dir = _cacheDir;
    if (dir == null || !await dir.exists()) return 0;
    var total = 0;
    await for (final f in dir.list()) {
      if (f is File) total += await f.length();
    }
    return total;
  }

  Future<void> clearCache() async {
    final dir = _cacheDir;
    if (dir == null || !await dir.exists()) return;
    await for (final f in dir.list()) {
      if (f is File) await f.delete();
    }
    notifyListeners();
  }
}
