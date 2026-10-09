// 「阅读 3.0（Legado）」书源适配器：把 JSON 书源包装成爽阅的 [NovelSource]。
//
// 为什么要有这一层：
//   爽阅的 11 个固化书源是手写 Dart 适配器（[NovelSource] 的实现类），
//   搜索 / 发现 / 书架 / 阅读器 / 换源 全都只认这个接口。
//   如果让 Legado 引擎另起一套数据通路，就得把上面每个页面都改一遍。
//   这里把 JSON 书源适配成同一个接口 —— **固化书源与导入书源从此完全同构**：
//   上层一行都不用改，两者也能进同一次搜索、同一个书架、同一次换源。
//
// 能力映射（Legado 规则 → NovelSource 方法）：
//   search          ← searchUrl + ruleSearch
//   fetchDetail     ← ruleBookInfo + ruleToc
//   fetchChapter    ← ruleContent（书源可标记走隐藏 WebView）
//   fetchRankTabs   ← exploreUrl 分类
//   fetchRank       ← ruleExplore（空则回退 ruleSearch）
//   fetchHome / 书单 ← 无对应概念，返回空
//
// 离线缓存不在这里做：AppStore.chapterText() 对所有 [NovelSource] 一视同仁，
// Legado 书源因此自动继承爽阅既有的每书 JSON 缓存、断点续传与批量下载。
import '../dom.dart';
import '../legado/models.dart';
import '../legado/online_book_service.dart';
import '../legado/online_repo.dart';
import '../legado/source_store.dart';
import '../models.dart';
import 'source.dart';

/// 一个 Legado 书源（内置 JSON 书源或用户导入的书源）。
class LegadoSource extends NovelSource {
  LegadoSource(this.source, {OnlineRepo? repo, OnlineBookService? service})
      : _repo = repo,
        _service = service;

  final BookSource source;

  /// 书源仓库（可选注入；不传则按本源现造一个免 I/O 的）。
  final OnlineRepo? _repo;

  /// 详情 / 目录 / 正文服务。
  final OnlineBookService? _service;

  late final OnlineBookService _svc = _service ?? OnlineBookService();

  /// 只含本源、且不做任何磁盘 I/O 的仓库（initial 传入即不会 load/save）。
  late final OnlineRepo _r =
      _repo ?? OnlineRepo(store: SourceStore(initial: [source]));

  /// 本源是否支持发现页（有可静态解析的 exploreUrl）。
  bool get hasExplore => OnlineRepo.parseExploreCategories(source).isNotEmpty;

  /// 本源 exploreUrl 是否为 JS 脚本（静态解析不了，发现页会明确提示）。
  bool get exploreNeedsJs => OnlineRepo.hasJsExplore(source);

  @override
  String get id => source.bookSourceUrl;

  @override
  String get name => source.bookSourceName.isEmpty
      ? source.bookSourceUrl
      : source.bookSourceName;

  @override
  String get baseUrl => source.bookSourceUrl;

  /// 「首页推荐」← 本源第一个发现分类的前 [homePerSource] 本。
  ///
  /// Legado 书源没有真正的站点首页概念，但它的 `exploreUrl` 第一个分类
  /// （通常是「玄幻」「热门」之类）就是该源当下最像推荐榜的一页。
  /// 只取前几条，避免单个源在聚合推荐里刷屏。
  @override
  Future<List<Book>> fetchHome() async {
    if (!hasExplore) return const [];
    try {
      final cat = OnlineRepo.parseExploreCategories(source).first;
      final res = await _r.exploreSource(source, cat);
      if (res.error != null) return const [];
      return [
        for (final b in res.books.take(homePerSource)) _toBook(b),
      ];
    } catch (_) {
      return const []; // 单源失败不影响聚合
    }
  }

  /// 每个导入书源在聚合推荐里最多贡献几本。
  ///
  /// 只限导入源、不限固化源：导入源可能有几十个，不设限会把「发现」页
  /// 撑爆并拖慢聚合；固化源就 10 个且一直是原样，保持既有观感。
  static const int homePerSource = 5;

  /// Legado 书源没有「书单中心」概念。
  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);

  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      const Booklist(title: '', paragraphs: [], books: []);

  /// 发现页分类 ← exploreUrl（`标题::地址` / JSON 数组两种写法都支持）。
  @override
  Future<List<RankTab>> fetchRankTabs() async => [
        for (final c in OnlineRepo.parseExploreCategories(source))
          RankTab(title: c.title, url: c.url),
      ];

  /// 分类书单 ← ruleExplore（缺失时引擎内部回退 ruleSearch）。
  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async {
    final cats = OnlineRepo.parseExploreCategories(source);
    if (cats.isEmpty) return const Paged(items: []);
    final cat = cats.firstWhere(
      (c) => c.url == tab.url || c.title == tab.title,
      orElse: () => cats.first,
    );
    final res = await _r.exploreSource(source, cat);
    if (res.error != null) throw Exception(res.error);
    return Paged(items: [for (final b in res.books) _toBook(b)]);
  }

  /// 搜索 ← searchUrl 模板 + ruleSearch。
  @override
  Future<List<Book>> search(String query) async {
    final res = await _r.searchOne(source, query);
    if (res.error != null) throw Exception(res.error);
    return [for (final b in res.books) _toBook(b)];
  }

  /// 详情 + 目录 ← ruleBookInfo + ruleToc。
  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async {
    final info = await _svc.fetchInfo(source, book.url);
    if (info.chapters.isEmpty) {
      throw Exception('「${source.bookSourceName}」未解析到章节');
    }
    // 书源解析出的字段优先，书架里已有数据兜底（换源后封面/作者不丢）。
    final merged = Book(
      sourceId: id,
      id: book.id,
      url: book.url,
      title: _pick(info.name, book.title) ?? '未命名',
      author: _pick(info.author, book.author),
      cover: _pick(info.coverUrl, book.cover),
      intro: _pick(info.intro, book.intro),
      status: book.status,
      latest: _pick(info.lastChapter, book.latest),
    );
    return BookDetail(book: merged, chapters: info.chapters);
  }

  /// 正文 ← ruleContent；书源标记 webView 时走隐藏浏览器（仅 Android）。
  @override
  Future<List<String>> fetchChapter(BookDetail detail, Chapter chapter) async {
    final text = await _svc.fetchChapterText(source, chapter.url);
    return cleanParas(text.split('\n'));
  }

  /// Legado 引擎按 ruleContent 处理取文，不再跟爽阅的「下一页」链接逻辑。
  @override
  String? pageNextUrl(Document doc, String currentUrl) => null;

  @override
  bool allowFollow(String currentUrl, String nextUrl) => false;

  /// 基类 [NovelSource.fetchChapter] 的取文钩子 —— 本类已整体覆盖 fetchChapter，
  /// 走不到这里；留空实现只为满足抽象接口。
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  static String? _pick(String? a, String? b) => (a != null && a.isNotEmpty)
      ? a
      : ((b != null && b.isNotEmpty) ? b : null);

  /// SearchBook → 爽阅的 Book（id 用书籍页地址，与固化书源保持同一约定）。
  Book _toBook(SearchBook b) => Book(
        sourceId: id,
        id: b.bookUrl ?? b.name ?? '',
        url: b.bookUrl ?? '',
        title: b.name ?? '未命名',
        author: b.author,
        cover: b.coverUrl,
        intro: b.intro,
        status: b.kind,
        latest: b.latestChapterTitle,
      );
}
