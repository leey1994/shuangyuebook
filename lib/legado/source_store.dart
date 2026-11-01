// 书源仓库：导入 / 导出 / 持久化（JSON 文件）/ 启用状态管理。
//
// 持久化位置：App files 目录下的 book_sources.json
// 结构：{"version": 1, "sources": [ {...书源JSON...} ]}
//
// 性能约定（1000+ 条书源卡顿治理；回归测试见 test/source_list_perf_test.dart）：
//  - [sourcesView] / [enabledSources] / [urls] 是不可变**缓存视图**：`_sources`
//    不变时反复访问返回同一个 List 实例 —— 旧实现每次访问都复制整表，
//    一帧里 UI 会取好几次（length / 循环 / enabledCount / 推荐候选），
//    1000 条时每帧白拷几千次对象引用；
//  - [indexOfUrl] / [byUrl] 走 `Map<String,int>` 索引，只在 `_sources` 增删时
//    重建一次，替掉每行都 O(n) 的 `indexWhere`（列表里反查 = O(n²)）；
//  - 批量操作（[addAll] / [setEnabledAll] / [removeMany] / 导入）只发一次通知、
//    只排一次落盘，不再「每条一次 notify + 一次写盘」；
//  - 大文件的 JSON 解析与落盘编码在后台 isolate 做（compute），
//    不占 UI 线程。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../platform/native_bridge.dart';
import 'models.dart';
import 'source_vars.dart';

/// 导入结果统计。
class SourceImportReport {
  const SourceImportReport({
    this.added = 0,
    this.updated = 0,
    this.invalid = 0,
    this.legado2 = 0,
    this.error,
  });

  final int added;
  final int updated;
  final int invalid;

  /// 被明确拒收的「阅读 2.0」书源条数（字段结构不同，硬导进来也跑不起来）。
  final int legado2;
  final String? error;

  bool get hasAny => added + updated > 0;

  String get summary {
    if (error != null) return error!;
    final parts = <String>[
      if (added > 0) '新增 $added 个',
      if (updated > 0) '更新 $updated 个',
      if (invalid > 0) '跳过 $invalid 个无效条目',
      if (legado2 > 0) '拒收 $legado2 个「阅读 2.0」书源（请用 3.0 格式重新导出）',
    ];
    return parts.isEmpty ? '没有可导入的书源' : parts.join('，');
  }
}

/// 超过这个字符数的导入文本改用后台 isolate 解析。
///
/// 1000 条书源 JSON 约 0.5–3 MB，主线程 jsonDecode 要几十到上百毫秒，
/// 正卡在「点完导入就掉帧」的位置；小文本（三五条）建 isolate 的开销
/// 比解析本身还大，所以仍走同步路径。
const int kSourceImportBackgroundChars = 64 * 1024;

/// 超过这个条数时，落盘 / 导出的 `jsonEncode` 也挪到后台 isolate。
const int kSourceEncodeBackgroundCount = 128;

/// 解析书源 JSON 文本（后台 isolate 入口）。
///
/// 参数与返回值都必须是可跨 isolate 传输的纯数据：
/// 返回 `{'error': String}` 或 `{'total': int, 'items': List<Map>}}`。
/// 这里只做 jsonDecode + 有效性过滤（bookSourceUrl 非空），
/// [BookSource] 对象留给 UI isolate 构造 —— 模型对象不跨 isolate 传。
Map<String, dynamic> decodeSourcePayload(String text) {
  final trimmed = text.trim().replaceFirst('\uFEFF', '');
  if (trimmed.isEmpty) return <String, dynamic>{'error': '内容为空'};
  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return <String, dynamic>{'error': '不是合法的 JSON（书源应为 JSON 数组或对象）'};
  }
  final raw = decoded is List ? decoded : <dynamic>[decoded];
  final items = <Map<String, dynamic>>[];
  var v2 = 0;
  for (final item in raw) {
    if (item is! Map) continue;
    try {
      final url = (item['bookSourceUrl'] ?? '').toString().trim();
      if (url.isEmpty) continue;
      if (looksLikeLegado2(item)) {
        v2++;
        continue;
      }
      items.add(Map<String, dynamic>.from(item));
    } catch (_) {
      // 单条坏数据不影响整体导入
    }
  }
  return <String, dynamic>{'total': raw.length, 'items': items, 'v2': v2};
}

