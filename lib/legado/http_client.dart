// 请求层：超时 / 重试 / 编码探测（UTF-8 与 GBK）/ 请求头 / Cookie / 简单限流。
//
// 设计目标（对照 Legado 的公开行为，独立实现）：
// - 书源站点编码混杂（UTF-8 / GBK），需要按 响应头 → 页面 meta → 兜底探测 的顺序解码；
// - 每源可配置并发率（concurrentRate：`N/M` 表示 M 秒最多 N 次请求）；
// - Cookie 暂存于内存（enabledCookieJar 的基础形态，后续里程碑再持久化）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fast_gbk/fast_gbk.dart';
import 'package:http/http.dart' as http;

import 'cookie_jar.dart';

/// 一次请求的响应。
class SourceResponse {
  SourceResponse({
    required this.statusCode,
    required this.body,
    required this.bytes,
    required this.headers,
    required this.finalUrl,
  });

  final int statusCode;

  /// 按检测到的编码解码后的正文。
  final String body;

  /// 原始字节（保存封面等二进制场景备用）。
  final Uint8List bytes;

  final Map<String, String> headers;

  /// 重定向后的最终地址。
  final String finalUrl;

  bool get ok => statusCode >= 200 && statusCode < 300;
}

/// 请求失败（网络层）。
class SourceHttpException implements Exception {
  SourceHttpException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 轻量请求客户端。
class SourceHttpClient {
  SourceHttpClient({http.Client? client, Duration? timeout})
      : _client = client ?? sharedClient,
        defaultTimeout = timeout ?? const Duration(seconds: 15);

  /// 进程级共享连接池。
  ///
  /// 书源管理页每改动一次就会重建全部 [LegadoSource]，若每个实例各建一个
  /// http.Client，反复启停书源会不断泄漏连接池。爽阅的 Net 也是同样做法。
  static final http.Client sharedClient = http.Client();

  final http.Client _client;
  final Duration defaultTimeout;
  /// 进程级 Cookie 仓库（落盘到 <files>/cookies.json，脚本也能读写）。
  LegadoCookieJar get _cookies => LegadoCookieJar.I;

  /// GET。
  Future<SourceResponse> get(
    String url, {
    Map<String, String>? headers,
    String? charset,
    Duration? timeout,
    int retries = 1,
  }) =>
      request(
        'GET',
        url,
        headers: headers,
        charset: charset,
        timeout: timeout,
        retries: retries,
      );

  /// POST（body 为原始字符串，通常已在模板层渲染好）。
  Future<SourceResponse> post(
    String url, {
    Map<String, String>? headers,
    String? body,
    String? charset,
    Duration? timeout,
    int retries = 1,
  }) =>
      request(
        'POST',
        url,
        headers: headers,
        body: body,
        charset: charset,
        timeout: timeout,
        retries: retries,
      );

