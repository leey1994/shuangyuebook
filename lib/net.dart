import 'dart:convert';

import 'package:http/http.dart' as http;

/// HTTP 响应封装。
class Resp {
  final int status;
  final String body;
  final String url;
  final bool setCookie; // 本次响应是否下发了 Set-Cookie
  const Resp(this.status, this.body, this.url, this.setCookie);
}

/// 带 UA / Cookie jar / 黄金屋浏览器检查重试 的 HTTP 客户端。
class Net {
  static const _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  static const _timeout = Duration(seconds: 20);

  /// host -> "k=v; k2=v2"
  static final Map<String, String> _cookies = {};

  static bool hasCookiesFor(String url) {
    final host = Uri.parse(url).host;
    return (_cookies[host] ?? '').isNotEmpty;
  }

  static Map<String, String> _headers(String url, {String? referer}) {
    final host = Uri.parse(url).host;
    final h = <String, String>{
      'User-Agent': _ua,
      'Accept':
          'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
      'Accept-Language': 'zh-CN,zh;q=0.9',
    };
    final c = _cookies[host];
    if (c != null && c.isNotEmpty) h['Cookie'] = c;
    if (referer != null) h['Referer'] = referer;
    return h;
  }

  static void _absorbCookies(String url, http.Response r) {
    final host = Uri.parse(url).host;
    final sc = r.headers['set-cookie'];
    if (sc == null || sc.isEmpty) return;
    final jar = StringBuffer();
    if ((_cookies[host] ?? '').isNotEmpty) {
      jar.write(_cookies[host]);
      jar.write('; ');
    }
    final seen = <String>{};
    for (final m in RegExp(r'([^;,=\s]+)=([^;,]*)').allMatches(sc)) {
      final name = m.group(1)!.trim();
      if (name.toLowerCase() == 'path' ||
          name.toLowerCase() == 'expires' ||
          name.toLowerCase() == 'max-age' ||
          name.toLowerCase() == 'domain' ||
          name.toLowerCase() == 'httponly' ||
          name.toLowerCase() == 'samesite' ||
          name.toLowerCase() == 'secure') {
        continue;
      }
      if (!seen.add(name)) continue;
      jar.write(name);
      jar.write('=');
      jar.write(m.group(2)!.trim());
      jar.write('; ');
    }
    if (jar.isNotEmpty) _cookies[host] = jar.toString().trim();
  }

  /// JS 种 cookie 挑战页（素书卷/神文/智能书库同 CMS：200 + 短 body +
  /// `document.cookie = "..."` 后 `location.reload`）。
  static bool _isJsChallenge(Resp r) =>
      r.status == 200 &&
      r.body.length < 4000 &&
      r.body.contains('document.cookie = "') &&
      r.body.contains('window.location.reload');

  static bool _needsRetry(Resp r) =>
      r.body.contains('正在检查您的浏览器') || _isJsChallenge(r);

  /// 把挑战页里的每个 `document.cookie = "k=v"` 种进 jar（同名覆盖）。
  static void _absorbJsChallengeCookie(String url, String body) {
    final host = Uri.parse(url).host;
    for (final m
        in RegExp(r'document\.cookie\s*=\s*"([^"]+)"').allMatches(body)) {
      for (final kv in m.group(1)!.split(';')) {
        final i = kv.indexOf('=');
        if (i <= 0) continue;
        final k = kv.substring(0, i).trim();
        final v = kv.substring(i + 1).trim();
        final parts = <String>[];
        for (final seg in (_cookies[host] ?? '').split(';')) {
          final s = seg.trim();
          if (s.isEmpty) continue;
          final eq = s.indexOf('=');
          final name = eq > 0 ? s.substring(0, eq) : s;
          if (name == k) continue;
          parts.add(s);
        }
        parts.add('$k=$v');
        _cookies[host] = parts.join('; ');
      }
    }
  }

  /// GET；浏览器检查/JS 种 cookie 挑战则解锁后重试（最多 4 轮，兼容多轮种罐）。
  static Future<Resp> get(String url, {String? referer}) async {
    var r = await _get(url, referer: referer);
    var guard = 0;
    while (guard < 4 && _needsRetry(r)) {
      if (_isJsChallenge(r)) {
        _absorbJsChallengeCookie(url, r.body);
      } else {
        // 黄金屋「浏览器检查」：带 __sc_clearance=1 重试
        final host = Uri.parse(url).host;
        final jar = _cookies[host] ?? '';
        if (!jar.contains('__sc_clearance')) {
          _cookies[host] = '$jar; __sc_clearance=1'.trim();
        }
      }
      r = await _get(url, referer: referer);
      guard++;
    }
    return r;
  }

  static Future<Resp> _get(String url, {String? referer}) async {
    final client = http.Client();
    try {
      final r = await client
          .get(Uri.parse(url), headers: _headers(url, referer: referer))
          .timeout(_timeout);
      _absorbCookies(url, r);
      var body = utf8.decode(r.bodyBytes, allowMalformed: true);
      // 个别页面声明 gbk/GB2312 时兜底（四站均 UTF-8，此为容错）
      if (body.contains('charset=gb') || body.contains('charset=GB')) {
        body = gbkFallback(r.bodyBytes);
      }
      return Resp(r.statusCode, body, url, r.headers.containsKey('set-cookie'));
    } finally {
      client.close();
    }
  }

  /// POST 表单（yewa /api/search 等）；同样支持 JS 种 cookie 挑战多轮解锁。
  static Future<Resp> postForm(
    String url,
    Map<String, String> body, {
    String? referer,
  }) async {
    var r = await _post(url, body, referer: referer);
    var guard = 0;
    while (guard < 4 && _isJsChallenge(r)) {
      _absorbJsChallengeCookie(url, r.body);
      r = await _post(url, body, referer: referer);
      guard++;
    }
    return r;
  }

  static Future<Resp> _post(
    String url,
    Map<String, String> body, {
    String? referer,
  }) async {
    final client = http.Client();
    try {
      final r = await client
          .post(
            Uri.parse(url),
            headers: _headers(url, referer: referer)
              ..['Content-Type'] = 'application/x-www-form-urlencoded; charset=UTF-8'
              ..['X-Requested-With'] = 'XMLHttpRequest',
            body: body,
          )
          .timeout(_timeout);
      _absorbCookies(url, r);
      return Resp(
        r.statusCode,
        utf8.decode(r.bodyBytes, allowMalformed: true),
        url,
        r.headers.containsKey('set-cookie'),
      );
    } finally {
      client.close();
    }
  }

  /// 极简 GBK 容错：按字节高位猜测。仅在非 UTF-8 声明时使用。
  static String gbkFallback(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      // 无法精确解码时保留原始替换字符，避免整体失败
      return latin1.decode(bytes);
    }
  }
}