/// 「阅读 2.0」书源的扁平规则字段。
///
/// 3.0 把规则收进了 `ruleSearch` / `ruleBookInfo` / `ruleToc` / `ruleContent`
/// 四个对象；2.0 是一整排 `ruleSearchList` / `ruleBookContent` 这样的顶层键。
/// 两种结构没有兼容层，直接导进来只会得到「搜不到书」的坏源，所以明确拒收。
const Set<String> _legado2RuleKeys = {
  'ruleSearchList',
  'ruleSearchName',
  'ruleSearchAuthor',
  'ruleSearchKind',
  'ruleSearchLastChapter',
  'ruleSearchIntroduce',
  'ruleSearchCoverUrl',
  'ruleSearchNoteUrl',
  'ruleBookName',
  'ruleBookAuthor',
  'ruleBookKind',
  'ruleBookLastChapter',
  'ruleBookIntroduce',
  'ruleBookCoverUrl',
  'ruleChapterList',
  'ruleChapterName',
  'ruleContentUrl',
  'ruleBookContent',
  'ruleBookUrlPattern',
};

/// 是否是「阅读 2.0」书源（见 [_legado2RuleKeys]）。
bool looksLikeLegado2(Map item) {
  // 只要带了任一 3.0 嵌套规则对象，就按 3.0 处理（有些源会混着写兼容字段）
  for (final k in const ['ruleSearch', 'ruleBookInfo', 'ruleToc', 'ruleContent']) {
    if (item[k] is Map) return false;
  }
  for (final k in _legado2RuleKeys) {
    if (item.containsKey(k)) return true;
  }
  return false;
}

/// 落盘快照的解码（后台 isolate 入口）。
///
/// 落盘结构是 `{"version":1,"builtinSyncVersion":N,"sources":[...]}`，
/// 和「导入用的裸数组」不是一回事，所以单独一个入口。
/// 返回 `{'builtinSyncVersion': int, 'items': List<Map>}`。
Map<String, dynamic> decodeSourceSnapshotPayload(String text) {
  final trimmed = text.trim().replaceFirst('\uFEFF', '');
  if (trimmed.isEmpty) return <String, dynamic>{'items': const []};
  dynamic decoded;
  try {
    decoded = jsonDecode(trimmed);
  } catch (_) {
    return <String, dynamic>{'items': const []};
  }
  if (decoded is! Map) return <String, dynamic>{'items': const []};
  final raw = decoded['sources'];
  final items = <Map<String, dynamic>>[];
  if (raw is List) {
    for (final item in raw) {
      if (item is! Map) continue;
      try {
        items.add(Map<String, dynamic>.from(item));
      } catch (_) {
        // 单条坏数据不影响整体
      }
    }
  }
  final v = decoded['builtinSyncVersion'];
  return <String, dynamic>{
    'builtinSyncVersion': v is num ? v.toInt() : SourceStore.kBuiltinSyncVersion,
    'items': items,
  };
}

/// 落盘编码（后台 isolate 入口）。
String encodeSourceSnapshot(Map<String, dynamic> snapshot) =>
    jsonEncode(snapshot);

/// 导出编码（后台 isolate 入口，缩进格式与旧版一致）。
String encodeSourceExport(List<Map<String, dynamic>> list) =>
    const JsonEncoder.withIndent('  ').convert(list);

/// 书源仓库（可监听，UI 依赖它刷新）。
class SourceStore extends ChangeNotifier {
  SourceStore({AppDirs? dirsOverride, List<BookSource>? initial})
      : _dirsOverride = dirsOverride {
    if (initial != null) _sources.addAll(initial);
  }

  /// 进程内共享实例（在线书籍内容读取器按 bookSourceUrl 查找书源时使用）。
  static SourceStore? shared;

  final AppDirs? _dirsOverride;
  final List<BookSource> _sources = [];
  AppDirs? _dirs;
  File? _file;
  Timer? _saveTimer;

  // ---------- 缓存视图（_sources 变更时整体失效） ----------

  List<BookSource>? _sourcesView;
  List<BookSource>? _enabledView;
  List<String>? _urlsView;
  Map<String, int>? _urlIndex;