  /// 解析 `data:[<mediatype>][;base64],<payload>`，本地生成响应。
  ///
  /// 对齐上游 `AnalyzeUrl.getByteArrayIfDataUri`：只处理带 `;base64` 的形式，
  /// 解出的字节再按 响应头/meta → UTF-8 的顺序解码成正文。
  static SourceResponse? _decodeDataUri(String url, String? charset) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) {
      throw SourceHttpException('无效的 data URI（缺少逗号）：${_clipUrl(url)}');
    }
    final meta = url.substring(5, comma);
    final payload = url.substring(comma + 1);
    Uint8List bytes;
    try {
      if (meta.toLowerCase().contains(';base64')) {
        final raw = payload.replaceAll(RegExp(r'\s'), '');
        bytes = base64Decode(base64Url.normalize(raw));
      } else {
        bytes = Uint8List.fromList(utf8.encode(Uri.decodeFull(payload)));
      }
    } catch (err) {
      throw SourceHttpException('无效的 data URI（base64 解码失败）：${_clipUrl(url)}');
    }
    final cs = charset ?? _charsetFromContentType(meta) ?? _sniffCharset(bytes);
    return SourceResponse(
      statusCode: 200,
      body: _decodeWith(bytes, cs),
      bytes: bytes,
      headers: {if (meta.isNotEmpty) 'content-type': meta},
      // 空串让调用方回退到书源里的原始地址做 baseUrl（data: 没有可用的主机）。
      finalUrl: '',
    );
  }

  static String _clipUrl(String u) => u.length <= 80 ? u : '${u.substring(0, 80)}…';

  /// 通用请求（带重试与 Cookie）。
  Future<SourceResponse> request(
    String method,
    String url, {
    Map<String, String>? headers,
    String? body,
    String? charset,
    Duration? timeout,
    int retries = 1,
  }) async {
    // 协议相对地址（//host/path）按 https 补全：老缓存与少数书源会漏掉 scheme，
    // 这里兜底，避免整章/整本书因为「无效的地址」打不开。
    final u = url.trim();
    // legado 的 data: URI：脚本（番茄小说 fqSearchUrl、七猫聚合等）自己用
    // java.ajax 拿到数据后，把结果以 base64 塞进 data: URI 交回规则管线，
    // 由上游 AnalyzeUrl.getByteArrayIfDataUri 本地解码、完全不发请求。
    final inline = _decodeDataUri(u, charset);
    if (inline != null) return inline;
    final normalized = u.startsWith('//') ? 'https:$u' : u;
    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme) {
      throw SourceHttpException('无效的地址：$url');
    }
    var attempt = 0;
    // JS 校验挑战页的 cookie：拿到后要带在同一次重试里（见 _jsCookieChallenge）。
    String? challengeCookie;
    var challengeTried = false;
    while (true) {
      attempt++;
      try {
        final h = <String, String>{
          // 默认 UA 对齐 legado AppConfig.getPrefUserAgent（CronetMainVersion=128.0.0.0）：
          // 桌面 Windows Chrome。移动 UA 会让部分站点返回移动版页面，与书源规则错位。
          'User-Agent':
              'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36',
          ...?headers,
        };
        final cookie = _cookies.headerFor(uri);
        final parts = <String>[
          if (cookie != null && cookie.isNotEmpty) cookie,
          if (challengeCookie != null) challengeCookie,
        ];
        if (parts.isNotEmpty) {
          h['Cookie'] = parts.join('; ');
        }
        // 浏览器行为：缺省带同源 Referer（部分站的防盗链/来源校验只认它）。
        if (uri.hasScheme && !_hasHeader(h, 'referer')) {
          h['Referer'] = '${uri.scheme}://${uri.host}/';
        }
        final bodyBytes = body == null ? null : _encodeBody(body, charset);
        // 书源的 POST 大多只写 `,{"method":"POST","body":...}` 不给 Content-Type，
        // PHP 站没有表单头会解析不到参数（实测抖音/速读谷收不到关键词）→ 默认补齐。
        if (bodyBytes != null && !_hasHeader(h, 'content-type')) {
          // JSON 串（对象/数组开头）按 JSON 发送（QQ 系 API 校验 Content-Type），
          // 其余维持表单默认（PHP 站没有表单头解析不到参数）。
          final t = body!.trimLeft();
          h['content-type'] = (t.startsWith('{') || t.startsWith('['))
              ? 'application/json; charset=UTF-8'
              : _formContentType(charset);
        }
        _sanitizeHeaders(h);
        http.Response resp;
        final t = timeout ?? defaultTimeout;
        if (method == 'POST') {
          resp =
              await _client.post(uri, headers: h, body: bodyBytes).timeout(t);
        } else if (method == 'GET') {
          resp = await _client.get(uri, headers: h).timeout(t);
        } else {
          final req = http.Request(method, uri);
          req.headers.addAll(h);
          if (bodyBytes != null) req.bodyBytes = bodyBytes;
          resp = await http.Response.fromStream(
            await _client.send(req).timeout(t),
          );
        }
        _cookies.absorb(uri, resp.headers);
        final decoded = decodeBody(resp.bodyBytes, resp.headers, charset);
        var out = SourceResponse(
          statusCode: resp.statusCode,
          body: decoded,
          bytes: resp.bodyBytes,
          headers: resp.headers,
          finalUrl: resp.request?.url.toString() ?? url,
        );
        // 少数站点返回 30x 却不带可跟随的 Location（或 Location 含裸中文/空格），
        // http 包会原样把它交回来 —— 这里按 RFC 自行跟随，最多 3 跳。
        var hops = 0;
        while (out.statusCode >= 300 &&
            out.statusCode < 400 &&
            hops < 3 &&
            _hasHeader(out.headers, 'location')) {
          final loc = out.headers['location']!.trim();
          final next = _parseRedirect(uri, loc);
          if (next == null) break;
          hops++;
          final follow = await _client
              .get(next, headers: h)
              .timeout(timeout ?? defaultTimeout);
          _cookies.absorb(next, follow.headers);
          out = SourceResponse(
            statusCode: follow.statusCode,
            body: decodeBody(follow.bodyBytes, follow.headers, charset),
            bytes: follow.bodyBytes,
            headers: follow.headers,
            finalUrl: follow.request?.url.toString() ?? next.toString(),
          );
        }
        // 有些站点的「反爬校验」其实只是 set-cookie + reload（神文小说
        // 的 ge_js_validator）：取出那条 cookie 重发一次即可，不必真跑 JS。
        // 只对短小的 GET 响应做一次，避免正常页误判。
        if (!challengeTried &&
            method == 'GET' &&
            out.statusCode == 200 &&
            out.body.length < 4096) {
          final kv = _jsCookieChallenge(out.body);
          if (kv != null) {
            challengeTried = true;
            challengeCookie = kv;
            continue;
          }
        }
        // 5xx / 429 视为临时故障：按 retries 退避重试；4xx 不重试（规则/权限问题，重试无用）。
        if ((out.statusCode >= 500 || out.statusCode == 429) &&
            attempt <= retries) {
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
          continue;
        }
        return out;
      } on TimeoutException {
        if (attempt <= retries) continue;
        throw SourceHttpException(
          '请求超时（${(timeout ?? defaultTimeout).inSeconds}s）',
        );
      } on SocketException catch (e) {
        if (attempt <= retries) continue;
        throw SourceHttpException('网络错误：${e.message}');
      } on http.ClientException catch (e) {
        if (attempt <= retries) continue;
        throw SourceHttpException('请求失败：${e.message}');
      }
    }
  }

  /// 只关自己创建的连接池；共享的那个由进程生命周期托管，关了会影响全 App。
  void close() {
    if (_ownsClient) _client.close();
  }

  bool get _ownsClient => !identical(_client, sharedClient);
}

