import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'data/shelf_sort.dart';
import 'legado/models.dart';
import 'legado/source_store.dart';
import 'local/file_scan.dart';
import 'models.dart';
import 'pet/pet_event.dart';
import 'pet/pet_store.dart';
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

  // ---- 排版（旧版融合）----
  double marginH; // 左右页边距（逻辑像素）
  double marginV; // 上下留白（逻辑像素）
  double letterSpacing; // 字距（逻辑像素）
  bool indentFirstLine; // 首行缩进两字
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
    this.showHeader = true,
    this.showFooter = true,
    this.bgIndex = 0,
  });

  /// 排版相关字段变了就重排（阅读器据此决定是否重新分页）。
  String get layoutSignature =>
      '$fontSize|$lineHeight|$letterSpacing|$indentFirstLine|'
      '$marginH|$marginV|${pageMode.name}|$bgIndex';
}

/// 全局状态：书架、历史、书签、偏好、章节离线缓存。
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore I = AppStore._();

  SharedPreferences? _sp;

  /// 共享偏好句柄。新模块（桌宠等）直接复用这里的持久化，不必再开一套文件；
  /// 为空说明持久化不可用，调用方照常降级为内存态。
  SharedPreferences? get sp => _sp;

  final ReaderPrefs prefs = ReaderPrefs();

  List<ShelfEntry> shelf = [];
  List<ShelfEntry> history = [];
  Map<String, List<Bookmark>> bookmarks = {};
  List<String> searchHistory = [];

  Directory? _cacheDir;
  bool inited = false;

  /// 书源检测并发数（同时打几个书源）：慢 4 / 标准 8 / 极速 16。
  int checkConcurrency = 8;

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
      checkConcurrency = sp.getInt('sourceCheckConcurrency') ?? checkConcurrency;
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
      final su = sp.getString('shelfUpdates');
      if (su != null) {
        try {
          shelfUpdates = (jsonDecode(su) as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, (v as num).toInt()));
        } catch (_) {}
      }
      final luc = sp.getInt('shelfUpdateCheckAt');
      _lastUpdateCheck =
          luc == null ? null : DateTime.fromMillisecondsSinceEpoch(luc);
      final rs = sp.getStringList('recommendSources');
      if (rs != null) _recommendIds = rs.toSet(); // null=未配置=全部；[]=一个都不选
      _shelfSort = shelfSortModeFrom(sp.getString('shelfSort'));
      _shelfAscending =
          sp.getBool('shelfAscending') ?? _shelfSort.defaultAscending;
      _shelfView = shelfViewModeFrom(sp.getString('shelfView'));
      _punchHole = punchHoleFrom(sp.getString('punchHole'));
      // 轻量进度记录先覆盖回来（进程被杀时最后几页只写在 progress:* 里），
      // 再排序，保证「最近阅读」顺序与真实阅读时间一致。
      _applyProgressRecords(sp);
      applyShelfSort();
    }
    if (_cacheDir == null) {
      try {
        _cacheDir = Directory(
            '${(await getApplicationSupportDirectory()).path}/novel_cache');
        if (!await _cacheDir!.exists()) {
          await _cacheDir!.create(recursive: true);
        }
      } catch (_) {
        _cacheDir = null;
      }
    }
    inited = true;
  }

  /// 仅测试用：跳过 path_provider，把离线缓存指到临时目录。
  @visibleForTesting
  void debugSetCacheDir(Directory? d) {
    _cacheDir = d;
    _metaFut.clear();
    _metaSig.clear();
    // 章节内存缓存与在途表也跟着清：换测试目录等于换一本书，
    // 否则上一个用例读到的正文会从内存里「糊」到新用例上。
    _memChapter.clear();
    _memOrder.clear();
    _inflightChapter.clear();
    _fgChapterLoads = 0;
    _prefetchGen++;
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
          jsonEncode(this
              .bookmarks
              .map((k, v) => MapEntry(k, v.map((b) => b.toJson()).toList()))));
    }
    if (notify) notifyListeners();
  }

  // ---------- 轻量进度记录 ----------
  //
  // 每翻一页只写一条 ~120B 的 `progress:<hash>`；书架 / 历史两份完整列表
  // 只在「换章 / 章节数变化 / 首次入历史」这类低频事件时整体落盘。
  // SharedPreferences 每次 setString 都会重写整份 XML，所以这里真正的收益是
  // 「每页少编码少写两份大 JSON」，写盘体积与书量无关。

  static const String _kProgress = 'progress:';

  String _progressKey(String bookUrl) => '$_kProgress${_hash(bookUrl)}';

  /// 启动时把 `progress:*` 覆盖回 shelf / history（上次进程被杀时最后几页只在
  /// 进度记录里）。整表落盘的那份时间戳更新时以整表为准。
  void _applyProgressRecords(SharedPreferences sp) {
    for (final k in sp.getKeys()) {
      if (!k.startsWith(_kProgress)) continue;
      final raw = sp.getString(k);
      if (raw == null || raw.isEmpty) continue;
      Map<String, dynamic>? rec;
      try {
        final dec = jsonDecode(raw);
        if (dec is Map<String, dynamic>) rec = dec;
      } catch (_) {
        continue;
      }
      if (rec == null) continue;
      final url = rec['u'];
      if (url is! String) continue;
      final ts = (rec['ts'] as num?)?.toInt() ?? 0;
      for (final list in [shelf, history]) {
        for (final e in list) {
          if (e.book.url != url) continue;
          if (ts > 0 && ts < e.updatedAt.millisecondsSinceEpoch) continue;
          final c = (rec['c'] as num?)?.toInt();
          if (c != null && c >= 0) e.chapterIndex = c;
          final t = rec['t'];
          if (t is String && t.isNotEmpty) e.chapterTitle = t;
          final p = (rec['p'] as num?)?.toInt();
          if (p != null) e.page = p;
          final o = (rec['o'] as num?)?.toInt();
          if (o != null) e.paragraph = o;
          final n = (rec['n'] as num?)?.toInt();
          if (n != null && n > e.chapterCount) e.chapterCount = n;
          if (ts > 0) e.updatedAt = DateTime.fromMillisecondsSinceEpoch(ts);
        }
      }
    }
  }

  /// 把内存里的书架 / 历史整体落盘。离开阅读器、App 进后台时各调一次即可，
  /// 不必每翻页都写。
  void flushProgress() => _save(notify: false, bookmarks: false);

  // ---------- 书架排序 ----------

  ShelfSortMode _shelfSort = ShelfSortMode.recentRead;
  bool _shelfAscending = false;
  ShelfViewMode _shelfView = ShelfViewMode.wide;

  /// 屏幕挖孔位置，桌宠据此绕开摄像头。
  PunchHole _punchHole = PunchHole.none;

  ShelfSortMode get shelfSort => _shelfSort;
  bool get shelfAscending => _shelfAscending;
  ShelfViewMode get shelfView => _shelfView;
  PunchHole get punchHole => _punchHole;

  void setPunchHole(PunchHole v) {
    _punchHole = v;
    _sp?.setString('punchHole', v.name);
    notifyListeners();
  }

  void setShelfView(ShelfViewMode v) {
    _shelfView = v;
    _sp?.setString('shelfView', v.name);
    notifyListeners();
    _pet(PetAction.shelfView);
  }

  /// 排序 / 视图切换的下一档（书架页右上角一键循环）。
  void cycleShelfView() {
    final i = ShelfViewMode.values.indexOf(_shelfView);
    setShelfView(ShelfViewMode.values[(i + 1) % ShelfViewMode.values.length]);
  }

  void setShelfSort(ShelfSortMode v) {
    _shelfSort = v;
    // 换排序方式时套用该方式的默认方向（书名升序、进度降序……）
    _shelfAscending = v.defaultAscending;
    _sp?.setString('shelfSort', v.name);
    _sp?.setBool('shelfAscending', _shelfAscending);
    notifyListeners();
    _pet(PetAction.shelfSort);
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
      _pet(PetAction.importLocal);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 丢弃本地书的解析缓存（文件被改动后调用，下次阅读重新解析）。
  void invalidateLocal([String? path]) => localSource.invalidate(path);

  // ---------- 阅读偏好 ----------

  /// 通知桌宠「用户改了 X」。所有偏好都走这里，所以联动只写一次。
  void _pet(PetAction a) => PetStore.I.emit(a);

  void setFontSize(double v) {
    prefs.fontSize = v.clamp(12, 32).toDouble();
    _sp?.setDouble('fontSize', prefs.fontSize);
    notifyListeners();
    _pet(PetAction.fontSizeChange);
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
    _pet(PetAction.themeChange);
  }

  void setPageMode(PageMode v) {
    prefs.pageMode = v;
    _sp?.setString('pageMode', v.name);
    // 旧字段同步写入，老版本回滚时仍能读懂
    _sp?.setBool('paginate', v != PageMode.scroll);
    notifyListeners();
    _pet(PetAction.pageModeChange);
  }

  /// 兼容旧调用点（设置页 / 阅读器面板的「翻页 ⇄ 滚动」开关）。
  void setPaginate(bool v) => setPageMode(v ? PageMode.slide : PageMode.scroll);

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

  void setShowHeader(bool v) {
    prefs.showHeader = v;
    _sp?.setBool('showHeader', v);
    notifyListeners();
    _pet(PetAction.settingChange);
  }

  void setShowFooter(bool v) {
    prefs.showFooter = v;
    _sp?.setBool('showFooter', v);
    notifyListeners();
    _pet(PetAction.settingChange);
  }

  void setBgIndex(int v) {
    prefs.bgIndex = v;
    _sp?.setInt('bgIndex', v);
    notifyListeners();
    _pet(PetAction.backgroundChange);
  }

  void setAutoCache(int v) {
    prefs.autoCache = v;
    _sp?.setInt('autoCache', v);
    notifyListeners();
    _pet(PetAction.settingChange);
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
    _pet(PetAction.settingChange);
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
    if (shelfUpdates.remove(bookUrl) != null) _saveUpdates();
    _save(history: false, bookmarks: false);
    _pet(PetAction.shelfRemove);
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
    // 基线前进 = 用户看过最新目录：追更角标一并清掉
    if (changed) {
      if (shelfUpdates.remove(bookUrl) != null) _saveUpdates();
      _save(bookmarks: false);
    }
  }

  /// 更新阅读进度（同时写书架与历史）。
  ///
  /// 章内翻页是高频路径：只写一条轻量进度记录（[flushProgress] 会在离开
  /// 阅读器时把整表补写一次），换章/章节数变化/首次入历史才重写两份大列表。
  /// [silent] = true 时连监听都不通知（滚动模式每 600ms 一次）。
  void updateProgress(
    Book b, {
    required int chapterIndex,
    required String chapterTitle,
    int page = 0,
    int paragraph = 0,
    bool silent = false,
    int chapterCount = 0,
  }) {
    ShelfEntry? prev;
    for (final e in history) {
      if (e.book.url == b.url) {
        prev = e;
        break;
      }
    }
    prev ??= shelfEntry(b.url);
    final prevIdx = prev?.chapterIndex ?? -1;
    final prevCount = prev?.chapterCount ?? 0;
    final prevTitle = prev?.chapterTitle ?? '';

    var created = false;
    ShelfEntry upsert(List<ShelfEntry> list) {
      ShelfEntry? e;
      for (final x in list) {
        if (x.book.url == b.url) {
          e = x;
          break;
        }
      }
      if (e == null) {
        e = ShelfEntry(book: b);
        created = true;
      }
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
    // 阅读进度带着更大的章节数 = 详情已刷新：追更角标视为已读
    if (h.chapterCount > prevCount && shelfUpdates.remove(b.url) != null) {
      _saveUpdates();
    }
    final si = shelf.indexWhere((e) => e.book.url == b.url);
    if (si >= 0) {
      shelf.removeAt(si);
      shelf.insert(0, h);
    }
    if (history.length > 100) history.removeRange(100, history.length);

    // 1) 轻量记录：一条 ~120B 的小 JSON，与书量无关
    _sp?.setString(
      _progressKey(b.url),
      jsonEncode({
        'u': b.url,
        'c': chapterIndex,
        't': chapterTitle,
        'p': page,
        'o': paragraph,
        'n': h.chapterCount,
        'ts': h.updatedAt.millisecondsSinceEpoch,
      }),
    );

    // 2) 整表落盘：只在低频变化时做
    final chapterChanged = created ||
        prevIdx != chapterIndex ||
        prevCount != h.chapterCount ||
        prevTitle != chapterTitle;
    if (chapterChanged) {
      _save(notify: !silent, bookmarks: false);
    }
    // 章内翻页（prevPage/prevPara 变了、章名没变）不落盘也不通知：
    // 书架页展示的章名没变化，没必要重建整棵树；进度已在上面存好。
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
    if (searchHistory.length > 20) {
      searchHistory.removeRange(20, searchHistory.length);
    }
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
    _pet(PetAction.addBookmark);
  }

  void removeBookmark(String bookUrl, int index) {
    bookmarks[bookUrl]?.removeAt(index);
    _save(shelf: false, history: false);
    _pet(PetAction.removeBookmark);
  }

  // ---------- 章节离线缓存 ----------
  //
  // 一章一文件（命中路径只读一个小 JSON，不再整本解析）：
  //   novel_cache/<bookHash>.json           目录 + 书名（旧版同路径，含 texts 时自动迁移）
  //   novel_cache/<bookHash>/<chHash>.json  单章 {"u": chapterUrl, "p": [段落...]}
  // 文件名用 chapterUrl 的哈希，文件内再存一份 url：哈希撞车时当作未命中，不会串章。

  File? _bookFile(String bookUrl) {
    final dir = _cacheDir;
    if (dir == null) return null;
    return File('${dir.path}/${_hash(bookUrl)}.json');
  }

  Directory? _bookDir(String bookUrl) {
    final dir = _cacheDir;
    if (dir == null) return null;
    return Directory('${dir.path}/${_hash(bookUrl)}');
  }

  Future<Directory?> _ensureBookDir(String bookUrl) async {
    final d = _bookDir(bookUrl);
    if (d == null) return null;
    try {
      if (!await d.exists()) await d.create(recursive: true);
      return d;
    } catch (_) {
      return null;
    }
  }

  File _chapterFile(Directory dir, String chapterUrl) =>
      File('${dir.path}/${_hash(chapterUrl)}.json');

  static String _hash(String s) {
    // FNV-1a 32bit，文件名安全
    var h = 0x811c9dc5;
    for (final b in utf8.encode(s)) {
      h ^= b;
      h = (h * 0x01000193) & 0x7fffffff;
    }
    return h.toRadixString(16);
  }

  final Map<String, Future<Map<String, dynamic>>> _metaFut = {};
  final Map<String, String> _metaSig = {};

  /// 目录元数据（含旧布局迁移；每本书每进程只解析一次）。
  Future<Map<String, dynamic>> _meta(String bookUrl) =>
      _metaFut.putIfAbsent(bookUrl, () => _readMeta(bookUrl));

  Future<Map<String, dynamic>> _readMeta(String bookUrl) async {
    var m = <String, dynamic>{};
    final f = _bookFile(bookUrl);
    if (f != null) {
      try {
        if (await f.exists()) {
          final raw = await f.readAsString();
          final dec = raw.isEmpty ? null : jsonDecode(raw);
          if (dec is Map<String, dynamic>) m = dec;
        }
      } catch (_) {
        m = <String, dynamic>{};
      }
    }
    // 旧布局迁移：整本 texts → 一章一文件，再把不带 texts 的目录写回
    final legacy = m.remove('texts');
    if (legacy is Map && legacy.isNotEmpty) {
      final dir = await _ensureBookDir(bookUrl);
      if (dir != null) {
        for (final e in legacy.entries) {
          final v = e.value;
          if (v is! List || v.isEmpty) continue;
          final url = e.key.toString();
          final cf = _chapterFile(dir, url);
          try {
            if (await cf.exists()) continue;
            await cf.writeAsString(jsonEncode({'u': url, 'p': v}), flush: true);
          } catch (_) {}
        }
        await _writeMeta(bookUrl, m);
      }
    }
    _metaSig[bookUrl] = _sigOf(m);
    return m;
  }

  String _sigOf(Map<String, dynamic> m) =>
      _sigOfParts(m['title']?.toString(), (m['chapters'] as List?) ?? const []);

  /// 目录签名：书名 + 章数 + 首末章地址。任何一项变了才值得重写目录文件。
  String _sigOfParts(String? title, List<dynamic> chs) {
    final n = chs.length;
    String urlAt(int i) {
      final e = chs[i];
      return e is Map ? (e['url']?.toString() ?? '') : '';
    }

    final first = n == 0 ? '' : urlAt(0);
    final last = n == 0 ? '' : urlAt(n - 1);
    return '${title ?? ''}|$n|$first|$last';
  }

  Future<void> _writeMeta(String bookUrl, Map<String, dynamic> m) async {
    final f = _bookFile(bookUrl);
    if (f == null) return;
    try {
      final copy = Map<String, dynamic>.from(m)..remove('texts');
      await f.writeAsString(jsonEncode(copy), flush: true);
      _metaSig[bookUrl] = _sigOf(copy);
    } catch (_) {}
  }

  /// 记住目录 / 书名；内容没变就不写盘（千章目录 ≈150 KB，不能每章重写）。
  Future<void> _rememberDetail(BookDetail detail) async {
    final url = detail.book.url;
    final m = await _meta(url);
    final chs = detail.chapters.map((c) => c.toJson()).toList();
    final sig = _sigOfParts(detail.book.title, chs);
    if (_metaSig[url] == sig) return;
    m['title'] = detail.book.title;
    m['chapters'] = chs;
    await _writeMeta(url, m);
    _metaSig[url] = sig;
  }

  Future<List<String>?> _readChapter(String bookUrl, String chUrl) async {
    final dir = _bookDir(bookUrl);
    if (dir == null) return null;
    try {
      final f = _chapterFile(dir, chUrl);
      if (!await f.exists()) return null;
      final dec = jsonDecode(await f.readAsString());
      if (dec is! Map || dec['u'] != chUrl) return null; // 哈希撞车 → 当未命中
      final p = dec['p'];
      if (p is! List || p.isEmpty) return null;
      return p.map((e) => e.toString()).toList();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeChapter(
      String bookUrl, String chUrl, List<String> paras) async {
    final dir = await _ensureBookDir(bookUrl);
    if (dir == null) return;
    try {
      await _chapterFile(dir, chUrl)
          .writeAsString(jsonEncode({'u': chUrl, 'p': paras}), flush: true);
    } catch (_) {}
  }

  Future<bool> _hasChapter(String bookUrl, String chUrl) async {
    final dir = _bookDir(bookUrl);
    if (dir == null) return false;
    try {
      return await _chapterFile(dir, chUrl).exists();
    } catch (_) {
      return false;
    }
  }

  // ---------- 章节正文：内存缓存 + 在途去重 ----------
  //
  // 「切下一章有时候要等很久」的根因不是网速，是同一章被抓了两次：后台预取
  // 正在抓第 N+1 章，用户翻页时前台又发一遍第 N+1 章，两个请求在同一个站点
  // / IP 上互相拖，还各自跑一遍书源 JS。现在两者共用同一个 Future。

  /// 最近读过的章节正文（内存 LRU）：翻回上一章、来回跳转零延迟。
  static const int _memChapterMax = 8;
  final Map<String, List<String>> _memChapter = {};
  final List<String> _memOrder = [];

  /// 在途章节请求：`bookUrl|chUrl` → Future（预取与前台共用，只发一次）。
  final Map<String, Future<List<String>>> _inflightChapter = {};
  int _fgChapterLoads = 0;

  /// 前台正在取章节正文（预取据此让路，别抢站点限速）。
  bool get chapterBusy => _fgChapterLoads > 0;

  static String _chKey(String bookUrl, String chUrl) => '$bookUrl|$chUrl';

  List<String>? _memGet(String key) {
    final hit = _memChapter[key];
    if (hit == null) return null;
    _memOrder.remove(key);
    _memOrder.add(key); // 命中挪到队尾，淘汰最久没读的那章
    return hit;
  }

  void _memPut(String key, List<String> paras) {
    if (paras.isEmpty) return;
    _memChapter[key] = paras;
    _memOrder.remove(key);
    _memOrder.add(key);
    while (_memOrder.length > _memChapterMax) {
      _memChapter.remove(_memOrder.removeAt(0));
    }
  }

  /// 取章节正文：内存 → 磁盘 → 网络（同一章同时只会有一个网络请求在飞）。
  ///
  /// [background] = 后台预取：不计入「前台忙」，不抢占前台请求。
  Future<List<String>> chapterText(
    NovelSource src,
    BookDetail detail,
    Chapter ch, {
    bool background = false,
  }) async {
    final key = _chKey(detail.book.url, ch.url);
    final mem = _memGet(key);
    if (mem != null) return mem;
    final pend = _inflightChapter[key];
    if (pend != null) return pend; // 预取已经在抓这一章：搭车，别再发一遍
    final fut = _chapterTextInner(src, detail, ch, key, background);
    _inflightChapter[key] = fut;
    try {
      return await fut;
    } finally {
      if (identical(_inflightChapter[key], fut)) _inflightChapter.remove(key);
    }
  }

  Future<List<String>> _chapterTextInner(
    NovelSource src,
    BookDetail detail,
    Chapter ch,
    String key,
    bool background,
  ) async {
    final bookUrl = detail.book.url;
    await _meta(bookUrl); // 顺带完成旧布局迁移（每本每进程一次）
    final hit = await _readChapter(bookUrl, ch.url);
    if (hit != null) {
      _memPut(key, hit);
      return hit;
    }
    if (!background) _fgChapterLoads++;
    try {
      final paras = await src.fetchChapter(detail, ch);
      if (paras.isNotEmpty) {
        _memPut(key, paras);
        await _writeChapter(bookUrl, ch.url, paras); // 空结果不入缓存（可重试）
      }
      await _rememberDetail(detail);
      return paras;
    } finally {
      if (!background) _fgChapterLoads--;
    }
  }

  /// 已缓存的章节数。
  Future<int> cachedChapterCount(String bookUrl) async {
    await _meta(bookUrl);
    final dir = _bookDir(bookUrl);
    if (dir == null) return 0;
    var n = 0;
    try {
      await for (final e in dir.list()) {
        if (e is File && e.path.endsWith('.json')) n++;
      }
    } catch (_) {}
    return n;
  }

  /// 读取已缓存的章节正文（书内搜索用）：chapterUrl → 段落数组。
  Future<Map<String, List<String>>> cachedTexts(String bookUrl) async {
    await _meta(bookUrl);
    final out = <String, List<String>>{};
    final dir = _bookDir(bookUrl);
    if (dir == null) return out;
    try {
      await for (final e in dir.list()) {
        if (e is! File || !e.path.endsWith('.json')) continue;
        try {
          final dec = jsonDecode(await e.readAsString());
          if (dec is! Map) continue;
          final u = dec['u'];
          final p = dec['p'];
          if (u is! String || p is! List || p.isEmpty) continue;
          out[u] = p.map((x) => x.toString()).toList();
        } catch (_) {}
      }
    } catch (_) {}
    return out;
  }

  // ---------- 推荐页书源 ----------

  /// 参与推荐的书源 id 集合；null = 未配置 = 全部，{} = 一个都不选。
  /// 固化源用 NovelSource.id，导入源用 bookSourceUrl（= LegadoSource.id）。
  Set<String>? _recommendIds;

  /// 推荐来源变更信号：推荐页只听它，不被书架进度等无关通知带偏。
  final ValueNotifier<int> recommendChanged = ValueNotifier<int>(0);

  bool get recommendAll => _recommendIds == null;

  /// [id] 是否参与推荐（未配置时一律参与）。
  bool recommendOn(String id) => _recommendIds?.contains(id) ?? true;

  /// 首次改动前把「全部」展开成显式全集 ——
  /// 否则取消一个就退化成「谁都不选」。
  Set<String> _allSourceIds() => {
        for (final s in builtinSources) s.id,
        for (final s in SourceStore.shared?.enabled ?? const <BookSource>[])
          s.bookSourceUrl,
      };

  /// 勾选 / 取消一个书源参与推荐。[all] 时恢复为「全部参与」。
  void setRecommendOn(String id, bool v, {bool all = false}) {
    Set<String> s;
    if (all) {
      s = v ? <String>{id} : _allSourceIds();
    } else {
      s = _recommendIds ?? _allSourceIds();
      if (v) {
        s.add(id);
      } else {
        s.remove(id);
      }
    }
    _recommendIds = s;
    _saveRecommend();
    recommendChanged.value++;
    notifyListeners();
  }

  /// [v]=true 全选（回到未配置态），false 一个都不选。
  void setRecommendAll(bool v) {
    _recommendIds = v ? null : <String>{};
    _saveRecommend();
    recommendChanged.value++;
    notifyListeners();
  }

  void _saveRecommend() {
    final ids = _recommendIds;
    if (ids == null) {
      _sp?.remove('recommendSources');
    } else {
      _sp?.setStringList('recommendSources', ids.toList());
    }
  }

  /// 书源检测并发数（1..32）。
  void setCheckConcurrency(int v) {
    checkConcurrency = v.clamp(1, 32);
    _sp?.setInt('sourceCheckConcurrency', checkConcurrency);
    notifyListeners();
  }

  // ---------- 追更红点 ----------

  /// 书架追更角标：bookUrl → 新增章节数（自上次打开以来）。
  Map<String, int> shelfUpdates = {};
  bool checkingUpdates = false;
  DateTime? _lastUpdateCheck;

  /// 自动检查的最小间隔；手动按钮不受它限制。
  static const Duration kUpdateCheckMinInterval = Duration(hours: 6);

  /// 距上次检查是否已超过间隔（书架页进屏时据此决定要不要自动补一刀）。
  bool get updateCheckDue {
    final last = _lastUpdateCheck;
    return last == null ||
        DateTime.now().difference(last) >= kUpdateCheckMinInterval;
  }

  void _saveUpdates() {
    _sp?.setString('shelfUpdates', jsonEncode(shelfUpdates));
  }

  /// 检查书架连载更新：逐本拉最新目录，对比已知章节数。
  ///
  /// 返回 (更新书数, 新增章节数, 检查失败数)。跳过本地书与没有基线
  /// （从没打开过详情）的书；网络失败单本不拖垮整轮。5 本并发一轮，
  /// 兼顾速度与对书源的礼貌。
  Future<(int, int, int)> checkShelfUpdates() async {
    if (checkingUpdates) return (0, 0, 0);
    checkingUpdates = true;
    notifyListeners();
    var updated = 0, newCh = 0, failed = 0;
    try {
      final targets = shelf
          .where((e) =>
              e.book.sourceId != LocalSource.sourceId && e.chapterCount > 0)
          .toList();
      for (var i = 0; i < targets.length; i += 5) {
        final chunk = targets.skip(i).take(5);
        await Future.wait(chunk.map((e) async {
          final src = sourceById(e.book.sourceId);
          if (src == null) return; // 书源已删：静默跳过
          try {
            final d = await src.fetchDetail(e.book);
            final remote = d.chapters.length;
            final known = e.chapterCount;
            if (remote > known) {
              shelfUpdates[e.book.url] = remote - known;
              updated++;
              newCh += remote - known;
            } else if (shelfUpdates.remove(e.book.url) != null) {
              // 远端不再有超出已知的章节：清掉过期角标
            }
          } catch (_) {
            failed++;
          }
        }));
      }
      _lastUpdateCheck = DateTime.now();
      _sp?.setInt(
          'shelfUpdateCheckAt', _lastUpdateCheck!.millisecondsSinceEpoch);
      _saveUpdates();
      notifyListeners();
    } finally {
      checkingUpdates = false;
      notifyListeners();
    }
    if (updated > 0) _pet(PetAction.shelfUpdate);
    return (updated, newCh, failed);
  }

  /// 离线兜底：读取缓存的目录。
  Future<BookDetail?> cachedDetail(Book b) async {
    final m = await _meta(b.url);
    final chs = (m['chapters'] as List?)?.toList();
    if (chs == null || chs.isEmpty) return null;
    return BookDetail(
      book: b,
      chapters:
          chs.map((e) => Chapter.fromJson(e as Map<String, dynamic>)).toList(),
    );
  }

  /// 下载整本书离线；[onProgress] (已完成, 总数)；返回是否全部完成。
  ///
  /// 一章一文件，无需批量落盘：已存在的章节直接跳过（文件存在即命中）。
  Future<bool> downloadBook(
    NovelSource src,
    BookDetail detail, {
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    final bookUrl = detail.book.url;
    final total = detail.chapters.length;
    await _rememberDetail(detail); // 目录先落盘（不变则不写）
    for (var i = 0; i < total; i++) {
      if (cancelled?.call() ?? false) return false; // 已下章节各自成文件，无需补写
      final ch = detail.chapters[i];
      if (await _hasChapter(bookUrl, ch.url)) {
        onProgress?.call(i + 1, total);
        continue;
      }
      try {
        final t = await src.fetchChapter(detail, ch);
        if (t.isNotEmpty) await _writeChapter(bookUrl, ch.url, t);
      } catch (_) {
        // 单章失败不中断整本下载
      }
      onProgress?.call(i + 1, total);
    }
    return true;
  }

  // ---------- 自动预取后续章节 ----------

  int _prefetchGen = 0;

  /// 取消进行中的预取（切换章节/退出阅读器时调用）。
  void cancelPrefetch() => _prefetchGen++;

  /// 自动缓存从 [from] 章起的 [count] 章（仅抓未缓存的，网络失败即停）。
  ///
  /// 自己不直接发请求，走 [chapterText] 的「在途去重」：用户翻到该章时是搭
  /// 同一个请求，不会再抓一遍。前台正在取正文时让路（站点按 IP 限速，抢道
  /// 会让「下一章」明显变慢），且每抓一章歇 250 ms，给前台留出余量。
  Future<void> prefetchNext(
    NovelSource src,
    BookDetail detail,
    int from,
    int count,
  ) async {
    if (count <= 0 || from >= detail.chapters.length) return;
    final gen = ++_prefetchGen;
    final bookUrl = detail.book.url;
    final end = (from + count).clamp(0, detail.chapters.length);
    for (var i = from; i < end; i++) {
      if (gen != _prefetchGen) return;
      final ch = detail.chapters[i];
      if (_memChapter.containsKey(_chKey(bookUrl, ch.url))) continue;
      if (await _hasChapter(bookUrl, ch.url)) continue;
      // 前台在抓正文：先让路（最多等 4s，之后照常预取，不卡死自己）
      for (var w = 0; w < 40 && chapterBusy && gen == _prefetchGen; w++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      if (gen != _prefetchGen) return;
      final sw = Stopwatch()..start();
      try {
        await chapterText(src, detail, ch, background: true);
      } catch (_) {
        return; // 网络中断/失败：停止预取，不刷屏重试
      }
      sw.stop();
      // 慢源（WebView 渲染 / 站点按 IP 限速）预取一章就收手：一次灌几十章会把
      // 隐藏 WebView 队列和站点限速占满，反而让「下一章」排在后面等。
      if (sw.elapsedMilliseconds > 2000) return;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    if (gen != _prefetchGen) return;
    await _rememberDetail(detail);
  }

  /// 缓存目录占用字节数（含各书章节子目录）。
  Future<int> cacheSize() async {
    final dir = _cacheDir;
    if (dir == null || !await dir.exists()) return 0;
    var total = 0;
    try {
      await for (final e in dir.list(recursive: true, followLinks: false)) {
        if (e is File) total += await e.length();
      }
    } catch (_) {}
    return total;
  }

  Future<void> clearCache() async {
    final dir = _cacheDir;
    if (dir == null || !await dir.exists()) return;
    try {
      await for (final e in dir.list()) {
        // tts 音频子目录长期复用（见 ttsAudioDir），清缓存不动它
        if (e is Directory && (e.path.endsWith('${Platform.pathSeparator}tts'))) {
          continue;
        }
        try {
          await e.delete(recursive: true);
        } catch (_) {}
      }
    } catch (_) {}
    _metaFut.clear(); // 目录与章节都已删掉，别拿旧缓存糊回去
    _metaSig.clear();
    notifyListeners();
  }
}