  /// 仅供测试：url→index 索引的整表重建次数。
  ///
  /// 「加一条就 indexWhere 扫一遍」的旧实现会让它涨成 O(n) 次；
  /// 现在一次批量导入只允许重建一次。
  @visibleForTesting
  int debugIndexRebuildCount = 0;

  /// 内置资产清理的版本号：同一版本只清理一次。
  ///
  /// 历史版本预置过的书源地址清单（`legacyBuiltinUrls`）只在**升级后首次启动**
  /// 生效一次；否则用户手动重新导入同址书源后，每次启动都会被再删一遍。
  int _builtinSyncVersion = 0;

  /// 当前资产清理逻辑的版本。改清理规则时 +1。
  static const int kBuiltinSyncVersion = 1;

  /// 全部导入书源的**稳定不可变视图**。
  ///
  /// `_sources` 没有变更时反复取到的是同一个 List 实例（零拷贝），
  /// 变更后自动重建一次。UI 请用这个 getter。
  List<BookSource> get sourcesView =>
      _sourcesView ??= List<BookSource>.unmodifiable(_sources);

  /// 兼容旧调用点：与 [sourcesView] 等价。
  ///
  /// 历史实现是 `List.unmodifiable(_sources)`（每次访问都复制整表），
  /// 这里保留旧名字但不再产生拷贝，行为对外一致（同样不可修改）。
  List<BookSource> get sources => sourcesView;

  /// 已启用书源的稳定不可变视图（缓存，`_sources` 变更时重建）。
  List<BookSource> get enabledSources =>
      _enabledView ??=
          List<BookSource>.unmodifiable(_sources.where((s) => s.enabled));

  /// 兼容旧调用点：与 [enabledSources] 等价（原来每次都新建一个列表）。
  List<BookSource> get enabled => enabledSources;

  /// 已启用数量（O(1)：复用 [enabledSources] 的长度，不再整表 where）。
  int get enabledCount => enabledSources.length;

  bool get isEmpty => _sources.isEmpty;

  /// 全部书源地址（缓存视图；全选 / 去重判断用，避免临时 map(...).toList()）。
  List<String> get urls =>
      _urlsView ??=
          List<String>.unmodifiable(_sources.map((s) => s.bookSourceUrl));

  /// url → 下标索引（`_sources` 增删时重建；启用状态切换不重建）。
  ///
  /// 同一地址出现多次时保留**第一次**出现的下标 —— 与旧实现
  /// `indexWhere((x) => x.bookSourceUrl == url)` 的语义一致。
  Map<String, int> get _urlIndexMap => _urlIndex ??= _buildUrlIndex();

  Map<String, int> _buildUrlIndex() {
    debugIndexRebuildCount++;
    final index = <String, int>{};
    for (var i = 0; i < _sources.length; i++) {
      index.putIfAbsent(_sources[i].bookSourceUrl, () => i);
    }
    return index;
  }

  /// 按地址取下标；没有返回 -1（O(1)，替代 `indexWhere`）。
  int indexOfUrl(String url) => _urlIndexMap[url] ?? -1;

  /// 是否已有该地址的书源（O(1)）。
  bool containsUrl(String url) => _urlIndexMap.containsKey(url);

  /// 按地址取书源（O(1)）。
  BookSource? byUrl(String url) {
    final i = _urlIndexMap[url];
    if (i == null || i >= _sources.length) return null;
    return _sources[i];
  }

  /// 视图失效：只清列表视图，保留 url→index（元素位置与地址都没变时用）。
  void _invalidateViews() {
    _sourcesView = null;
    _enabledView = null;
    _urlsView = null;
  }

  /// 全部失效：列表视图 + url→index（有增删导致下标位移时用）。
  void _invalidateAll() {
    _invalidateViews();
    _urlIndex = null;
  }

  // ---------- 加载 / 保存 ----------

