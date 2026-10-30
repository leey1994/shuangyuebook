// 导入书源的离线解析分身池：把「取页 + 规则解析 + QuickJS」整条链搬出主 isolate。
//
// 为什么还要再搬一层：书源体检已经进分身，但**搜索页 / 首页推荐 / 排行 /
// 换源计数**这些扇出路径仍然在主 isolate 上解析 —— 每个源的搜索页都要
// package:html 解析一遍、序列化再喂 xml 解析一遍、逐条跑 CSS/XPath/JSONPath
// 规则，JS 源还要跑 QuickJS。几十个源同时回结果，就是几十块 10~100ms 的
// 同步砖头拍在渲染线程上：列表掉帧、翻页发卡。
//
// 分工：
//  - 主 isolate 只做「发任务 / 收纯数据 / 画界面」；
//  - 分身（常驻 isolate 池）做网络 + 解析 + 脚本，结论按 JSON 回传；
//  - 需要平台通道的源（隐藏 WebView，见 [sourceNeedsMainParse]）不进分身，
//    仍然走主线程原路 —— 分身里开不了 WebView，硬塞只会拿壳页把好源判死。
//
// 保真回传（缺任何一条都会让「分身结论」和「主线程结论」不一致）：
//  1. Cookie：每个任务前用主线程同一份 `cookies.json` 起一个只读仓库，
//     任务中站点新下发的 Cookie 随结果带回主线程合并（写盘只认主线程一家）；
//  2. 书源跨阶段变量：搜索里 `@put:{...}` 写进 book.variableMap 的东西，
//     随结果带回主线程，否则详情页 `@get:{...}`（17k 那类源）会拿到空值；
//  3. `defer`：分身里 QuickJS 起不来、而这源的搜索确实依赖 JS 时，
//     明确回「交回主线程复探」，不在分身里瞎判。
//
// 目录 / 正文（OnlineBookService）刻意留在主线程：那是单源单页，等它的时候
// 用户在转圈页面上，没有并发解析互相挤；而且 Android 的令牌墙正文真要靠
// WebView 渲染，分身里没有。
import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';
import 'cookie_jar.dart';
import 'models.dart';
import 'online_book_service.dart';
import 'online_repo.dart';
import 'source_store.dart';
import 'source_vars.dart';

/// 书源是否需要留在主 isolate 解析。
///
/// 判据取「书源定义里出现过 `webView` 字样」这一宽口径：`extra.webView` 标记、
/// 章地址 `,{"webView":true}` 尾缀、脚本里的 `java.webView(...)` 都会命中。
/// 宁可多留几个在主线程，也不在分身里误杀好源。
bool sourceNeedsMainParse(BookSource s) =>
    s.toJson().toString().contains('webView');

/// 测试用：跳过原生桥直接指定分身要读的目录（真机上由主 isolate 经桥取）。
/// 传 null 恢复「取不到目录就一律留主线程」的默认行为。
@visibleForTesting
void debugSetWorkerDirs(AppDirs? dirs) {
  _dirsCache = dirs;
  _dirsFailed = dirs == null;
}

/// 分身要读的目录（Cookie / 书源变量）。
///
/// 只能由主 isolate 经桥取（MethodChannel 在分身里不可用），取一次常驻。
/// 取不到（测试环境没有原生桥、桌面端通道未就绪）就返回 null —— 上层据此
/// 一律留在主线程，行为回改动前。
AppDirs? _dirsCache;
bool _dirsFailed = false;

Future<AppDirs?> workerAppDirs() async {
  if (_dirsCache != null) return _dirsCache;
  if (_dirsFailed) return null;
  try {
    return _dirsCache = await NativeBridge.appDirs();
  } catch (_) {
    _dirsFailed = true;
    return null;
  }
}

/// 把分身带回的副作用合并进主线程：站点新下发的 Cookie、搜索写入的跨阶段变量。
/// 少合并任何一条，随后的详情 / 正文就会拿到空值，把好源误判成「搜不到书」。
void applyOffthreadSideEffects(Map<String, dynamic> r, String sourceUrl) {
  final ck = r['cookies'];
  if (ck is List && ck.isNotEmpty) LegadoCookieJar.I.mergeFrom(ck);
  final iv = r['itemVars'];
  if (iv is Map) {
    for (final e in iv.entries) {
      final m = e.value;
      if (m is! Map) continue;
      OnlineBookService.cacheItemVars(
        sourceUrl,
        '${e.key}',
        {for (final v in m.entries) '${v.key}': '${v.value}'},
      );
    }
  }
}

/// 离线解析分身池（进程内单例）。
class ParseWorkerPool {
  ParseWorkerPool._();

  static final ParseWorkerPool I = ParseWorkerPool._();