/// 识别「JS 校验」挑战页：`document.cookie = "k=v; path=/"` + `location.reload()`。
///
/// 这类站点（ge_js_validator / 神文小说）只是要求带一个 cookie 再请求一次，
/// 直接照 cookie 重发即可，不需要真的执行 JS。
String? _jsCookieChallenge(String body) {
  if (!body.contains('location.reload')) return null;
  final m = RegExp(r"""document\.cookie\s*=\s*["']([^"']+)["']""")
      .firstMatch(body);
  if (m == null) return null;
  final pair = m.group(1)!.split(';').first.trim();
  return pair.contains('=') ? pair : null;
}

/// 解析 30x 的 Location：容忍裸中文/空格（先按 RFC 3986 百分号编码再解析）。
Uri? _parseRedirect(Uri base, String loc) {
  if (loc.isEmpty) return null;
  final direct = Uri.tryParse(loc);
  if (direct != null && direct.hasScheme) return direct;
  final encoded = Uri.encodeFull(loc).replaceAll(' ', '%20');
  try {
    return base.resolve(encoded);
  } catch (_) {
    return null;
  }
}

/// 请求体编码：`charset` 为 GBK 系时按 GBK 编码（老 PHP 站常见），否则 UTF-8。
List<int> _encodeBody(String body, String? charset) {
  final cs = charset?.trim().toLowerCase() ?? '';
  if (cs.contains('gb')) {
    try {
      return gbk.encode(body);
    } catch (_) {
      // 含 GBK 无法表示的字符（emoji 等）→ 退回 UTF-8
    }
  }
  return utf8.encode(body);
}