  Future<void> load() async {
    _dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${_dirs!.files}/book_sources.json');
    try {
      if (await _file!.exists()) {
        final text = await _file!.readAsString();
        // 1000+ 条书源时，jsonDecode + 逐条构造模型在主 isolate 上要几百毫秒，
        // 正好卡在「点开图标 → 首帧出现」这段，用户感知就是启动慢。
        // 大文件改到后台 isolate 解码，主 isolate 只做模型构造。
        final items = await _decodeForStart(text);
        for (final item in items) {
          try {
            final s = BookSource.fromJson(item);
            if (s.bookSourceUrl.isNotEmpty) _sources.add(s);
          } catch (_) {
            // 跳过坏条目
          }
        }
      }
    } catch (_) {
      // 读取失败时以空列表启动
    }
    _invalidateAll();
    notifyListeners();
  }

  /// 启动用的解码：返回原始条目列表（Map）。
  ///
  /// 大文本走后台 isolate；小文本直接解（起 isolate 的开销比解析本身还大）。
  Future<List<Map<String, dynamic>>> _decodeForStart(String text) async {
    if (text.length < kSourceImportBackgroundChars) {
      final parsed = decodeSourceSnapshotPayload(text);
      final v = parsed['builtinSyncVersion'];
      if (v is int) _builtinSyncVersion = v;
      final items = parsed['items'];
      return items is List
          ? [
              for (final item in items)
                if (item is Map) Map<String, dynamic>.from(item)
            ]
          : const [];
    }
    try {
      final parsed = await compute(decodeSourceSnapshotPayload, text);
      final v = parsed['builtinSyncVersion'];
      if (v is int) _builtinSyncVersion = v;
      final items = parsed['items'];
      if (items is List) {
        return [
          for (final item in items)
            if (item is Map) Map<String, dynamic>.from(item)
        ];
      }
    } catch (_) {
      // isolate 起不来就退回同步解析
    }
    final parsed = decodeSourceSnapshotPayload(text);
    final v = parsed['builtinSyncVersion'];
    if (v is int) _builtinSyncVersion = v;
    final items = parsed['items'];
    return items is List
        ? [
            for (final item in items)
              if (item is Map) Map<String, dynamic>.from(item)
          ]
        : const [];
  }

  // ---------- 变更 ----------

  /// 批量导入；同一 bookSourceUrl 视为更新（保留原启用状态）。
  ///
  /// 旧实现每条都 `indexWhere` 扫一遍全表（1000 条导入 = 100 万次比较），
  /// 现在改用 url→index 索引，整体 O(n + m)；通知与落盘各只发一次。
  ({int added, int updated}) addAll(List<BookSource> items) {
    if (items.isEmpty) return (added: 0, updated: 0);
    // 首次构建 O(n)，之后本次循环里增量维护，不再重复扫表。
    final index = _urlIndexMap;
    var added = 0;
    var updated = 0;
    for (final s in items) {
      final i = index[s.bookSourceUrl];
      if (i != null && i < _sources.length) {
        // 保留用户当前的启用状态
        final keepEnabled = _sources[i].enabled;
        _sources[i] =
            s.enabled == keepEnabled ? s : s.copyWith(enabled: keepEnabled);
        updated++;
      } else {
        _sources.add(s);
        // 同址重复：索引保留第一条（与 indexWhere / byUrl 语义一致）
        index.putIfAbsent(s.bookSourceUrl, () => _sources.length - 1);
        added++;
      }
    }
    if (added + updated > 0) {
      _invalidateViews();
      _saveSoon();
      notifyListeners();
    }
    return (added: added, updated: updated);
  }

  void remove(String url) {
    if (!containsUrl(url)) return;
    final before = _sources.length;
    _sources.removeWhere((s) => s.bookSourceUrl == url);
    if (_sources.length == before) return;
    // 连带清掉该源的脚本变量（legado 删除书源时同样清 BookSourceVariable）
    SourceVars.shared?.removeSource(url);
    _invalidateAll();
    _saveSoon();
    notifyListeners();
  }

  void setEnabled(String url, bool value) {
    final i = _urlIndexMap[url];
    if (i == null || i >= _sources.length) return;
    if (_sources[i].enabled == value) return;
    _sources[i] = _sources[i].copyWith(enabled: value);
    // 位置与地址都没变：索引还能用，只重建列表视图。
    _invalidateViews();
    _saveSoon();
    notifyListeners();
  }

