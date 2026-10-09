// 书源健康检测：导入后批量验活 + 每天定时体检。
//
// 为什么要做：导入的书源常常是几个月前的收藏，站点早就换域名或关停。
// 它们不会报错，只是安安静静地返回空 —— 用户表现为「搜不到书」，却查不出原因。
// 这里用一次真实搜索当探针，把「活着且搜得出东西」和「已经废了」区分开。
//
// 检测结果落在 <files>/source_health.json，阅读记录页展示当天情况。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';
import '../sources/legado_source.dart';
import '../sources/registry.dart';
import 'source_store.dart';

/// 探针关键词：专有名词比「天才」这类烂大街的词更容易命中真实结果，
/// 站点若把验证页/首页当成结果返回，也更容易被判为不通过。
const String kProbeKeyword = '斗破苍穹';

/// 单源探测的硬超时。超时不判死刑，只记为异常。
const Duration kProbeTimeout = Duration(seconds: 12);

/// 一次检测的结论。
class SourceHealth {
  SourceHealth({
    required this.url,
    required this.name,
    required this.ok,
    required this.checkedAt,
    this.books = 0,
    this.ms = 0,
    this.error,
  });

  final String url;
  final String name;

  /// 探测通过：请求成功且解析出至少一本书。
  final bool ok;

  /// 探测到的结果条数。
  final int books;

  /// 耗时（毫秒）。
  final int ms;

  final String? error;

  final DateTime checkedAt;

  Map<String, dynamic> toJson() => {
        'url': url,
        'name': name,
        'ok': ok,
        'books': books,
        'ms': ms,
        'error': error,
        'checkedAt': checkedAt.toIso8601String(),
      };

  factory SourceHealth.fromJson(Map<String, dynamic> j) => SourceHealth(
        url: j['url'] as String? ?? '',
        name: j['name'] as String? ?? '',
        ok: j['ok'] as bool? ?? false,
        books: (j['books'] as num?)?.toInt() ?? 0,
        ms: (j['ms'] as num?)?.toInt() ?? 0,
        error: j['error'] as String?,
        checkedAt: DateTime.tryParse(j['checkedAt'] as String? ?? '') ??
            DateTime.now(),
      );
}

/// 批量检测的结果 + 给用户看的一句话。
class SourceCheckReport {
  SourceCheckReport({
    required this.checked,
    required this.passed,
    required this.failed,
    required this.removed,
  });

  /// 本次检测了多少个导入书源。
  final int checked;

  /// 可用的个数。
  final int passed;

  /// 判定为不可用的源（含原因），供 UI 展示。
  final List<SourceHealth> failed;

  /// 实际从仓库删掉的 url。
  final List<String> removed;

  bool get hasFailure => failed.isNotEmpty;

  String get summary {
    if (checked == 0) return '没有可检测的书源';
    final sb = StringBuffer('检测 $checked 个，$passed 个可用');
    if (failed.isNotEmpty) sb.write('，${failed.length} 个不可用');
    if (removed.isNotEmpty) sb.write('，已移除 ${removed.length} 个');
    return sb.toString();
  }
}

/// 书源健康档案（进程内单例 + JSON 持久化）。
class SourceHealthStore extends ChangeNotifier {
  SourceHealthStore({AppDirs? dirsOverride}) : _dirsOverride = dirsOverride;

  static SourceHealthStore? shared;

  static SourceHealthStore get I => shared ??= SourceHealthStore();

  final AppDirs? _dirsOverride;
  final Map<String, SourceHealth> _items = {};
  File? _file;
  Timer? _saveTimer;

  /// 今天是否已经检测过（每天一次，不重复打扰）。
  bool get checkedToday {
    final at = lastCheckedAt;
    return at != null && _sameDay(at, DateTime.now());
  }

  DateTime? get lastCheckedAt {
    DateTime? newest;
    for (final h in _items.values) {
      if (newest == null || h.checkedAt.isAfter(newest)) newest = h.checkedAt;
    }
    return newest;
  }

  /// 当天的检测结果（正常的在前，再按耗时升序）。
  List<SourceHealth> get today {
    final now = DateTime.now();
    final list = _items.values.where((h) => _sameDay(h.checkedAt, now)).toList()
      ..sort((a, b) {
        if (a.ok != b.ok) return a.ok ? -1 : 1;
        return a.ms.compareTo(b.ms);
      });
    return list;
  }