String _formContentType(String? charset) {
  final cs = charset?.trim() ?? '';
  return cs.isEmpty
      ? 'application/x-www-form-urlencoded'
      : 'application/x-www-form-urlencoded; charset=$cs';
}

bool _hasHeader(Map<String, String> headers, String name) =>
    headers.keys.any((k) => k.toLowerCase() == name);

final _headerNameRe = RegExp(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$");

/// 清洗请求头：丢弃非 RFC 7230 token 的名字（实测有书源写了 U+2011 连字符的
/// `User‑Agent`，http 包会直接抛「无效的请求头」）与含换行的值（防注入）。
void _sanitizeHeaders(Map<String, String> headers) {
  headers.removeWhere((k, v) => !_headerNameRe.hasMatch(k) || v.contains('\n'));
  for (final k in headers.keys.toList()) {
    final v = headers[k]!;
    if (v.contains('\r')) headers[k] = v.replaceAll('\r', ' ');
  }
}

/// 解析 `concurrentRate`：`N/M`（M 秒 N 次）或 `N`（每秒 N 次）。
class RateGate {
  RateGate(String? concurrentRate) {
    final s = concurrentRate?.trim() ?? '';
    if (s.isEmpty) return;
    final parts = s.split('/');
    final n = int.tryParse(parts[0].trim());
    if (n == null || n <= 0) return;
    final m = parts.length > 1 ? (int.tryParse(parts[1].trim()) ?? 1) : 1;
    window = Duration(seconds: math.max(1, m));
    limit = n;
  }

  Duration? window;
  int limit = 0;
  final List<DateTime> _recent = [];

  bool get active => window != null && limit > 0;

  /// 在允许的速率内等待。
  Future<void> waitSlot() async {
    final w = window;
    if (w == null || limit <= 0) return;
    while (true) {
      final now = DateTime.now();
      _recent.removeWhere((t) => now.difference(t) > w);
      if (_recent.length < limit) {
        _recent.add(now);
        return;
      }
      final oldest = _recent.first;
      final wait = w - now.difference(oldest);
      await Future<void>.delayed(wait.isNegative ? Duration.zero : wait);
    }
  }
}

// ---------- 编码解码 ----------

/// 解码响应正文：
/// 显式 charset → Content-Type → meta 探测 → UTF-8 严格 → GBK → UTF-8 宽松。
String decodeBody(
  Uint8List bytes,
  Map<String, String>? headers, [
  String? charsetHint,
]) {
  var cs = charsetHint?.toLowerCase().trim();
  cs ??= _charsetFromContentType(headers?['content-type']);
  cs ??= _sniffCharset(bytes);
  return _decodeWith(bytes, cs);
}

String? _charsetFromContentType(String? contentType) {
  if (contentType == null) return null;
  final m = RegExp(
    r'charset\s*=\s*["\x27]?([\w-]+)',
    caseSensitive: false,
  ).firstMatch(contentType);
  return m?.group(1)?.toLowerCase();
}

String? _sniffCharset(Uint8List bytes) {
  final n = math.min(bytes.length, 2048);
  final head = latin1.decode(bytes.sublist(0, n), allowInvalid: true);
  final m = RegExp(
    r'charset\s*=\s*["\x27]?\s*([\w-]+)',
    caseSensitive: false,
  ).firstMatch(head);
  return m?.group(1)?.toLowerCase();
}

String _decodeWith(Uint8List bytes, String? cs) {
  if (cs != null) {
    if (cs.contains('gb')) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        // 落到兜底
      }
    }
    if (cs.contains('utf')) {
      try {
        return utf8.decode(bytes);
      } catch (_) {
        // 落到兜底
      }
    }
  }
  // 兜底链：严格 UTF-8 → GBK → 宽松 UTF-8
  try {
    return utf8.decode(bytes);
  } catch (_) {}
  try {
    final t = gbk.decode(bytes);
    if (!t.contains('\uFFFD')) return t;
  } catch (_) {}
  return utf8.decode(bytes, allowMalformed: true);
}