  /// 批量设置启用状态（书源管理「批量管理」用）。
  ///
  /// 返回实际变更的数量（已处于目标状态的条目不计入）。
  /// 只发一次通知、只排一次落盘；复杂度 O(选中条数) 而不是 O(全表)。
  int setEnabledAll(Iterable<String> urls, bool value) {
    final targets = urls.toSet();
    if (targets.isEmpty) return 0;
    final index = _urlIndexMap;
    var changed = 0;
    for (final url in targets) {
      final i = index[url];
      if (i == null || i >= _sources.length) continue;
      final s = _sources[i];
      if (s.enabled == value) continue;
      _sources[i] = s.copyWith(enabled: value);
      changed++;
    }
    if (changed > 0) {
      _invalidateViews();
      _saveSoon();
      notifyListeners();
    }
    return changed;
  }

  /// 批量删除（书源管理「批量管理」用）。返回实际删除的数量。
  ///
  /// 一次删除 + 一次通知 + 一次落盘（旧实现若在 UI 里逐条调 remove，
  /// 就是 N 次通知 + N 次写盘）。
  int removeMany(Iterable<String> urls) {
    final targets = urls.toSet();
    if (targets.isEmpty) return 0;
    final index = _urlIndexMap;
    final hit = <String>{
      for (final u in targets)
        if (index.containsKey(u)) u,
    };
    if (hit.isEmpty) return 0;
    final before = _sources.length;
    _sources.removeWhere((s) => hit.contains(s.bookSourceUrl));
    final removed = before - _sources.length;
    if (removed > 0) {
      for (final u in hit) {
        SourceVars.shared?.removeSource(u);
      }
      _invalidateAll();
      _saveSoon();
      notifyListeners();
    }
    return removed;
  }

  // ---------- 导入 / 导出 ----------

  /// 从 JSON 文本导入（同步；小文本与旧调用点用）。
  ///
  /// 支持数组或单个对象；容忍 BOM 与首尾空白。
  SourceImportReport importFromText(String text) =>
      _applyParsed(decodeSourcePayload(text));

  /// 从 JSON 文本导入（大文本自动把解析挪到后台 isolate）。
  ///
  /// 解析完仍回到调用方 isolate 构造 BookSource 并**一次性**入库，
  /// 所以「导入 1000 条」只会有一次通知 + 一次落盘。
  Future<SourceImportReport> importFromTextAsync(String text) async {
    if (text.length < kSourceImportBackgroundChars) return importFromText(text);
    Map<String, dynamic> parsed;
    try {
      parsed = await compute(decodeSourcePayload, text);
    } catch (_) {
      // isolate 起不来（受限平台）就退回同步解析，导入不能失败。
      return importFromText(text);
    }
    return _applyParsed(parsed);
  }

  /// 把解析结果（原始条目）构造为模型并入库。
  SourceImportReport _applyParsed(Map<String, dynamic> parsed) {
    final err = parsed['error'];
    if (err is String) return SourceImportReport(error: err);
    final total = (parsed['total'] as num?)?.toInt() ?? 0;
    final v2 = (parsed['v2'] as num?)?.toInt() ?? 0;
    final rawItems = parsed['items'] as List? ?? const [];
    final items = <BookSource>[];
    for (final raw in rawItems) {
      try {
        items.add(BookSource.fromJson(raw));
      } catch (_) {
        // 单条坏数据不影响整体导入
      }
    }
    if (items.isEmpty) {
      return const SourceImportReport(
        error: '没有解析到有效书源（需要 bookSourceUrl 与 bookSourceName）',
      );
    }
    final r = addAll(items);
    return SourceImportReport(
      added: r.added,
      updated: r.updated,
      invalid: total - items.length - v2,
      legado2: v2,
    );
  }

  /// 从文件导入（读文本 → 大文件后台解析 → 一次性入库）。
  Future<SourceImportReport> importFromFile(String path) async {
    try {
      final text = await File(path).readAsString();
      return await importFromTextAsync(text);
    } catch (e) {
      return SourceImportReport(error: '读取文件失败：$e');
    }
  }

  /// 导出为 JSON 文本（数组格式，与阅读 3.0 互通）。
  String exportJson() => encodeSourceExport(
        [for (final s in _sources) s.toJson()],
      );

