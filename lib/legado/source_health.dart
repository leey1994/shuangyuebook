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
import 'online_repo.dart';
import 'parse_worker.dart';
import 'source_store.dart';

/// 探针关键词阶梯：一个词搜不到不代表源废了（站点可能只收了其中一本，
/// 或者恰好下架/改名）。旧实现只用一个「斗破苍穹」，搜不到就直接判坏源 ——
/// 这是「原版能用的书源在爽阅里被判成坏源」的主因。
///
/// 顺序按「收录面从广到窄」排：第一本几乎全站都有，命中率最高，命中就停。
const List<String> kProbeKeywords = ['斗破苍穹', '诡秘之主', '凡人修仙传'];

/// 兼容旧引用（等同于 [kProbeKeywords] 第一个）。
const String kProbeKeyword = '斗破苍穹';

/// 单源探测的总预算。预算内把探针词阶梯跑完；超预算就带着已有结论收工。
/// 注意：这是整源预算，不是单次请求超时 —— 旧实现 25s 只够试一个词。
const Duration kProbeTimeout = Duration(seconds: 40);

/// 体检结论的保鲜期：超过这么久，旧的「连不上」不再作为排除依据。
const Duration kHealthVerdictTtl = Duration(days: 3);

/// 探测结论的三态。
///
/// · [ok]    搜得到东西，确实可用；
/// · [empty] 站点连通、搜索接口也返回了 200，但探针词全都没结果 —— 可能只是
///           这个源不收录这些书（或搜索只对分类生效），**不能判死**；
/// · [error] 请求层就失败了（连不上 / 超时 / 返回错误状态），才是真坏。
enum SourceHealthState { ok, empty, error }

/// 一次检测的结论。
class SourceHealth {
  SourceHealth({
    required this.url,
    required this.name,
    required bool ok,
    required this.checkedAt,
    SourceHealthState? state,
    this.books = 0,
    this.ms = 0,
    this.error,
  }) : state = state ??
            (ok ? SourceHealthState.ok : SourceHealthState.error);

  final String url;
  final String name;

  /// 探测结论（三态）。旧代码里的 `ok` 语义保留为「结论是可用」。
  final SourceHealthState state;

  /// 探测通过：请求成功且解析出至少一本书。
  bool get ok => state == SourceHealthState.ok;

  /// 站点能连通但没搜到探针词：可疑，不算坏源。
  bool get suspicious => state == SourceHealthState.empty;

