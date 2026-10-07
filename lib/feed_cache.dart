import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'models.dart';

/// 首页/排行/搜索结果缓存：进程内 TTL 5 分钟 + 磁盘持久 24 小时。
/// 第二次打开应用直接读磁盘命中，同一数据不重复请求网络；
/// 下拉刷新通过 [invalidate] 强制作废（内存 + 磁盘）。
class FeedCache {
  FeedCache._();

  static final Map<String, (Object, DateTime)> _m = {};
  static const ttl = Duration(minutes: 5);
  static const diskTtl = Duration(hours: 24);
  static Directory? _dir;

  static Future<void> init() async {
    try {
      final base = await getApplicationSupportDirectory();
      final d = Directory('${base.path}/feed_cache');
      if (!await d.exists()) await d.create(recursive: true);
      _dir = d;
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

  static T? get<T>(String k) {
    final e = _m[k];
    if (e != null) {
      if (DateTime.now().difference(e.$2) > ttl) {
        _m.remove(k);
      } else {
        return e.$1 as T?;
      }
    }
    // 内存未命中 → 尝试磁盘（24 小时内有效）
    final d = _readDisk(k);
    if (d is Object && d is T) {
      _m[k] = (d, DateTime.now());
      return d as T;
    }
    return null;
  }

  static void set(String k, Object v) {
    _m[k] = (v, DateTime.now());
    _writeDisk(k, v);
  }

  /// 删除某个键（下拉刷新时强制重新拉取，内存 + 磁盘一起作废）。
  static void invalidate(List<Object?> parts) {
    final k = key(parts);
    _m.remove(k);
    try {
      final f = _file(k);
      if (f != null && f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 带缓存的异步取值：命中（内存或磁盘）直接返回，未命中执行 [fetch] 并写缓存。
  static Future<T> reach<T>(String k, Future<T> Function() fetch) async {
    final hit = get<T>(k);
    if (hit != null) return hit;
    final v = await fetch();
    if (v is Object) set(k, v); // T 为可空类型时不缓存 null
    return v;
  }

  // ---------------- 磁盘编解码（类型按键前缀区分） ----------------

  static Object? _readDisk(String k) {
    try {
      final f = _file(k);
      if (f == null || !f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final ts = j['ts'] as int? ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > diskTtl.inMilliseconds) {
        f.deleteSync();
        return null;
      }
      return _decode(k, j['v']);
    } catch (_) {
      return null;
    }
  }

  static void _writeDisk(String k, Object v) {
    try {
      final f = _file(k);
      if (f == null) return;
      // 与读取侧一致用同步写（几十 KB 级，无感知）
      f.writeAsStringSync(
          jsonEncode({'ts': DateTime.now().millisecondsSinceEpoch, 'v': _encode(k, v)}));
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
    if (t == 'rank' || t == 'booklists') {
      final m = v as Map<String, dynamic>;
      final items = (m['items'] as List).cast<Map<String, dynamic>>();
      final next = m['nextUrl'] as String?;
      return t == 'rank'
          ? Paged<Book>(items: items.map(Book.fromJson).toList(), nextUrl: next)
          : Paged<BooklistEntry>(
              items: items.map(BooklistEntry.fromJson).toList(), nextUrl: next);
    }
    final items = (v as List).cast<Map<String, dynamic>>();
    return t == 'rankTabs'
        ? items.map(RankTab.fromJson).toList()
        : items.map(Book.fromJson).toList();
  }
}