  /// 导出（大库在后台 isolate 编码，剪贴板/弹窗之前不再卡一下 UI）。
  Future<String> exportJsonAsync() async {
    final list = [for (final s in _sources) s.toJson()];
    if (list.length < kSourceEncodeBackgroundCount) return encodeSourceExport(list);
    try {
      return await compute(encodeSourceExport, list);
    } catch (_) {
      return encodeSourceExport(list);
    }
  }

  /// 立即落盘（测试与退出前调用；平时是防抖保存）。
  Future<void> flush() => _save();

  /// 同步内置书源资产（App 启动时调用）。
  ///
  /// 现在**不预置任何导入书源** —— 原生内置适配器（lib/sources/）已经够用，
  /// 导入区留给用户自己填。资产文件保留下来只当「清理清单」用：
  ///
  /// - `sources`：预置清单，当前为空；
  /// - `legacyBuiltinUrls`：历史版本预置过的地址。这些从旧版本升级上来的用户
  ///   本地已经有它们，启动时按地址删掉，导入区才能真正回到「默认为空」。
  ///   只删地址完全一致的条目，用户自己导入的同名站点不受影响；
  ///   且按 [kBuiltinSyncVersion] **只清一次**，用户重新导入后不会再被删。
  Future<int> syncBuiltinSources() async {
    try {
      final text = await rootBundle.loadString(
        'assets/sources/builtin_sources.json',
      );
      var removed = 0;
      var cleaned = false;
      if (_builtinSyncVersion < kBuiltinSyncVersion) {
        removed = _dropLegacyBuiltinSources(text);
        _builtinSyncVersion = kBuiltinSyncVersion;
        cleaned = true;
      }
      var added = 0;
      final seeded = _seededFrom(text);
      if (seeded.isNotEmpty) {
        final report = importFromText(seeded);
        added = report.added + report.updated;
      }
      if (removed > 0 || added > 0 || cleaned) await flush();
      return added + removed;
    } catch (_) {
      return 0;
    }
  }

  /// 从资产里取出预置书源数组（`sources` 字段；兼容旧的纯数组格式）。
  String _seededFrom(String builtinJson) {
    try {
      final decoded = jsonDecode(builtinJson);
      if (decoded is List) return jsonEncode(decoded);
      if (decoded is Map && decoded['sources'] is List) {
        return jsonEncode(decoded['sources']);
      }
    } catch (_) {
      return '';
    }
    return '';
  }

  /// 按内置资产里的 `legacyBuiltinUrls` 清单移除历史内置源。
  ///
  /// 只删「书源地址完全一致」的条目：用户自己导入的同名站点不受影响。
  int _dropLegacyBuiltinSources(String builtinJson) {
    final legacy = <String>{};
    void collect(dynamic decoded) {
      if (decoded is Map) {
        final urls = decoded['legacyBuiltinUrls'];
        if (urls is List) legacy.addAll(urls.map((u) => u.toString().trim()));
      } else if (decoded is List) {
        for (final item in decoded) {
          if (item is Map) collect(item);
        }
      }
    }

    try {
      collect(jsonDecode(builtinJson));
    } catch (_) {
      return 0;
    }
    legacy.removeWhere((u) => u.isEmpty);
    if (legacy.isEmpty) return 0;
    final before = _sources.length;
    _sources.removeWhere((s) => legacy.contains(s.bookSourceUrl));
    final removed = before - _sources.length;
    if (removed > 0) _invalidateAll();
    return removed;
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }

  // ---------- 持久化 ----------

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      // 先在内存里拍快照（只重建一次 Map），编码再按体量决定是否进 isolate。
      final snapshot = <String, dynamic>{
        'version': 1,
        'builtinSyncVersion': _builtinSyncVersion,
        'sources': [for (final s in _sources) s.toJson()],
      };
      String text;
      if (_sources.length >= kSourceEncodeBackgroundCount) {
        try {
          text = await compute(encodeSourceSnapshot, snapshot);
        } catch (_) {
          text = jsonEncode(snapshot);
        }
      } else {
        text = jsonEncode(snapshot);
      }
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(text);
      await tmp.rename(file.path);
    } catch (_) {
      // 忽略保存失败
    }
  }
}