  /// 请求层失败：基本可以确认废了。
  bool get broken => state == SourceHealthState.error;

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
        'state': state.name,
        'books': books,
        'ms': ms,
        'error': error,
        'checkedAt': checkedAt.toIso8601String(),
      };

  factory SourceHealth.fromJson(Map<String, dynamic> j) {
    final ok = j['ok'] as bool? ?? false;
    final err = j['error'] as String?;
    // 老档案没有 state 字段：按「ok 为假 + 错误是搜索无结果」回落成可疑，
    // 避免升级后把历史数据里本来能用的源当成坏源。
    final state = switch (j['state']) {
      'ok' => SourceHealthState.ok,
      'empty' => SourceHealthState.empty,
      'error' => SourceHealthState.error,
      _ => ok
          ? SourceHealthState.ok
          : (err != null && err.contains('无结果')
              ? SourceHealthState.empty
              : SourceHealthState.error),
    };
    return SourceHealth(
      url: j['url'] as String? ?? '',
      name: j['name'] as String? ?? '',
      ok: ok,
      state: state,
      books: (j['books'] as num?)?.toInt() ?? 0,
      ms: (j['ms'] as num?)?.toInt() ?? 0,
      error: err,
      checkedAt: DateTime.tryParse(j['checkedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 批量检测的结果 + 给用户看的一句话。
class SourceCheckReport {
  SourceCheckReport({
    required this.checked,
    required this.passed,
    required this.failed,
    required this.removed,
    this.warned = const <SourceHealth>[],
  });

  /// 本次检测了多少个导入书源。
  final int checked;

  /// 可用的个数。
  final int passed;

  /// 判定为不可用的源（请求层就失败，含原因），供 UI 展示。
  final List<SourceHealth> failed;

  /// 可疑源：站点连得上，但探针词搜不到东西。**不算坏源**，只提示。
  final List<SourceHealth> warned;

  /// 实际从仓库删掉的 url。
  final List<String> removed;

  bool get hasFailure => failed.isNotEmpty;

  bool get hasWarning => warned.isNotEmpty;

  String get summary {
    if (checked == 0) return '没有可检测的书源';
    final sb = StringBuffer('检测 $checked 个，$passed 个可用');
    if (warned.isNotEmpty) sb.write('，${warned.length} 个搜不到探针词（可疑）');
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

  int get todayFailed => today.where((h) => h.broken).length;

  int get todaySuspicious => today.where((h) => h.suspicious).length;

  /// 这个源还能不能进「可用书源池」。
  ///
  /// 没体检过的源先当可用（用户刚导入还没检测完时不能被当成废源），
  /// 只有请求层失败（[SourceHealthState.error]）才排除；「搜不到探针词」
  /// 只是可疑，仍然可用 —— 检测误判不该连累正常的搜索/阅读链路。
  ///
  /// 结论有保鲜期（[kHealthVerdictTtl]）：三天前的「连不上」可能是当时网断，
  /// 不能永久把这个源挡在池外，过期就放回去等下次体检。
  bool isUsable(String url) {
    final h = _items[url];
    if (h == null) return true;
    if (!h.broken) return true;
    return DateTime.now().difference(h.checkedAt) > kHealthVerdictTtl;
  }

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

  /// 探测单个源（主线程路径）。
  ///
  /// 批量体检默认把整条链交给后台分身池（[ParseWorkerPool]），只有两类源
  /// 留在这里：书源定义里带 `webView` 的（隐藏 WebView 只能开在主 isolate），
  /// 以及分身起不来 / 判不了退回的少数源。
  Future<SourceHealth> probe(LegadoSource src) => _probeMainThread(src);

  /// 主线程探测：把探针词阶梯跑一遍，结论最可靠但会占主线程。
  Future<SourceHealth> _probeMainThread(LegadoSource src) async {
    final t0 = DateTime.now();
    final outcome = await _probeLadder(
      (kw, left) async => (await src.search(kw).timeout(left)).length,
    );
    return SourceHealth(
      url: src.id,
      name: src.name,
      ok: outcome.state == SourceHealthState.ok,
      state: outcome.state,
      books: outcome.books,
      ms: DateTime.now().difference(t0).inMilliseconds,
      error: outcome.error,
      checkedAt: DateTime.now(),
    );
  }

  /// 探针词阶梯：从 [kProbeKeywords] 里逐个试，命中即收工。
  ///
  /// 每个词最多两次机会（先按原样，失败后 300ms 重试一次，抵消瞬时抖动）；
  /// 整源共享 [kProbeTimeout] 预算，超预算就带着已有结论返回 ——
  /// 一百个源逐个跑满预算会拖成十几分钟，宁可先给结论。
  Future<_ProbeOutcome> _probeLadder(
    Future<int> Function(String keyword, Duration left) search,
  ) async {
    final deadline = DateTime.now().add(kProbeTimeout);
    var sawEmpty = false;
    Object? lastError;
    for (final kw in kProbeKeywords) {
      for (var attempt = 0; attempt < 2; attempt++) {
        final left = deadline.difference(DateTime.now());
        if (left < const Duration(seconds: 2)) break;
        try {
          final n = await search(kw, left);
          if (n > 0) {
            return _ProbeOutcome(SourceHealthState.ok, books: n);
          }
          // 请求成功但零结果：换下一个探针词，别重试同一个词
          sawEmpty = true;
          break;
        } catch (e) {
          lastError = e;
          if (deadline.difference(DateTime.now()) <
              const Duration(seconds: 4)) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }
      if (deadline.difference(DateTime.now()) < const Duration(seconds: 2)) {
        break;
      }
    }
    if (sawEmpty) {
      return _ProbeOutcome(
        SourceHealthState.empty,
        error: '搜索接口能连通，但「${kProbeKeywords.join(' / ')}」都搜不到 —— '
            '可能没收录这些书，先按可疑保留',
      );
    }
    return _ProbeOutcome(SourceHealthState.error,
        error: _brief(lastError ?? '连不上站点'));
  }

  /// 分身探测：结论只回「活没活」，书目留在后台 isolate。
  ///
  /// 返回 null = 分身不可用（或这源的 JS 只有主线程起得来），交回主线程补探。
  Future<_ProbeOutcome?> _probeOffthread(
    OnlineRepo repo,
    LegadoSource src,
  ) async {
    final deadline = DateTime.now().add(kProbeTimeout);
    var sawEmpty = false;
    String? lastError;
    for (final kw in kProbeKeywords) {
      final left = deadline.difference(DateTime.now());
      if (left < const Duration(seconds: 2)) break;
      Map<String, dynamic>? r;
      try {
        r = await repo.offthreadProbe(src.source, kw).timeout(left);
      } catch (e) {
        lastError = _brief(e);
        continue;
      }
      if (r == null) return null; // 分身起不来 / 判不了
      if (r['status'] == 'err') {
        lastError = (r['error'] as String?) ?? '搜索失败';
        continue;
      }
      if (r['status'] == 'lost') {
        // 分身崩/超时不是源坏：按可疑保留，别落回主线程重探（双倍等待）
        return _ProbeOutcome(SourceHealthState.empty,
            error: '分身解析超时，本轮跳过（未判定书源失效）');
      }
      final count = (r['count'] as num?)?.toInt() ?? 0;
      if (count > 0) {
        return _ProbeOutcome(SourceHealthState.ok, books: count);
      }
      sawEmpty = true;
    }
    if (sawEmpty) {
      return _ProbeOutcome(SourceHealthState.empty,
          error: '搜索接口能连通，但探针词都没结果 —— 先按可疑保留');
    }
    return _ProbeOutcome(SourceHealthState.error, error: lastError ?? '搜索失败');
  }

  /// 批量检测导入书源。
  ///
  /// 探针走 [ParseWorkerPool] 常驻分身：取页、搜索页解析、JS 脚本全在后台
  /// isolate，主 isolate 只收结论 —— 体检期间不再掉帧。只有两类源留主线程：
  /// 需要隐藏 WebView 的（[sourceNeedsMainParse]），和分身起不来 / 判不了的。
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
    var done = 0;
    void record(SourceHealth h) {
      results.add(h);
      _items[h.url] = h;
      done++;
      notifyListeners();
      onProgress?.call(done, sources.length);
    }

    // 分身判不了 / 起不来的源，收尾统一在主线程补探：结论可靠优先于流畅
    final onMainThread = <LegadoSource>[];
    Future<void> runOnMainThread() async {
      final list = onMainThread;
      var i = 0;
      Future<void> worker() async {
        while (true) {
          final k = i++;
          if (k >= list.length) return;
          record(await _probeMainThread(list[k]));
        }
      }

      await Future.wait([
        for (var k = 0; k < concurrency && k < list.length; k++) worker(),
      ]);
    }

    // 需要隐藏 WebView 的源（平台通道只在主 isolate 可用）不进分身。
    final iso = <LegadoSource>[];
    for (final s in sources) {
      if (sourceNeedsMainParse(s.source)) {
        onMainThread.add(s);
      } else {
        iso.add(s);
      }
    }

    if (iso.isNotEmpty) {
      // 一个仓库管一批：perSourceTimeout 就是分身里的单源预算
      final repo = OnlineRepo(
        store: SourceStore(initial: [for (final s in iso) s.source]),
        perSourceTimeout: kProbeTimeout,
      );
      var next = 0;
      Future<void> worker() async {
        while (true) {
          final i = next++;
          if (i >= iso.length) return;
          final src = iso[i];
          final t0 = DateTime.now();
          final outcome = await _probeOffthread(repo, src);
          if (outcome == null) {
            onMainThread.add(src); // 分身判不了 → 主线程补探
            continue;
          }
          record(SourceHealth(
            url: src.id,
            name: src.name,
            ok: outcome.state == SourceHealthState.ok,
            state: outcome.state,
            books: outcome.books,
            ms: DateTime.now().difference(t0).inMilliseconds,
            error: outcome.error,
            checkedAt: DateTime.now(),
          ));
        }
      }

      await Future.wait([
        for (var i = 0; i < concurrency && i < iso.length; i++) worker(),
      ]);
    }

    // 少数留在主线程的源顺序探测（webView 源在实测语料里是 0 条，不是热路径）
    if (onMainThread.isNotEmpty) await runOnMainThread();

    // 只有「请求层就失败」才叫未通过；「搜不到探针词」只是可疑 ——
    // 原版能用的源在爽阅里被判坏、然后被用户一键清掉，就是从这儿来的。
    final failed = results.where((h) => h.broken).toList();
    final warned = results.where((h) => h.suspicious).toList();
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
      warned: warned,
      removed: removed,
    );
  }

  /// 每天首次启动自动体检一次；今天已检过则跳过。
  ///
  /// 自动体检**不删源**：用户不在意的时段里把书源清空代价太大。
  /// 删除只发生在「刚导入、用户明确要求」的那一刻。
  Future<SourceCheckReport?> autoRunIfNeeded({int concurrency = 4}) async {
    if (checkedToday) return null;
    if (importedSources.isEmpty) return null;
    return run(removeFailed: false, concurrency: concurrency);
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

/// 一次探针阶梯的结论（内部用）。
class _ProbeOutcome {
  _ProbeOutcome(this.state, {this.books = 0, this.error});

  final SourceHealthState state;
  final int books;
  final String? error;
}