  int get todayOk => today.where((h) => h.ok).length;

  int get todayFailed => today.length - todayOk;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Future<void> load() async {
    final dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${dirs.files}/source_health.json');
    try {
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map && data['items'] is List) {
          for (final e in data['items'] as List) {
            if (e is Map) {
              final h = SourceHealth.fromJson(e.cast<String, dynamic>());
              if (h.url.isNotEmpty) _items[h.url] = h;
            }
          }
        }
      }
    } catch (_) {
      // 读不出来就从零开始，不阻塞启动
    }
    notifyListeners();
  }

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode({
        'version': 1,
        'items': [for (final h in _items.values) h.toJson()],
      }));
    } catch (_) {
      // 落盘失败不影响本次结论
    }
  }

  /// 探测单个源：跑一次真实搜索当探针。
  Future<SourceHealth> probe(LegadoSource src) async {
    final t0 = DateTime.now();
    try {
      final books = await src.search(kProbeKeyword).timeout(kProbeTimeout);
      final ms = DateTime.now().difference(t0).inMilliseconds;
      return SourceHealth(
        url: src.id,
        name: src.name,
        // 搜得到东西才算活；只回 200 但解析不出书 = 站点改版 / 挂了验证
        ok: books.isNotEmpty,
        books: books.length,
        ms: ms,
        error: books.isEmpty ? '搜索无结果，站点可能已失效' : null,
        checkedAt: DateTime.now(),
      );
    } catch (e) {
      return SourceHealth(
        url: src.id,
        name: src.name,
        ok: false,
        ms: DateTime.now().difference(t0).inMilliseconds,
        error: _brief(e),
        checkedAt: DateTime.now(),
      );
    }
  }

  /// 批量检测导入书源。
  ///
  /// [removeFailed] 为 true 时把不通过的源从仓库删掉（导入流程用）。
  /// [onProgress] 每完成一个源回调一次，参数为「已完成数 / 本次总数」。
  ///
  /// 无论删不删，检测结论都会写进健康档案，用户能在阅读记录页看到
  /// 当天谁不通过、原因是什么。
  Future<SourceCheckReport> run({
    bool removeFailed = false,
    void Function(int done, int total)? onProgress,
    int concurrency = 4,
  }) async {
    final sources = importedSources;
    if (sources.isEmpty) {
      return SourceCheckReport(checked: 0, passed: 0, failed: [], removed: []);
    }
    final results = <SourceHealth>[];
    var next = 0;
    var done = 0;
    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= sources.length) return;
        final src = sources[i];
        final h = await probe(src);
        results.add(h);
        _items[src.id] = h;
        done++;
        notifyListeners();
        onProgress?.call(done, sources.length);
      }
    }

    await Future.wait([
      for (var i = 0; i < concurrency && i < sources.length; i++) worker(),
    ]);

    final failed = results.where((h) => !h.ok).toList();
    var removed = <String>[];
    if (removeFailed && failed.isNotEmpty) {
      final store = SourceStore.shared;
      if (store != null) {
        removed = failed.map((f) => f.url).toList();
        store.removeMany(removed);
        await store.flush();
      }
    }
    _saveSoon();
    return SourceCheckReport(
      checked: results.length,
      passed: results.length - failed.length,
      failed: failed,
      removed: removed,
    );
  }

  /// 每天首次启动自动体检一次；今天已检过则跳过。
  ///
  /// 自动体检**不删源**：用户不在意的时段里把书源清空代价太大。
  /// 删除只发生在「刚导入、用户明确要求」的那一刻。
  Future<SourceCheckReport?> autoRunIfNeeded() async {
    if (checkedToday) return null;
    if (importedSources.isEmpty) return null;
    return run(removeFailed: false);
  }

  static String _brief(Object e) {
    var s = e.toString();
    if (s.startsWith('Exception: ')) s = s.substring(11);
    return s.length > 60 ? '${s.substring(0, 60)}…' : s;
  }

  /// 仅供测试：直接塞入检测结果（跳过真实网络探测）。
  @visibleForTesting
  void seedForTest(List<SourceHealth> items) {
    for (final h in items) {
      _items[h.url] = h;
    }
    notifyListeners();
  }
}