  /// 关掉离线解析（分身起不来 / 测试要求同线程时置位）：调用方一律走主线程。
  bool disabled = false;

  /// 分身总数：留核心给主 isolate 与渲染线程，最多 4 个。
  static int get workerCount {
    final n = Platform.numberOfProcessors;
    if (n <= 2) return 1;
    if (n <= 5) return 2;
    return 4;
  }

  final List<SendPort> _workers = [];
  final List<Isolate> _isolates = [];
  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final Map<int, Timer> _watchdog = {};
  ReceivePort? _hub;
  int _seq = 0;
  int _rr = 0;
  Completer<void>? _starting;

  /// 分身池当前活着的分身数（测试 / 诊断用）。
  @visibleForTesting
  int get liveWorkers => _workers.length;

  /// 起池（幂等）。首个任务触发，之后常驻复用 —— 复用才有 QuickJS 运行时、
  /// HTTP keep-alive 与站点限流表的意义。
  Future<void> _ensureStarted() async {
    if (_workers.isNotEmpty) return;
    if (_starting != null) return _starting!.future;
    final c = Completer<void>();
    _starting = c;
    final hub = _hub = ReceivePort();
    hub.listen(_onMessage);
    final want = workerCount;
    try {
      for (var i = 0; i < want; i++) {
        _isolates.add(await Isolate.spawn(_workerEntry, hub.sendPort,
            errorsAreFatal: false, debugName: 'legado-parse-$i'));
      }
    } catch (e) {
      hub.close();
      _hub = null;
      disabled = true;
      debugPrint('[书源分身] 起池失败，本轮全部回主线程解析：$e');
      if (!c.isCompleted) c.complete();
      return;
    }
    // 至少要有一个分身报到才开工（就绪消息见 _onMessage 的 ready 分支）
    await c.future.timeout(const Duration(seconds: 5), onTimeout: () {
      if (_workers.isEmpty) {
        disabled = true;
        debugPrint('[书源分身] 分身未在 5s 内就绪，回主线程解析');
      }
    });
    if (_workers.isNotEmpty) {
      debugPrint('[书源分身] 已起 ${_workers.length} 个分身：取页/解析/JS 不在主 isolate');
    }
  }

  void _onMessage(dynamic m) {
    if (m is! Map) return;
    if (m['ready'] == true) {
      final p = m['port'];
      if (p is SendPort) {
        _workers.add(p);
        if (_starting != null && !_starting!.isCompleted) _starting!.complete();
      }
      return;
    }
    final id = (m['id'] as num?)?.toInt();
    if (id == null) return;
    _watchdog.remove(id)?.cancel();
    final c = _pending.remove(id);
    if (c != null && !c.isCompleted) c.complete(Map<String, dynamic>.from(m));
  }

  /// 提交一个任务并等回执。返回 null = 没走成分身（调用方落回主线程原路）。
  Future<Map<String, dynamic>?> submit(Map<String, dynamic> job) async {
    if (disabled) return null;
    try {
      await _ensureStarted();
    } catch (_) {
      return null;
    }
    if (_workers.isEmpty) return null;
    final id = ++_seq;
    final payload = Map<String, dynamic>.of(job)..['id'] = id;
    final c = Completer<Map<String, dynamic>>();
    _pending[id] = c;
    // 轮转派活：单个分身内部是并发的（任务里还有网络等待），所以不按在飞数
    // 计数，均摊就够。
    // ponytail: 站点限流表（RateGate）是「每个分身一份」，同一源被派到不同
    // 分身时限流各算各的 —— 与改动前「每个源一个 OnlineRepo」的粒度接近，
    // 但并发搜索撞在一起时可能多打一发。真要严格全局限流，得把闸门挪回
    // 主线程在 submit 前放行。
    final w = _workers[_rr++ % _workers.length];
    try {
      w.send(payload);
    } catch (e) {
      _pending.remove(id);
      debugPrint('[书源分身] 派活失败，回主线程：$e');
      return null;
    }
    // 看门狗：分身崩了/消息丢了不能把上层 Future 挂成永久等待。
    final budgetS = (job['timeoutSecs'] as num?)?.toInt() ?? 60;
    _watchdog[id] = Timer(Duration(seconds: budgetS + 15), () {
      _watchdog.remove(id);
      final p = _pending.remove(id);
      if (p != null && !p.isCompleted) p.complete({'id': id, 'status': 'lost'});
    });
    final r = await c.future;
    if (r['status'] == 'lost') {
      debugPrint('[书源分身] 任务 ${job['kind']} 超时未回，本条回主线程');
      return null;
    }
    return r;
  }

