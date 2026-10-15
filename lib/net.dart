import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart';
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

  /// 共享 Client：keep-alive 连接复用（11 源并行搜索/聚合发现页大量同域请求，
  /// 每请求新建 Client 会重复 TCP+TLS 握手）。进程级单例，不 close。
  static final http.Client _client = http.Client();

  /// 供站外零散 GET（封面图等）复用同一连接池。
  static http.Client get client => _client;

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
    final r = await _client
        .get(Uri.parse(url), headers: _headers(url, referer: referer))
        .timeout(_timeout);
    _absorbCookies(url, r);
    return Resp(r.statusCode, decodeBody(r.bodyBytes), url,
        r.headers.containsKey('set-cookie'));
  }

  /// 解 HTTP 正文字符集：真 UTF-8 直接通过，解不动才按 GBK 兜底。
  ///
  /// 不看页面 meta 声明：有的站（伪速读谷章节页）meta 写 gb2312、实际发
  /// UTF-8，按声明重解会把好页面解成乱码。GBK 字节几乎不可能整页通过
  /// 严格 UTF-8 校验，所以先试 UTF-8 判得更准。
  static String decodeBody(List<int> bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return gbkFallback(bytes);
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
    final r = await _client
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
  }

  /// GBK 容错解码：真 GBK 解码（fast_gbk，与 legado/http_client 同一条链），
  /// 失败退回宽松 UTF-8 —— 旧实现拿 latin1 兜底，GBK 站正文全是乱码。
  static String gbkFallback(List<int> bytes) {
    try {
      return gbk.decode(bytes);
    } catch (_) {
      return utf8.decode(bytes, allowMalformed: true);
    }
  }
}
