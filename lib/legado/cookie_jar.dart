// Cookie 仓库（对齐 legado 的 CookieManager / CookieStoreEntity）。
//
// 为什么要做：书源脚本里 `java.getCookie(url)` / `cookie.setCookie(url, …)` /
// `cookie.removeCookie(url)` 是常见套路（124 个主流源里 8 个用到，包含晋江、
// 爱丽丝书屋、篱笆好文学这类必须登录态的站）。同时站点下发的会话 Cookie 必须
// **跨请求、跨重启**保留，否则：
//   - Cloudflare / 盾类站点每次请求都被判为新会话 → 403 挑战；
//   - 需要先访问首页拿 PHPSESSID 才能搜的站，POST 与 GET 落到不同会话；
//   - 登录态（书源 `loginUrl` + 手动登录）重启即失效。
//
// 与旧实现的差别（原来是 http_client.dart 里的内存 Map<host, Map<name, value>>）：
//   - 按 RFC 6265 记录 domain / path / expires / secure / hostOnly，而不是只按 host；
//   - 子域可见（`.example.com` 下发的 Cookie 对 `www.example.com` 有效）；
//   - 处理 Max-Age / Expires / 删除语义（值空或过期即移除）；
//   - 落盘 <files>/cookies.json，重启仍在；
//   - 提供脚本 API：getFor / setFor / removeFor（对应 java.getCookie 等）。
//
// 落盘结构：
//   {"version":1,"cookies":[{"n":名称,"v":值,"d":域,"p":路径,"e":过期毫秒,"s":secure,"h":hostOnly}]}
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../platform/native_bridge.dart';

/// 单条 Cookie。
class LegadoCookie {
  LegadoCookie({
    required this.name,
    required this.value,
    required this.domain,
    this.path = '/',
    this.expiresAt,
    this.secure = false,
    this.hostOnly = true,
  });

  final String name;
  String value;
  final String domain;
  final String path;

  /// 过期时间（null = 会话 Cookie，进程内有效）。
  DateTime? expiresAt;
  final bool secure;

  /// true：只对下发它的主机有效（未写 `Domain=` 的默认行为）。
  final bool hostOnly;

  String get key => '$domain|$path|$name';

  bool get expired {
    final e = expiresAt;
    return e != null && e.isBefore(DateTime.now());
  }

  Map<String, dynamic> toJson() => {
        'n': name,
        'v': value,
        'd': domain,
        'p': path,
        if (expiresAt != null) 'e': expiresAt!.millisecondsSinceEpoch,
        if (secure) 's': true,
        if (hostOnly) 'h': true,
      };

  static LegadoCookie? fromJson(Map<String, dynamic> m) {
    final n = m['n']?.toString() ?? '';
    final d = m['d']?.toString() ?? '';
    if (n.isEmpty || d.isEmpty) return null;
    final e = m['e'];
    return LegadoCookie(
      name: n,
      value: m['v']?.toString() ?? '',
      domain: d,
      path: m['p']?.toString() ?? '/',
      expiresAt: e is num
          ? DateTime.fromMillisecondsSinceEpoch(e.toInt())
          : null,
      secure: m['s'] == true,
      hostOnly: m['h'] == true,
    );
  }
}

/// Cookie 仓库（进程内单例，按需落盘）。
class LegadoCookieJar {
  LegadoCookieJar({AppDirs? dirsOverride}) : _dirsOverride = dirsOverride;

  static LegadoCookieJar? shared;

  /// 兜底单例：没初始化时也能用（只存内存）。
  static LegadoCookieJar get I => shared ??= LegadoCookieJar();

  final AppDirs? _dirsOverride;

  /// key = `domain|path|name`。
  final Map<String, LegadoCookie> _cookies = {};

  File? _file;
  Timer? _saveTimer;
  bool _loaded = false;
  bool _dirty = false;

  /// 总量上限：脚本偶尔会无脑 setCookie，不设上限会写爆磁盘。
  static const int maxCookies = 512;

  bool get loaded => _loaded;

  /// 当前保存的条数（诊断用）。
  int get length => _cookies.length;

  // ---------- HTTP 层接口 ----------

  /// 吸收响应的 `Set-Cookie`（支持多条、Expires 带逗号）。
  void absorb(Uri uri, Map<String, String> headers) {
    final raw = headers['set-cookie'] ?? headers['Set-Cookie'];
    if (raw == null || raw.isEmpty) return;
    var changed = false;
    for (final one in _splitSetCookie(raw)) {
      if (_absorbOne(uri, one)) changed = true;
    }
    if (changed) _saveSoon();
  }