  /// 测试 / 退出用：关掉池、杀掉分身并释放端口。
  void dispose() {
    for (final t in _watchdog.values) {
      t.cancel();
    }
    _watchdog.clear();
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(const _PoolGone());
    }
    _pending.clear();
    for (final i in _isolates) {
      i.kill(priority: Isolate.beforeNextEvent);
    }
    _isolates.clear();
    _workers.clear();
    _hub?.close();
    _hub = null;
    _starting = null;
  }
}

class _PoolGone implements Exception {
  const _PoolGone();
}

/// 分身入口（顶层函数：`Isolate.spawn` 只接受静态入口）。
void _workerEntry(SendPort hub) {
  final rp = ReceivePort();
  hub.send({'ready': true, 'port': rp.sendPort});
  rp.listen((m) {
    if (m is! Map) return;
    unawaited(_serve(hub, Map<String, dynamic>.from(m)));
  });
}

Future<void> _serve(SendPort hub, Map<String, dynamic> job) async {
  Map<String, dynamic> out;
  try {
    out = await _dispatch(job);
  } catch (e) {
    out = {'status': 'err', 'error': '分身异常：$e'};
  }
  out['id'] = job['id'];
  hub.send(out);
}

/// 同一分身内按源复用仓库：站点限流表（RateGate）与 HTTP 连接才留得住。
/// ponytail: 简单清空（超过 200 源），不做 LRU —— 分身本就只为省主线程。
final Map<String, OnlineRepo> _repos = {};

OnlineRepo _repoFor(BookSource src) {
  if (_repos.length > 200) _repos.clear();
  return _repos.putIfAbsent(
    src.bookSourceUrl,
    () => OnlineRepo(store: SourceStore(initial: [src]), offthreadParse: false),
  );
}

Future<Map<String, dynamic>> _dispatch(Map<String, dynamic> job) async {
  final dirs = AppDirs(files: '${job['files']}', cache: '${job['cache']}');
  // 每个任务前重读一次：主线程可能在两个任务之间写过 Cookie / 变量。
  final jar = LegadoCookieJar(dirsOverride: dirs)..readOnly = true;
  await jar.load();
  LegadoCookieJar.shared = jar;
  final vars = SourceVars(dirsOverride: dirs)..readOnly = true;
  await vars.load();
  SourceVars.shared = vars;

  final src = BookSource.fromJson(Map<String, dynamic>.from(job['source'] as Map));
  final repo = _repoFor(src);
  final budgetS = (job['timeoutSecs'] as num?)?.toInt() ?? 25;
  final kind = job['kind'];
  final t0 = DateTime.now();
  Map<String, dynamic> out;
  try {
    switch (kind) {
      case 'search':
        final res = await repo
            .searchOne(src, '${job['key']}', page: (job['page'] as num?)?.toInt() ?? 1)
            .timeout(Duration(seconds: budgetS));
        final su = src.searchUrl ?? '';
        final jsWanted = su.contains('@js:') || su.contains('<js>');
        final defer = res.error != null &&
            res.error!.contains('JS 引擎不可用') &&
            jsWanted;
        final books = [for (final b in res.books) b.toJson()];
        out = {
          'status': defer ? 'defer' : (res.error == null ? 'ok' : 'err'),
          'count': books.length,
          if (job['brief'] != true) 'books': books,
          if (res.error != null) 'error': res.error,
        };
      case 'explore':
        final cat = ExploreCategory(
          title: '${job['catTitle']}',
          url: '${job['catUrl']}',
        );
        final res = await repo
            .exploreSource(src, cat, page: (job['page'] as num?)?.toInt() ?? 1)
            .timeout(Duration(seconds: budgetS));
        out = {
          'status': res.error == null ? 'ok' : 'err',
          'count': res.books.length,
          'books': [for (final b in res.books) b.toJson()],
          if (res.error != null) 'error': res.error,
        };
      case 'categories':
        final cats = await repo
            .exploreCategoriesAsync(src)
            .timeout(Duration(seconds: budgetS));
        out = {
          'status': 'ok',
          'cats': [for (final c in cats) {'title': c.title, 'url': c.url}],
        };
      default:
        out = {'status': 'err', 'error': '未知任务类型：$kind'};
    }
  } on TimeoutException {
    out = {'status': 'err', 'error': '超时（单源 ${budgetS}s）'};
  } catch (e) {
    out = {'status': 'err', 'error': '$e'};
  }
  out['ms'] = DateTime.now().difference(t0).inMilliseconds;
  // 保真回传：本次任务里站点新下发的 Cookie + 搜索写入的跨阶段变量
  final touched = jar.touchedSnapshot();
  if (touched.isNotEmpty) out['cookies'] = touched;
  final iv = OnlineBookService.itemVarsSnapshotFor(src.bookSourceUrl);
  if (iv.isNotEmpty) out['itemVars'] = iv;
  return out;
}
