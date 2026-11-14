import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 首页/排行/搜索结果缓存：进程内 TTL 5 分钟 + 磁盘持久 24 小时。
/// 第二次打开应用直接读磁盘命中，同一数据不重复请求网络；
/// 下拉刷新通过 [invalidate] 强制作废（内存 + 磁盘）。
///
/// 磁盘 I/O 一律异步：首页/排行一次扇出几十个源，每条响应都同步写一个
/// 几十 KB 的 JSON 会直接在渲染线程上排队（安卓单次 1~5ms）。现在写盘串成
/// 一条异步队列，读盘在 [reach] 里 await。
class FeedCache {
  FeedCache._();

  static final Map<String, (Object, DateTime)> _m = {};
  static const ttl = Duration(minutes: 5);
  static const diskTtl = Duration(hours: 24);

  /// 磁盘文件数上限（约 30KB/条 → 12MB 量级）。超了按最后写入时间淘汰最旧的。
  /// 旧实现只有「读同一个 key 时才判过期」，搜索关键词每个词都落一个文件，
  /// 用久了磁盘只涨不降。
  static const int maxFiles = 400;

  static Directory? _dir;

  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/feed_cache');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
      unawaited(_sweep(d));
    } catch (_) {
      _dir = null; // 降级为纯内存缓存
    }
  }

  static String key(List<Object?> parts) => parts.join('|');

  static File? _file(String k) {
    final d = _dir;
    if (d == null) return null;
    // 文件名 = 键的安全化前缀（限长） + djb2 哈希（防中文/URL 字符与碰撞）
    var safe = k.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    if (safe.length > 80) safe = safe.substring(0, 80);
    var h = 5381;
    for (final u in k.codeUnits) {
      h = ((h << 5) + h + u) & 0x7fffffff;
    }
    return File('${d.path}/${safe}_${h.toRadixString(16)}.json');
  }

  /// 只读内存（同步、零 I/O）。需要磁盘兜底时用 [getAsync]。
  static T? get<T>(String k) {
    final e = _m[k];
    if (e == null) return null;
    if (DateTime.now().difference(e.$2) > ttl) {
      _m.remove(k);
      return null;
    }
    return e.$1 as T?;
  }

  /// 磁盘兜底读取（异步）；命中会回填内存并沿用磁盘记录的抓取时间 ——
  /// 不把 5 分钟内存 TTL 重新计时，数据年龄才如实增长。
  static Future<T?> getAsync<T>(String k) async {
    final hit = get<T>(k);
    if (hit != null) return hit;
    final (d, ts) = await _readDisk(k);
    if (d is Object && d is T) {
      _m[k] = (d, ts);
      return d as T;
    }
    return null;
  }

  static void clearForTest() {
    _m.clear();
    _stopJsonWorker();
  }

  static void set(String k, Object v) {
    _m[k] = (v, DateTime.now());
    unawaited(_writeDisk(k, v));
  }

  /// 删除某个键（下拉刷新时强制重新拉取，内存 + 磁盘一起作废）。
  static void invalidate(List<Object?> parts) {
    final k = key(parts);
    _m.remove(k);
    unawaited(_deleteDisk(k));
  }

  /// 按键前缀批量作废（排行刷新：「rank」一次清掉 rankTabs 与全部 rank 页）。
  ///
  /// 只作废内存、磁盘交给 [invalidatePrefixAsync] 后台删 —— 调用方若紧接着
  /// 重新取数，[reach] 会在删除完成前从磁盘把旧值读回来（下拉刷新「刷了等于
  /// 没刷」就是这么来的）。要保证刷新生效，请 await 异步版。
  @Deprecated('刷新后紧接着取数会读到磁盘旧值，改用 invalidatePrefixAsync')
  static void invalidatePrefix(String prefix) {
    unawaited(invalidatePrefixAsync(prefix));
  }

  /// 按键前缀批量作废（内存 + 磁盘），完成后再返回。
  ///
  /// 排行下拉刷新必须 await 它：内存删掉之后 [getAsync] 会去磁盘兜底，
  /// 磁盘删除是异步的，旧实现留了一个「刚删完又读回旧值」的窗口。
  static Future<void> invalidatePrefixAsync(String prefix) async {
    _m.removeWhere((k, _) => _safeName(k).startsWith(prefix));
    final d = _dir;
    if (d == null) return;
    try {
      await for (final f in d.list()) {
        if (f is File && f.uri.pathSegments.last.startsWith(prefix)) {
          try {
            await f.delete();
          } catch (_) {}
        }
      }
    } catch (_) {
      // 磁盘清理失败不影响内存语义（下次写入会覆盖）
    }
  }

  static String _safeName(String k) {
    var safe = k.replaceAll(RegExp(r'[^A-Za-z0-9]+'), '_');
    if (safe.length > 80) safe = safe.substring(0, 80);
    return safe;
  }

  /// 带缓存的异步取值：命中（内存或磁盘）直接返回，未命中执行 [fetch] 并写缓存。
  ///
  /// [skipEmpty]：结果为空列表时不写缓存（源抽风返回空 ≠ 真的没有数据，
  /// 缓存住会让用户在整个 TTL 里都搜不到这本书）。
  static Future<T> reach<T>(String k, Future<T> Function() fetch,
      {bool skipEmpty = false}) async {
    final hit = await getAsync<T>(k);
    if (hit != null) return hit;
    final v = await fetch();
    if (skipEmpty && v is List && v.isEmpty) return v; // 空结果不入缓存
    if (v is Object) set(k, v); // T 为可空类型时不缓存 null
    return v;
  }

  // ---------------- 磁盘编解码（类型按键前缀区分） ----------------

  /// 串行写队列：同一 key 的并发写不会互相覆盖，且一次只跑一个文件 I/O。
  static Future<void> _writeChain = Future.value();

  // ---------------- 后台 JSON 编解码（单常驻 isolate） ----------------
  //
  // 首页一次扇出几十个源，每条响应几十 KB；jsonEncode/jsonDecode 都在主
  // isolate 上排队，大响应时会直接丢帧。这里用**一个**常驻 isolate 串行
  // 处理编解码 —— 不用 compute()：每次 spawn 1~3ms，30 条响应就是一串
  // spawn，比编码本身还贵。
  static Isolate? _jsonIso;
  static SendPort? _jsonTo;
  static ReceivePort? _jsonRx;
  static Future<SendPort?>? _jsonStart;
  static final Map<int, Completer<Object?>> _jsonPending = {};
  static int _jsonSeq = 0;
  static bool _jsonDead = false;

  static Future<SendPort?> _jsonPort() {
    final p = _jsonTo;
    if (p != null) return Future.value(p);
    return _jsonStart ??= _startJsonWorker();
  }

  static Future<SendPort?> _startJsonWorker() async {
    final rx = ReceivePort();
    final ready = Completer<SendPort>();
    rx.listen((m) {
      if (m is SendPort) {
        if (!ready.isCompleted) ready.complete(m);
        return;
      }
      if (m is List && m.length == 3) {
        final c = _jsonPending.remove(m[0]);
        if (c != null && !c.isCompleted) {
          c.complete(m[1] == true ? m[2] : null);
        }
      }
    });
    try {
      _jsonIso =
          await Isolate.spawn(_jsonWorker, rx.sendPort, debugName: 'feed-json');
      final to = await ready.future.timeout(const Duration(seconds: 3));
      _jsonRx = rx;
      return _jsonTo = to;
    } catch (_) {
      rx.close();
      _jsonIso?.kill(priority: Isolate.immediate);
      _jsonIso = null;
      _jsonDead = true; // 平台不支持 / 起不来：之后一律回主线程
      _jsonStart = null;
      return null;
    }
  }

  static Future<Object?> _json(String op, Object data) async {
    if (_jsonDead) return null;
    final to = await _jsonPort();
    if (to == null) return null;
    final id = ++_jsonSeq;
    final c = Completer<Object?>();
    _jsonPending[id] = c;
    try {
      to.send([id, op, data, _jsonRx!.sendPort]);
      return await c.future.timeout(const Duration(seconds: 15));
    } catch (_) {
      _jsonPending.remove(id);
      return null;
    }
  }

  static void _stopJsonWorker() {
    _jsonIso?.kill(priority: Isolate.immediate);
    _jsonIso = null;
    _jsonTo = null;
    _jsonRx?.close();
    _jsonRx = null;
    _jsonStart = null;
    _jsonPending.clear();
    _jsonDead = false;
  }

  static Future<(Object?, DateTime)> _readDisk(String k) async {
    final now = DateTime.now();
    try {
      final f = _file(k);
      if (f == null || !await f.exists()) return (null, now);
      final text = await f.readAsString();
      final dec = await _json('dec', text) ?? jsonDecode(text);
      final j = dec is Map<String, dynamic>
          ? dec
          : Map<String, dynamic>.from(dec as Map);
      final ts = j['ts'] as int? ?? 0;
      final dt = DateTime.fromMillisecondsSinceEpoch(ts);
      if (now.difference(dt) > diskTtl) {
        try {
          await f.delete();
        } catch (_) {}
        return (null, now);
      }
      return (_decode(k, j['v']), dt);
    } catch (_) {
      return (null, now);
    }
  }

  static Future<void> _writeDisk(String k, Object v) async {
    final f = _file(k);
    if (f == null) return;
    // 模型 → 纯 JSON 结构必须在主 isolate 做（对象不能跨 isolate 传）；
    // 真正耗时的 jsonEncode 丢给后台，主线程只等结果。
    final plain = {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'v': _encode(k, v),
    };
    final enc = await _json('enc', plain);
    final body = enc is String ? enc : jsonEncode(plain);
    _writeChain = _writeChain.then((_) async {
      try {
        await f.writeAsString(body);
      } catch (_) {}
    });
  }

  static Future<void> _deleteDisk(String k) async {
    final f = _file(k);
    if (f == null) return;
    _writeChain = _writeChain.then((_) async {
      try {
        if (await f.exists()) await f.delete();
      } catch (_) {}
    });
  }

  /// 启动清扫：删 24h 前的文件；仍超 [maxFiles] 时按最后写入时间淘汰最旧的。
  static Future<void> _sweep(Directory d) async {
    try {
      final files = <(File, DateTime)>[];
      await for (final e in d.list()) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          files.add((e, st.modified));
        } catch (_) {}
      }
      final now = DateTime.now();
      files.sort((a, b) => b.$2.compareTo(a.$2)); // 新 → 旧
      for (var i = 0; i < files.length; i++) {
        final stale = now.difference(files[i].$2) > diskTtl;
        if (stale || i >= maxFiles) {
          try {
            await files[i].$1.delete();
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  static Object _encode(String k, Object v) {
    switch (k.split('|').first) {
      case 'rankTabs':
        return (v as List<RankTab>).map((e) => e.toJson()).toList();
      case 'rank':
        final p = v as Paged<Book>;
        return {
          'items': p.items.map((e) => e.toJson()).toList(),
          'nextUrl': p.nextUrl,
        };
      case 'booklists':
        final p = v as Paged<BooklistEntry>;
        return {
          'items': p.items.map((e) => e.toJson()).toList(),
          'nextUrl': p.nextUrl,
        };
      default: // home / search
        return (v as List<Book>).map((e) => e.toJson()).toList();
    }
  }

  static Object? _decode(String k, dynamic v) {
    final t = k.split('|').first;
    final rawItems = (v is Map ? v['items'] : v) as List;
    final items = [
      for (final e in rawItems)
        e is Map<String, dynamic> ? e : Map<String, dynamic>.from(e as Map),
    ];
    if (t == 'rank' || t == 'booklists') {
      final next = v is Map ? v['nextUrl'] as String? : null;
      return t == 'rank'
          ? Paged<Book>(items: items.map(Book.fromJson).toList(), nextUrl: next)
          : Paged<BooklistEntry>(
              items: items.map(BooklistEntry.fromJson).toList(), nextUrl: next);
    }
    return t == 'rankTabs'
        ? items.map(RankTab.fromJson).toList()
        : items.map(Book.fromJson).toList();
  }
}

/// 常驻 JSON 编解码 isolate 的入口（顶层函数，`Isolate.spawn` 只接受静态入口）。
///
/// 消息格式：`[id, 'enc'|'dec', 数据, 回执 SendPort]`；
/// 回执：`[id, 成功?, 结果]`（失败时调用方回主线程原路重试）。
void _jsonWorker(SendPort hub) {
  final rx = ReceivePort();
  hub.send(rx.sendPort);
  rx.listen((m) {
    if (m is! List || m.length != 4) return;
    final reply = m[3] as SendPort;
    try {
      final out = m[1] == 'enc' ? jsonEncode(m[2]) : jsonDecode(m[2] as String);
      reply.send([m[0], true, out]);
    } catch (e) {
      reply.send([m[0], false, '$e']);
    }
  });
}