  /// 构造请求头里的 `Cookie` 值；无匹配返回 null。
  String? headerFor(Uri uri) {
    final matched = <LegadoCookie>[];
    for (final c in _cookies.values.toList()) {
      if (!_matches(c, uri)) continue;
      if (c.expired) {
        _cookies.remove(c.key);
        _dirty = true;
        continue;
      }
      matched.add(c);
    }
    if (_dirty) {
      _dirty = false;
      _saveSoon();
    }
    if (matched.isEmpty) return null;
    // 长路径优先（RFC 6265 §5.4 的建议顺序）
    matched.sort((a, b) => b.path.length.compareTo(a.path.length));
    return matched.map((c) => '${c.name}=${c.value}').join('; ');
  }

  // ---------- 脚本层接口（java.getCookie / cookie.*） ----------

  /// `java.getCookie(tag)`：返回该地址的 Cookie 串；带 [key] 时返回单值。
  String getFor(String url, [String? key]) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return '';
    final all = headerFor(uri) ?? '';
    if (key == null || key.isEmpty) return all;
    for (final part in all.split(';')) {
      final p = part.trim();
      if (p.startsWith('$key=')) return p.substring(key.length + 1);
    }
    return '';
  }

  /// `cookie.setCookie(tag, 'a=1; b=2')`：按地址写入一组 Cookie。
  void setFor(String url, String cookieString) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return;
    if (cookieString.trim().isEmpty) {
      removeFor(url);
      return;
    }
    var changed = false;
    for (final part in cookieString.split(';')) {
      final p = part.trim();
      final eq = p.indexOf('=');
      if (eq <= 0) continue;
      final name = p.substring(0, eq).trim();
      final value = p.substring(eq + 1).trim();
      if (name.isEmpty) continue;
      _put(
        LegadoCookie(
          name: name,
          value: value,
          domain: uri.host.toLowerCase(),
          path: _defaultPath(uri),
        ),
      );
      changed = true;
    }
    if (changed) _saveSoon();
  }

  /// `cookie.removeCookie(tag)`：清掉该地址可见的全部 Cookie。
  void removeFor(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null || uri.host.isEmpty) return;
    final doomed = _cookies.values.where((c) => _matches(c, uri)).toList();
    for (final c in doomed) {
      _cookies.remove(c.key);
    }
    if (doomed.isNotEmpty) _saveSoon();
  }

  /// 书源被删除 / 用户点「清空 Cookie」时整体清空。
  void clear() {
    if (_cookies.isEmpty) return;
    _cookies.clear();
    _saveSoon();
  }

  // ---------- 落盘 ----------

  Future<void> load() async {
    final dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${dirs.files}/cookies.json');
    try {
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        final list = (data is Map) ? data['cookies'] : null;
        if (list is List) {
          for (final e in list) {
            if (e is! Map) continue;
            final c = LegadoCookie.fromJson(Map<String, dynamic>.from(e));
            if (c != null && !c.expired) _cookies[c.key] = c;
          }
        }
      }
    } catch (_) {
      // 读失败就以空仓启动，站点会重新下发
    }
    _loaded = true;
  }

  /// 立即落盘（测试与退出前调用）。
  Future<void> flush() => _save();

  void _saveSoon() {
    if (_file == null && _dirsOverride == null) return; // 没初始化：只存内存
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 1200), () {
      unawaited(_save());
    });
  }

  Future<void> _save() async {
    var file = _file;
    if (file == null) {
      final d = _dirsOverride;
      if (d == null) return;
      file = _file = File('${d.files}/cookies.json');
    }
    try {
      await file.parent.create(recursive: true);
      final tmp = File('${file.path}.tmp');
      await tmp.writeAsString(jsonEncode({
        'version': 1,
        'cookies': [for (final c in _cookies.values) c.toJson()],
      }));
      await tmp.rename(file.path);
    } catch (_) {
      // 忽略保存失败
    }
  }

  // ---------- 内部 ----------

  void _put(LegadoCookie c) {
    if (c.value.isEmpty || c.expired) {
      _cookies.remove(c.key);
      return;
    }
    if (!_cookies.containsKey(c.key) && _cookies.length >= maxCookies) {
      // 先踢过期，再按插入序踢最老
      _cookies.removeWhere((_, v) => v.expired);
      while (_cookies.length >= maxCookies) {
        _cookies.remove(_cookies.keys.first);
      }
    }
    _cookies[c.key] = c;
  }

  bool _absorbOne(Uri uri, String raw) {
    final parts = raw.split(';');
    if (parts.isEmpty) return false;
    final first = parts.first.trim();
    final eq = first.indexOf('=');
    if (eq <= 0) return false;
    final name = first.substring(0, eq).trim();
    var value = first.substring(eq + 1).trim();
    if (name.isEmpty) return false;
    if (value.length > 4096) value = value.substring(0, 4096);

    var domain = uri.host.toLowerCase();
    var hostOnly = true;
    var path = _defaultPath(uri);
    DateTime? expires;
    var secure = uri.scheme == 'https';
    for (final p in parts.skip(1)) {
      final t = p.trim();
      if (t.isEmpty) continue;
      final i = t.indexOf('=');
      final k = (i < 0 ? t : t.substring(0, i)).trim().toLowerCase();
      final v = i < 0 ? '' : t.substring(i + 1).trim();
      switch (k) {
        case 'domain':
          final d = v.replaceFirst(RegExp(r'^\.'), '').toLowerCase();
          if (d.isNotEmpty) {
            domain = d;
            hostOnly = false;
          }
        case 'path':
          if (v.startsWith('/')) path = v;
        case 'max-age':
          final secs = int.tryParse(v);
          if (secs != null) {
            expires = DateTime.now().add(Duration(seconds: secs));
          }
        case 'expires':
          final e = _parseHttpDate(v);
          if (e != null) expires = e;
        case 'secure':
          secure = true;
      }
    }
    // 子域校验：Domain 必须是当前主机的父域，否则丢弃（防跨站注入）
    if (!hostOnly && !_domainMatch(uri.host.toLowerCase(), domain)) {
      return false;
    }
    final c = LegadoCookie(
      name: name,
      value: value,
      domain: domain,
      path: path,
      expiresAt: expires,
      secure: secure,
      hostOnly: hostOnly,
    );
    final existed = _cookies.containsKey(c.key);
    _put(c);
    return existed || _cookies.containsKey(c.key);
  }

  bool _matches(LegadoCookie c, Uri uri) {
    final host = uri.host.toLowerCase();
    if (c.hostOnly) {
      if (host != c.domain) return false;
    } else if (!_domainMatch(host, c.domain)) {
      return false;
    }
    if (c.secure && uri.scheme != 'https') return false;
    final p = uri.path.isEmpty ? '/' : uri.path;
    if (c.path == '/') return true;
    if (!p.startsWith(c.path)) return false;
    // `/foo` 不该匹配 `/foobar`
    if (p.length > c.path.length &&
        !c.path.endsWith('/') &&
        p[c.path.length] != '/') {
      return false;
    }
    return true;
  }

  static bool _domainMatch(String host, String domain) =>
      host == domain || host.endsWith('.$domain');

  static String _defaultPath(Uri uri) {
    final p = uri.path;
    if (p.isEmpty || !p.startsWith('/')) return '/';
    final i = p.lastIndexOf('/');
    return i <= 0 ? '/' : p.substring(0, i);
  }

  /// 拆分多枚 Set-Cookie：Expires 里的 `Wed, 21 Oct 2025 ...` 也含逗号。
  static List<String> _splitSetCookie(String raw) {
    final out = <String>[];
    var start = 0;
    for (var i = 0; i < raw.length; i++) {
      if (raw[i] != ',') continue;
      // 逗号后面必须紧跟 `name=`（而不是日期），才算分隔符
      final rest = raw.substring(i + 1);
      final m = RegExp(r'^\s*[^=;,\s]+\s*=').hasMatch(rest);
      if (!m) continue;
      out.add(raw.substring(start, i));
      start = i + 1;
    }
    out.add(raw.substring(start));
    return out.where((e) => e.trim().isNotEmpty).toList();
  }

  static DateTime? _parseHttpDate(String v) {
    final t = v.trim();
    if (t.isEmpty) return null;
    // 常见格式：Wed, 21 Oct 2025 07:28:00 GMT
    const months = {
      'jan': 1,
      'feb': 2,
      'mar': 3,
      'apr': 4,
      'may': 5,
      'jun': 6,
      'jul': 7,
      'aug': 8,
      'sep': 9,
      'oct': 10,
      'nov': 11,
      'dec': 12,
    };
    final m = RegExp(
      r'(\d{1,2})[-\s]([A-Za-z]{3})[-\s](\d{2,4})\s+(\d{1,2}):(\d{2}):(\d{2})',
    ).firstMatch(t);
    if (m == null) return DateTime.tryParse(t);
    final mon = months[m.group(2)!.toLowerCase()];
    if (mon == null) return null;
    var year = int.parse(m.group(3)!);
    if (year < 100) year += 2000;
    return DateTime.utc(
      year,
      mon,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    );
  }
}
