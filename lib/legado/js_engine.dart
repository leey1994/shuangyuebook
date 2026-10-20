// P0 对齐 legado（对照 gedoor/legado 的 JsExtensions / JsEncodeUtils / AnalyzRule.evalJS 公开行为）：
// QuickJS（quickjs_engine，QuickJS-NG）同步 FFI 引擎接入。
//
// 职责：
//  1. 书源 JS 求值：@js / <js> / {{}} / jsLib，同一运行时内共享全局作用域
//     （对齐 legado 的「书源级 shareScope」：jsLib 定义全局函数，后续脚本可直接调用）；
//  2. java.* / cookie / cache 最小子集：通过 sendMessage 同步桥回调 Dart
//     （对齐 JsExtensions 与 JsEncodeUtils 的函数名与行为）；
//  3. java.ajax / java.webView 的「挂起—补网—重跑」模型：
//     脚本内调用 → Dart 无缓存时返回 suspend 标记 → JS 抛 __JSSUSP__ 错误
//     → Dart 抛 JsSuspendException → 服务层异步取数写入 JsSession 缓存
//     → 重跑脚本（会话内冻结 Date.now，保证重跑生成的 URL 稳定）→ 命中缓存继续。
//
// 边界：无脚本超时中断（QuickJS 中断句柄未暴露，由服务层控制来源）；ttf 反混淆为 P2（桥已预留）。
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fast_gbk/fast_gbk.dart';
import 'package:flutter/foundation.dart';
import 'package:pointycastle/export.dart' as pc;
import 'package:quickjs_engine/quickjs_engine.dart';

import 'source_vars.dart';
import 'cookie_jar.dart';

import 'java_compat.dart';
import 'java_compat_js.dart';

/// 书源 JS 求值会话：一次高层操作（搜索/详情/目录/正文/URL 构建）内共享。
///
/// 承载挂起补网缓存、变量与冻结时钟；服务层用 [runWithJsSession] 驱动重跑。
class JsSession {
  JsSession() : frozenNow = DateTime.now().millisecondsSinceEpoch;

  /// 冻结的“当前时间”：同一会话内重跑脚本时 Date.now() 保持稳定，
  /// 避免“脚本用时间戳拼 URL → 重跑时 URL 变化 → 缓存永远 miss”的死循环。
  final int frozenNow;

  /// java.ajax 补网缓存：请求键 → 响应文本。
  final Map<String, String> ajaxCache = {};

  /// java.ajax 补网元信息（请求键 → {code,url,headers}），供 Response 对象使用。
  final Map<String, Map<String, dynamic>> ajaxMeta = {};

  /// java.webView 渲染缓存（P2 规则化后由服务层写入）。
  final Map<String, String> webViewCache = {};

  /// java.put/get 内存变量（P2 起持久化到书/书源层级）。
  final Map<String, String> vars = {};

  /// cache.get/put（会话级）。
  final Map<String, String> cache = {};

  /// 已重跑次数（诊断用）。
  int rerun = 0;
}

/// 脚本挂起：等待服务层异步补网（ajax/webView）后重跑。
class JsSuspendException implements Exception {
  JsSuspendException(
    this.kind,
    this.target, {
    this.method = 'GET',
    this.headers = const {},
    this.body,
  });

  /// ajax | webview
  final String kind;

  /// 补网目标 URL。
  final String target;

  /// 请求方法（java.ajax({method:'POST'}) / java.post）。
  final String method;

  /// 请求头（书源显式指定，服务层再与书源公共头合并）。
  final Map<String, String> headers;

  /// 请求体（POST）。
  final String? body;

  @override
  String toString() =>
      'JsSuspendException($kind, $method $target${body == null ? '' : ' body=${body!.length}B'})';
}

/// JS 求值环境：书源/书籍/章节上下文 + 会话。
class JsEnv {
  JsEnv({
    this.scopeKey = '#default',
    this.sourceUrl = '',
    this.baseUrl,
    this.sourceName = '',
    this.sourceHeader,
    this.sourceJson,
    this.jsLib,
    this.book,
    this.chapter,
    this.title,
    this.nextChapterUrl,
    this.session,
    this.vars,
    this.getString,
    this.getElement,
    this.getElements,
    this.getCookie,
  });

  /// 运行时池键：书源 URL（同书源共享运行时/jsLib 作用域）。
  final String scopeKey;

  final String sourceUrl;

  /// baseUrl 绑定：当前解析页地址（legado AnalyzeRule 语义；缺省回落 sourceUrl）。
  final String? baseUrl;

  final String sourceName;
  final String? sourceHeader;

  /// 书源实体字段（`source.loginUrl` / `source.searchUrl` / `source.bookSourceComment`…）。
  ///
  /// 上游把整个 BookSource 实体绑给脚本，很多源靠它自举：例如爱丽丝书屋的
  /// `{{eval(String(source.loginUrl));GetUL();}}`（用 loginUrl 里的脚本初始化
  /// 站源变量），没有 loginUrl 就只能拼出相对地址 `/search.html?…`。
  final Map<String, dynamic>? sourceJson;

  /// 书源 jsLib：首次使用时在运行时内求值一次。
  final String? jsLib;

  /// book 绑定：{name, author, bookUrl}。
  final Map<String, dynamic>? book;

  /// chapter 绑定：{title, …}（目录逐项解析时挂当前章节；legado binding）。
  final Map<String, dynamic>? chapter;
  final String? title;
  final String? nextChapterUrl;
  final JsSession? session;

  /// 额外全局变量（page / key / keyword / searchKey / 自定义）。
  final Map<String, dynamic>? vars;

  /// java.getString(rule)：在调用方解析器上下文内对规则求值（同步、不递归 JS 段）。
  final String? Function(String rule)? getString;

  /// java.getElement(rule)：元素规则求值（v1 降级为 getString，P2 升级外链元素 Html）。
  final String? Function(String rule)? getElement;

  /// java.getElements(rule)：多元素规则求值，返回各元素 outerHtml。
  ///
  /// 上游 `getElements` 返回 jsoup `Elements`（可 `.size()/.get(i)` 迭代），
  /// 巴卡漫画的目录规则靠它一次拿全部章节 `li`，只给首个元素会丢章节。
  final List<String> Function(String rule)? getElements;

  /// cookie.getCookie(tag, key)：由服务层注入 CookieJar 读取器。
  final String? Function(String tag, String? key)? getCookie;

  /// 派生环境（URL/规则求值前合并 vars 等场景使用）。
  JsEnv copyWith({
    String? scopeKey,
    String? sourceUrl,
    String? baseUrl,
    String? sourceName,
    String? sourceHeader,
    Map<String, dynamic>? sourceJson,
    String? jsLib,
    Map<String, dynamic>? book,
    Map<String, dynamic>? chapter,
    String? title,
    String? nextChapterUrl,
    JsSession? session,
    Map<String, dynamic>? vars,
    String? Function(String rule)? getString,
    String? Function(String rule)? getElement,
    List<String> Function(String rule)? getElements,
    String? Function(String tag, String? key)? getCookie,
  }) =>
      JsEnv(
        scopeKey: scopeKey ?? this.scopeKey,
        sourceUrl: sourceUrl ?? this.sourceUrl,
        baseUrl: baseUrl ?? this.baseUrl,
        sourceName: sourceName ?? this.sourceName,
        sourceHeader: sourceHeader ?? this.sourceHeader,
        sourceJson: sourceJson ?? this.sourceJson,
        jsLib: jsLib ?? this.jsLib,
        book: book ?? this.book,
        chapter: chapter ?? this.chapter,
        title: title ?? this.title,
        nextChapterUrl: nextChapterUrl ?? this.nextChapterUrl,
        session: session ?? this.session,
        vars: vars ?? this.vars,
        getString: getString ?? this.getString,
        getElement: getElement ?? this.getElement,
        getElements: getElements ?? this.getElements,
        getCookie: getCookie ?? this.getCookie,
      );
}

/// 在会话下执行 [run]；脚本挂起时调用 [resolve] 补网后重跑。
///
/// [run] 可为同步闭包（规则流水线）或异步闭包（整段抓取流程）：
/// 挂起异常无论同步抛出还是随 Future 完成，都会被捕获并重跑。
Future<T> runWithJsSession<T>(
  JsSession session,
  FutureOr<T> Function() run,
  Future<void> Function(JsSuspendException e) resolve, {
  int maxRerun = 12,
}) async {
  while (true) {
    try {
      return await run();
    } on JsSuspendException catch (e) {
      session.rerun++;
      if (session.rerun > maxRerun) rethrow;
      await resolve(e);
    }
  }
}

class _Holder {
  _Holder(this.rt);

  final JavascriptRuntime rt;
  String? jsLibApplied;
  int usedAt = 0;
}

/// QuickJS 桥：运行时池 + java.* 同步桥 + 书源 JS 求值入口。
abstract final class JsBridge {
  static final Map<String, _Holder> _pool = {};
  static bool _libFailed = false;
  static JsEnv? _active;
  static int _tick = 0;
  static const int _poolMax = 8;

  /// 引擎是否可用（首次创建失败，如测试环境缺少 DLL，则整体降级）。
  static bool get available => !_libFailed;

  /// 求值一段书源 JS，返回字符串结果。
  ///
  /// 返回 null：引擎不可用或脚本报错（调用方按降级处理）。
  /// 抛出 [JsSuspendException]：脚本挂起，等待服务层补网后重跑。
  /// 最近一次脚本错误（求值开始时清空；供规则层判断是否退回降级路径）。
  static String? lastError;

  // ---------------------------------------------------------------------
  // P1-9：纯转换脚本结果缓存
  //
  // QuickJS 的 JS_Eval 每次都要「解析 + 编译 + 执行」整段源码，而上游 legado
  // 有 scriptCache（AnalyzeRule.kt:938-941）。引擎包只暴露 evaluate(String)，
  // 拿不到已编译 Script 句柄，因此在桥这一层缓存**结果**：
  // 键 = (源码, 上下文签名)，只对无副作用、无时间/随机/网络痕迹的纯脚本生效
  // （这类脚本占语料大多数：String(result).replace/match、base64、解码等）。
  // 命中即省掉一次完整编译 + 执行。
  // ---------------------------------------------------------------------

  static final Map<String, String> _resultCache = {};
  static const int _resultCacheMax = 256;
  static const int _resultCacheMaxLen = 64 * 1024;

  /// 出现这些痕迹说明脚本有副作用或结果不确定 → 不缓存。
  /// 注意：只排除 java.* 里真正带网络/会话副作用的调用，
  /// 纯编解码（`java.base64Decode`/`java.md5Encode` 等）仍可缓存。
  static const List<String> _kImpureMarks = [
    'java.ajax', 'java.webView', 'java.startBrowser', 'java.getCookie',
    'java.put', 'java.get(', 'java.cache', 'java.connect',
    'Date', // 时间
    'Math.random',
    'getString', 'getElement', 'getCookie', 'sendMessage',
    'fetch(', 'xhr', 'webview', 'cookie', 'cache',
    'put(', 'clear(',
  ];

  static bool _pureJs(String code) =>
      code.length <= 4096 && !_kImpureMarks.any(code.contains);

  // ---------------------------------------------------------------------
  // 大字符串结果分片取回
  //
  // 实测（test/scratch/threshold_test.dart）：桥的 `JS_Eval` 只能带回
  // 至多 8192 个 UTF-16 单元的字符串，超过即整体拿不到（返回 null 且无错误）。
  // 这让 `JSON.stringify(整页 JSON)`、`<js>换源后返回整段 HTML</js>` 这类
  // 规则静默变空（例如魔丸小说的 `bookList: <js>…JSON.stringify(result)</js>`
  // + `$.data.items`）。对齐 legado 的语义必须能取回任意长度的值，因此在
  // 脚本末尾把超长字符串挂到全局 `__lgBIG`，只回一个长度标记，Dart 侧再
  // 按 4000 单元分片取回（分片边界不劈开代理对）。
  // ---------------------------------------------------------------------

  /// 单次 `JS_Eval` 可安全带回的字符数（远低于 8192 实测上限）。
  static const int _kMaxEvalChars = 4000;

  /// 超长结果的标记前缀（`\u0001` 不会出现在正常书源结果里）。
  static const String _kBigMarker = '\u0001LG_BIG:';

  /// 脚本收尾：清理返回值；超长字符串转成标记 + 全局切片器。
  static const String _finalizeJs = 'var __c = __lgClean(__r);'
      'var __s = (typeof __c === "string")'
      ' ? __c : ((__c instanceof String) ? __c.valueOf() : null);'
      'if (__s !== null && __s.length > $_kMaxEvalChars) {'
      'globalThis.__lgBIG = __s;'
      'globalThis.__lgTake = function (a, b) { var s = __lgBIG;'
      'if (b < s.length) { var c = s.charCodeAt(b - 1);'
      'if (c >= 0xD800 && c <= 0xDBFF) b -= 1; }'
      'return s.slice(a, b); };'
      'return "\\u0001LG_BIG:" + __s.length; }'
      'return __c;';

  /// 上下文签名：任何会影响结果的绑定值变化都必须落进来。
  static String _ctxSig(JsEnv e, Object? input) {
    final b = StringBuffer();
    b
      ..write(e.scopeKey)
      ..write('\u0000')
      ..write(e.baseUrl ?? '')
      ..write('\u0000')
      ..write(e.nextChapterUrl ?? '')
      ..write('\u0000')
      ..write(e.title ?? '')
      ..write('\u0000');
    final ch = e.chapter;
    if (ch != null) {
      b
        ..write(ch['title'] ?? '')
        ..write('\u0000')
        ..write(ch['url'] ?? '');
    }
    b.write('\u0000');
    if (input is Map || input is List) {
      try {
        b.write(jsonEncode(input));
      } catch (_) {
        b.write('$input');
      }
    } else {
      b.write('${input ?? ''}');
    }
    final vs = e.vars;
    if (vs != null && vs.isNotEmpty) {
      b.write('\u0000');
      final keys = vs.keys.toList()..sort();
      for (final k in keys) {
        final v = vs[k];
        if (v is String || v is num || v is bool) {
          b
            ..write(k)
            ..write('=')
            ..write(v)
            ..write(';');
        }
      }
    }
    return b.toString();
  }

  /// 测试用：当前结果缓存条数 / 清空。
  @visibleForTesting
  static int get debugJsCacheSize => _resultCache.length;

  @visibleForTesting
  static void debugClearJsCache() => _resultCache.clear();

  static void _cacheResult(String? key, String value) {
    if (key == null || value.length > _resultCacheMaxLen) return;
    if (_resultCache.length >= _resultCacheMax) {
      _resultCache.remove(_resultCache.keys.first);
    }
    _resultCache[key] = value;
  }

  static String? evalCode(String code, {JsEnv? env, Object? input}) {
    lastError = null;
    if (_libFailed) return null;
    final e = env ?? JsEnv();
    final pure = _pureJs(code);
    final ckey = pure ? '$code\u0000${_ctxSig(e, input)}' : null;
    if (ckey != null) {
      final hit = _resultCache[ckey];
      if (hit != null) return hit;
    }
    final rt = _obtain(e);
    if (rt == null) return null;
    // 对齐 legado 求值作用域：脚本当作「全局脚本」执行。Rhino 的
    // ScriptEngine.eval 就是全局作用域，rule 里 `var helper = function…` 落全局，
    // 之后别的规则（或 jsLib 里的函数）还能调到。所以这里用间接 eval
    // （`(0,eval)`，ECMAScript 规定间接调用走全局作用域），而不是 `eval`——
    // 直接调用会把 var 关进本函数作用域，jsLib 函数就看不见了。
    // let/const 每次求值各有全新声明环境，不会跨调用撞名。
    JsEvalResult r;
    _active = e;
    try {
      r = rt.evaluate('${_setup(e, input)}\n'
          '(function () { var __r = (0, eval)(${jsonEncode(code)});'
          '$_finalizeJs})()');
      // 部分书源在 @js 里直接写顶层 return（legado 的 Rhino 允许），
      // eval 下会 SyntaxError；此时把整段包进函数体再跑一次。
      if (r.isError && '${r.stringResult}'.contains('return not in a function')) {
        r = rt.evaluate('${_setup(e, input)}\n'
            '(function () { var __r = (function () {\n$code\n})();'
            '$_finalizeJs})()');
      }
    } catch (err) {
      debugPrint('[js] evaluate 异常(${e.scopeKey})：$err');
      lastError = '$err';
      _drop(e.scopeKey);
      return null;
    } finally {
      _active = null;
    }
    final text = r.stringResult;
    if (traceAjax) {
      print('[js] eval code=${code.length}字 isError=${r.isError} '
          'raw=${r.rawResult == null ? "null" : r.rawResult.runtimeType} '
          'str=${_clip(text)}');
    }
    if (r.isError || text.contains('__JSSUSP__')) {
      final m = _suspRe.firstMatch(text) ?? _suspRe.firstMatch('${r.rawResult}');
      if (m != null) {
        final kind = m.group(1)!;
        final payload =
            utf8.decode(base64Url.decode(_padB64(m.group(2)!)), allowMalformed: true);
        throw _decodeSuspend(kind, payload);
      }
      debugPrint('[js] 脚本错误(${e.scopeKey})：${_clip(text)}');
      lastError = _clip(text);
      return null;
    }
    final pend = _pendingSusp(rt);
    if (pend != null) throw pend;
    // 超长字符串：脚本已把值挂到 __lgBIG，这里分片取回（见 _finalizeJs 注释）。
    if (text.startsWith(_kBigMarker)) {
      final out = _readBigString(rt, text.substring(_kBigMarker.length), e);
      if (out != null) _cacheResult(ckey, out);
      return out;
    }
    final raw = r.rawResult;
    if (raw == null) return null;
    String? out;
    final sobj = _asJsStringObject(raw);
    if (sobj != null) {
      // java.lang.String(bytes, charset) 的 `new String(…)` 结果是 String 对象，
      // 经 FFI 会退化成 {0:'a',1:'b'}，这里还原成普通字符串（书源只会当字符串用）。
      out = sobj;
    } else if (raw is String) {
      out = raw;
    } else if (raw is num || raw is bool) {
      out = raw.toString();
    } else {
      if (raw is Map || raw is List) {
        try {
          out = jsonEncode(raw);
        } catch (_) {}
      }
      out ??= text;
    }
    _cacheResult(ckey, out);
    return out;
  }

  /// 取本次求值里被脚本 `try/catch` 吞掉的 suspend（`__lgSuspLog` 首项）。
  static JsSuspendException? _pendingSusp(JavascriptRuntime rt) {
    try {
      final r = rt.evaluate('(globalThis.__lgSuspLog||[])[0]||""');
      if (r.isError) return null;
      final m = _suspRe.firstMatch(r.stringResult);
      if (m == null) return null;
      final payload = utf8.decode(
        base64Url.decode(_padB64(m.group(2)!)),
        allowMalformed: true,
      );
      return _decodeSuspend(m.group(1)!, payload);
    } catch (_) {
      return null;
    }
  }

  /// 分片取回 `__lgBIG`（单次取回上限见 [_kMaxEvalChars]）。
  static String? _readBigString(
      JavascriptRuntime rt, String lenText, JsEnv e) {
    final total = int.tryParse(lenText.trim()) ?? 0;
    if (total <= 0) return null;
    final sb = StringBuffer();
    var guard = 0;
    while (sb.length < total && guard++ < 4096) {
      final from = sb.length;
      final piece = rt.evaluate('__lgTake($from, ${from + _kMaxEvalChars})');
      final s = piece.isError ? '' : piece.stringResult;
      if (s.isEmpty) break;
      sb.write(s);
    }
    rt.evaluate('globalThis.__lgBIG = undefined;');
    if (sb.length != total) {
      // 取回不完整（只可能是运行时被回收）：宁可变空也不要半截正文。
      debugPrint('[js] 大结果取回不完整(${e.scopeKey})：${sb.length}/$total');
      lastError = 'big-result ${sb.length}/$total';
      return null;
    }
    return sb.toString();
  }

  /// 还原挂起请求体：新格式是 JSON（含 method/headers/body），旧格式是裸 URL。
  static JsSuspendException _decodeSuspend(String kind, String payload) {
    final t = payload.trim();
    if (t.startsWith('{')) {
      try {
        final o = jsonDecode(t);
        if (o is Map) {
          final h = <String, String>{};
          final rawH = o['h'];
          if (rawH is Map) {
            rawH.forEach((k, v) => h['$k'] = '$v');
          }
          final b = o['b'];
          return JsSuspendException(
            kind,
            '${o['u'] ?? ''}',
            method: '${o['m'] ?? 'GET'}'.toUpperCase(),
            headers: h,
            body: b == null ? null : '$b',
          );
        }
      } catch (_) {}
    }
    return JsSuspendException(kind, payload);
  }

  /// 补网缓存键：GET 无体时等于 URL，否则叠加方法与请求体指纹。
  static String ajaxKey(String method, String url, String? body) {
    final m = method.toUpperCase();
    if (m == 'GET' && body == null) return url;
    final h = body == null
        ? ''
        : base64Url.encode(utf8.encode(body)).replaceAll('=', '');
    return '$m $url${h.isEmpty ? '' : ' #$h'}';
  }

  /// 识别 JS String 对象的序列化形状（键恰好是 0..n-1 的连续整数）。
  static String? _asJsStringObject(Object? raw) {
    if (raw is! Map || raw.isEmpty) return null;
    final idx = <int>[];
    for (final k in raw.keys) {
      final i = int.tryParse('$k');
      if (i == null) return null;
      idx.add(i);
    }
    idx.sort();
    for (var i = 0; i < idx.length; i++) {
      if (idx[i] != i) return null;
    }
    final sb = StringBuffer();
    for (final i in idx) {
      sb.write('${raw['$i']}');
    }
    return sb.toString();
  }

  /// 丢弃某书源的运行时（异常恢复 / 测试清理）。
  static void dropScope(String scopeKey) {
    final h = _pool.remove(scopeKey);
    if (h == null) return;
    try {
      h.rt.dispose();
    } catch (_) {}
  }

  /// 清空全部运行时。
  static void disposeAll() {
    for (final k in _pool.keys.toList()) {
      dropScope(k);
    }
  }

  // ---------------------------------------------------------------------
  // 运行时池
  // ---------------------------------------------------------------------

  static JavascriptRuntime? _obtain(JsEnv env) {
    final existing = _pool[env.scopeKey];
    if (existing != null) {
      existing.usedAt = ++_tick;
      _applyJsLib(existing, env);
      return existing.rt;
    }
    if (_libFailed) return null;
    JavascriptRuntime rt;
    try {
      rt = QuickJsRuntime2(stackSize: 1024 * 1024, memoryLimit: 128 * 1024 * 1024);
      rt.onMessage('jsbridge', _dispatch);
      rt.evaluate(_prelude);
      rt.evaluate(_javaLibShim);
      // 原版书源脚本依赖真实 Java 类（Packages.java.*）：注入兼容层，
      // 覆盖 java.lang/util/security/nio/io/net/util.zip、javax.crypto、
      // android.util.Base64、cn.hutool、org.jsoup。
      rt.evaluate(kJavaCompatShim);
    } catch (e) {
      _libFailed = true;
      debugPrint('[js] QuickJS 引擎不可用（书源 JS 将降级为空结果）：$e');
      return null;
    }
    final h = _Holder(rt)..usedAt = ++_tick;
    _pool[env.scopeKey] = h;
    _trim();
    _applyJsLib(h, env);
    return rt;
  }

  static void _applyJsLib(_Holder h, JsEnv env) {
    final lib = env.jsLib;
    if (lib == null || lib.trim().isEmpty || lib == h.jsLibApplied) return;
    h.jsLibApplied = lib;
    _active = env;
    try {
      h.rt.evaluate(lib);
    } catch (e) {
      debugPrint('[js] jsLib 求值失败：$e');
    } finally {
      _active = null;
    }
  }

  static void _trim() {
    while (_pool.length > _poolMax) {
      String? oldest;
      var min = 1 << 62;
      _pool.forEach((k, v) {
        if (v.usedAt < min) {
          min = v.usedAt;
          oldest = k;
        }
      });
      if (oldest == null) return;
      dropScope(oldest!);
    }
  }

  static void _drop(String scopeKey) => dropScope(scopeKey);

  // ---------------------------------------------------------------------
  // 每次求值的上下文装配（对齐 legado evalJS 的 bindings）
  // ---------------------------------------------------------------------

  static final RegExp _identRe = RegExp(r'^[A-Za-z_$][A-Za-z0-9_$]*$');

  /// `BaseSource.put/get/remove` 的最小实现（`$obj`/`$map` 由 [_setup] 替换）。
  ///
  /// 上游这三者是「只在运行期存在」的键值表，书源脚本用它跨卡片传状态
  /// （例如七猫聚合 `source.put('qma_status', …)`、`source.get('qma_meta')`）。
  static const String _kPutShim = r'''
globalThis.$map = globalThis.$map || {};
$obj.put = function (k, v) {
  if (k === undefined || k === null) return;
  globalThis.$map[String(k)] = (v === undefined || v === null) ? '' : String(v);
};
$obj.get = function (k) {
  if (k === undefined || k === null) return null;
  var v = globalThis.$map[String(k)];
  return v === undefined ? null : v;
};
$obj.remove = function (k) {
  if (k === undefined || k === null) return;
  try { delete globalThis.$map[String(k)]; } catch (e) {}
};''';

  /// 保留名：上下文装配中已固定赋值，禁止被 vars 覆盖（避免把对象当字符串注入）。
  static const Set<String> _kReserved = {
    'result', 'baseUrl', 'nextChapterUrl', 'title', 'book', 'source',
    'java', 'cookie', 'cache', 'console', 'sendMessage', 'globalThis',
  };

  static String _setup(JsEnv e, Object? input) {
    final b = StringBuffer();
    // result 对齐 legado：JSON 元素以对象传入（脚本可 result.xxx / String(result)）
    final rlit = (input is Map || input is List)
        ? _jsonOrString(input!)
        : _lit(input?.toString());
    b.writeln('var result = $rlit;');
    b.writeln('var baseUrl = ${_lit(e.baseUrl ?? e.sourceUrl)};');
    b.writeln('var nextChapterUrl = ${_lit(e.nextChapterUrl ?? '')};');
    b.writeln(
        'var title = ${_lit(e.chapter?['title']?.toString() ?? e.title ?? '')};');
    b.writeln('var book = ${jsonEncode(e.book ?? const <String, dynamic>{})};');
    b.writeln('var chapter = '
        '${e.chapter == null ? 'null' : _jsonOrString(e.chapter!)};');
    b.writeln(
        'var source = ${jsonEncode(<String, dynamic>{
      // 书源实体字段先铺开（loginUrl / searchUrl / exploreUrl / bookSourceComment…），
      // 再覆盖成本次求值的绑定值，语义与上游「source 就是 BookSource 实体」一致。
      ...?e.sourceJson,
      'bookSourceUrl': e.sourceUrl,
      'bookSourceName': e.sourceName,
      'header': e.sourceHeader ?? '',
    })};');
    b.writeln('source.getKey = function () { return this.bookSourceUrl; };');
    // legado BaseSource.getVariable/setVariable（书源级变量，脚本常用于缓存 token）
    // 注意：上下文注入在每次求值的独立作用域里，桥函数只能走 globalThis 取。
    // - getVariable()        无参 → 返回全部变量的 JSON 串（聚合源用来读「打开参数」）
    // - getVariable(k)       有参 → 单值；可带默认值 getVariable(k, default)
    // - setVariable(k, v)    写单值；只给一个参数时按「整体覆盖」解析 JSON
    b.writeln('source.getVariable = function (k) { '
        'var d; '
        'if (k === undefined || k === null) { '
        'd = globalThis.__lgcall("source.var.all", {}); '
        'return d && d.v !== undefined && d.v !== null ? String(d.v) : ""; } '
        'd = globalThis.__lgcall("source.var.get", { k: String(k) }); '
        'var v = d ? (d.v === null || d.v === undefined ? "" : String(d.v)) : ""; '
        'if (v === "" && arguments.length > 1 && arguments[1] !== undefined '
        '&& arguments[1] !== null) { return String(arguments[1]); } '
        'return v; };');
    b.writeln('source.setVariable = function (k, v) { '
        'if (v === undefined) { '
        'globalThis.__lgcall("source.var.putAll", '
        '{ s: k === null || k === undefined ? "" : String(k) }); return; } '
        'globalThis.__lgcall("source.var.put", { k: String(k), '
        'v: v === null || v === undefined ? null : String(v) }); };');
    // legado BaseSource 的 put/get/remove：会话期内存键值（书源脚本用来跨卡片
    // 传状态，例如七猫聚合 `source.put('qma_status', …)`）。上游存在 source 实例
    // 上，这里挂在 globalThis（同一书源共用一个运行时），语义等价。
    b.writeln(_kPutShim.replaceAll(r'$obj', 'source').replaceAll(r'$map', '__lgPut'));
    b.writeln(_kPutShim.replaceAll(r'$obj', 'book').replaceAll(r'$map', '__lgPutB'));
    // 登录态：上游 BookSource 另有 loginInfo / loginHeader 两个字段，脚本用
    // getLoginInfoMap / putLoginInfo / getLoginHeader(Map) 读写。落到书源变量表
    // 里带前缀的键，避免与脚本自己的变量（qma_meta 之类）撞车。
    b.writeln('source.getLoginInfoMap = function () { '
        'try { var s = source.getVariable("@loginInfo"); '
        'return s ? JSON.parse(s) : {}; } catch (e) { return {}; } };');
    b.writeln('source.getLoginInfo = function () { return source.getLoginInfoMap(); };');
    b.writeln('source.putLoginInfo = function (m) { '
        'try { source.setVariable("@loginInfo", '
        'JSON.stringify(m === null || m === undefined ? {} : m)); } catch (e) {} };');
    b.writeln('source.getLoginHeader = function () { '
        'var s = source.getVariable("@loginHeader"); '
        'return s === "" ? null : s; };');
    b.writeln('source.getLoginHeaderMap = function () { '
        'try { var s = source.getVariable("@loginHeader"); '
        'return s ? JSON.parse(s) : {}; } catch (e) { return {}; } };');
    // book.getVariable/setVariable：书级变量（legado 按书持久化）。这里按
    // bookUrl 前缀落到书源变量表，跨卡片/跨章节仍能读到。
    b.writeln('book.getVariable = function (k, d) { '
        'var u = (book && book.bookUrl) ? book.bookUrl : ""; '
        'if (k === undefined || k === null) { return source.getVariable("@book:" + u); } '
        'return source.getVariable("@book:" + u + ":" + String(k), d); };');
    b.writeln('book.setVariable = function (k, v) { '
        'var u = (book && book.bookUrl) ? book.bookUrl : ""; '
        'if (v === undefined) { return source.setVariable("@book:" + u, k); } '
        'return source.setVariable("@book:" + u + ":" + String(k), v); };');
    final vs = e.vars;
    if (vs != null) {
      vs.forEach((k, v) {
        if (!_identRe.hasMatch(k) || _kReserved.contains(k)) return;
        if (v is! String && v is! num && v is! bool) return;
        b.writeln('var $k = ${_lit(v)};');
      });
    }
    final s = e.session;
    if (s != null) {
      b.writeln('Date.now = function () { return ${s.frozenNow}; };');
    }
    // setContent 的内容只对本次求值有效（上游每次求值都是新解析器实例）。
    b.writeln('globalThis.__lgContent = null;');
    b.writeln('globalThis.__lgContentUrl = "";');
    b.writeln('globalThis.__lgSuspLog = [];');
    return b.toString();
  }

  static String _lit(Object? v) {
    if (v == null) return 'null';
    if (v is num || v is bool) return '$v';
    return jsonEncode(v.toString());
  }

  /// JSON 字面量（不可编码时退回字符串字面量）。
  static String _jsonOrString(Object v) {
    try {
      return jsonEncode(v);
    } catch (_) {
      return _lit(v.toString());
    }
  }

  // ---------------------------------------------------------------------
  // JS → Dart 同步桥
  // ---------------------------------------------------------------------

  static dynamic _dispatch(dynamic msg) {
    var fn = '?';
    try {
      if (msg is! List || msg.isEmpty) return jsonEncode({'v': null});
      fn = '${msg[0]}';
      Map<String, dynamic> p = const <String, dynamic>{};
      if (msg.length > 1 && msg[1] != null) {
        final d = jsonDecode('${msg[1]}');
        if (d is Map) p = d.cast<String, dynamic>();
      }
      final env = _active;
      switch (fn) {
        case 'ajax':
          return _remote(
            env,
            'ajax',
            '${p['url'] ?? ''}',
            method: '${p['method'] ?? 'GET'}',
            headers: _strMap(p['headers']),
            body: p['body'] == null ? null : '${p['body']}',
          );
        case 'webview':
          return _remote(env, 'webview', '${p['url'] ?? ''}');
        case 'b64d':
          return jsonEncode({'v': _b64Decode('${p['s'] ?? ''}')});
        case 'b64e':
          return jsonEncode({'v': base64.encode(utf8.encode('${p['s'] ?? ''}'))});
        case 'hexd':
          return jsonEncode({'v': _hexDecode('${p['s'] ?? ''}')});
        case 'hexe':
          return jsonEncode({'v': _hexEncode('${p['s'] ?? ''}')});
        case 'encuri':
          return jsonEncode({
            'v': _javaUrlEncode(
                '${p['s'] ?? ''}', '${p['enc'] ?? ''}'.isEmpty ? 'UTF-8' : '${p['enc']}')
          });
        case 'timeFmt':
          return jsonEncode({'v': _timeFormat(p)});
        case 'md5':
          return jsonEncode({'v': _md5('${p['s'] ?? ''}')});
        case 'md5_16':
          return jsonEncode({'v': _md5('${p['s'] ?? ''}').substring(8, 24)});
        case 'aes':
          return jsonEncode({
            'v': _aesBase64DecodeToString('${p['str'] ?? ''}', '${p['key'] ?? ''}',
                '${p['transformation'] ?? 'AES/CBC/PKCS5Padding'}', '${p['iv'] ?? ''}')
          });
        case 'sym':
          return jsonEncode({'v': _symCrypto(p)});
        case 'digest':
          return jsonEncode({'v': _digest('${p['alg'] ?? 'MD5'}', p['data'])});
        case 'hmac':
          return jsonEncode({
            'v': _hmac(
                '${p['alg'] ?? 'HmacSHA256'}', p['key'], p['data'])
          });
        case 'b64b':
          // java.base64DecodeToByteArray：返回字节数组（JS 里是 Array<int>）
          return jsonEncode({'v': _b64Bytes('${p['s'] ?? ''}')?.toList() ?? const <int>[]});
        case 'deviceid':
          return jsonEncode({'v': _kDeviceId});
        case 'ua':
          return jsonEncode({'v': _kUA});
        case 'var.get':
          return jsonEncode({'v': env?.session?.vars['${p['k'] ?? ''}']});
        case 'source.var.all':
          {
            // 无参 getVariable()：全部变量序列化成 JSON 串（聚合源 getArguments
            // 会 JSON.parse 它来读「打开参数」）。
            // 没有任何变量时必须返回空串而不是 `{}` —— legado 的 variable 字段为空，
            // 聚合源的 getArguments 靠 `JSON.parse('')` 抛错来落回内置默认值，
            // 返回 `{}` 会让它读到 undefined（地址变成 `undefined/search?...`）。
            final url = env?.sourceUrl ?? '';
            final m = <String, String>{
              ...?SourceVars.shared?.of(url),
              ...?env?.session?.vars,
            };
            return jsonEncode({'v': m.isEmpty ? '' : jsonEncode(m)});
          }
        case 'source.var.putAll':
          {
            // 单参 setVariable(<json>)：整体覆盖
            final url = env?.sourceUrl ?? '';
            dynamic decoded;
            try {
              decoded = jsonDecode('${p['s'] ?? ''}');
            } catch (_) {
              decoded = null;
            }
            if (decoded is Map) {
              decoded.forEach((k, v) {
                final key = '$k';
                final val = v == null ? '' : '$v';
                env?.session?.vars[key] = val;
                if (url.isNotEmpty) {
                  SourceVars.shared?.set(url, key, val.isEmpty ? null : val);
                }
              });
            }
            return jsonEncode({'v': null});
          }
        case 'source.var.get':
          {
            // 先看会话内（同一次操作里 set 过的最新鲜），再落到书源级持久化
            // （legado 把变量存在书源数据库里，重启后仍在）。
            final sk = '${p['k'] ?? ''}';
            final sess = env?.session?.vars;
            var sVal = sess?[sk];
            if (sVal == null || sVal.isEmpty) {
              final url = env?.sourceUrl ?? '';
              if (url.isNotEmpty) {
                final stored = SourceVars.shared?.get(url, sk) ?? '';
                if (stored.isNotEmpty) {
                  sess?[sk] = stored;
                  sVal = stored;
                }
              }
            }
            return jsonEncode({'v': sVal});
          }
        case 'source.var.put':
          {
            final pk = '${p['k'] ?? ''}';
            final pv = '${p['v'] ?? ''}';
            env?.session?.vars[pk] = pv;
            final purl = env?.sourceUrl ?? '';
            if (purl.isNotEmpty) {
              SourceVars.shared?.set(purl, pk, pv.isEmpty ? null : pv);
            }
            return jsonEncode({'v': null});
          }
        case 'var.put':
          env?.session?.vars['${p['k'] ?? ''}'] = '${p['v'] ?? ''}';
          return jsonEncode({'v': null});
        case 'cache.get':
          return jsonEncode({'v': env?.session?.cache['${p['k'] ?? ''}']});
        case 'cache.put':
          env?.session?.cache['${p['k'] ?? ''}'] = '${p['v'] ?? ''}';
          return jsonEncode({'v': null});
        case 'cache.delete':
          env?.session?.cache.remove('${p['k'] ?? ''}');
          return jsonEncode({'v': null});
        case 'cookie.get':
          return jsonEncode({
            'v': env?.getCookie?.call('${p['tag'] ?? ''}', p['key']?.toString()) ?? ''
          });
        case 'cookie.set':
          LegadoCookieJar.I.setFor(
            '${p['tag'] ?? ''}',
            '${p['v'] ?? ''}',
          );
          return jsonEncode({'v': null});
        case 'cookie.del':
          LegadoCookieJar.I.removeFor('${p['tag'] ?? ''}');
          return jsonEncode({'v': null});
        case 'getString':
          return jsonEncode({'v': env?.getString?.call('${p['rule'] ?? ''}')});
        case 'getElement':
          final r = '${p['rule'] ?? ''}';
          return jsonEncode({
            'v': env?.getElement?.call(r) ?? env?.getString?.call(r)
          });
        case 'getElements':
          final r = '${p['rule'] ?? ''}';
          final hook = env?.getElements;
          if (hook != null) return jsonEncode({'v': hook(r)});
          final one = env?.getElement?.call(r) ?? env?.getString?.call(r);
          return jsonEncode({
            'v': one == null || one.isEmpty ? const <String>[] : <String>[one]
          });
        case 'log':
          debugPrint('[js.log] ${_clip('${p['msg'] ?? ''}')}');
          return jsonEncode({'v': null});
        case 'toast':
          return jsonEncode({'v': null});
        case 'jcompat':
          // Packages.* 兼容层：摘要/HMAC/AES/压缩/字符集/选择器下沉到 Dart。
          return jsonEncode(JavaCompat.dispatch(p));
        default:
          return jsonEncode({'v': null});
      }
    } catch (e) {
      debugPrint('[js] 桥调用 $fn 失败：$e');
      return jsonEncode({'v': null});
    }
  }

  static Map<String, String> _strMap(Object? raw) {
    final out = <String, String>{};
    if (raw is Map) {
      raw.forEach((k, v) {
        if (v != null) out['$k'] = '$v';
      });
    }
    return out;
  }

  /// 诊断开关：打印 ajax 缓存命中/落空（tool/dump_* 里打开）。
  static bool traceAjax = false;

  static dynamic _remote(
    JsEnv? env,
    String kind,
    String url, {
    String method = 'GET',
    Map<String, String> headers = const {},
    String? body,
  }) {
    if (url.isEmpty) return jsonEncode({'v': ''});
    final ses = env?.session;
    final key = ajaxKey(method, url, body);
    if (traceAjax) {
      final hit = kind == 'ajax'
          ? (ses?.ajaxCache.containsKey(key) ?? false)
          : (ses?.webViewCache.containsKey(key) ?? false);
      print('[ajax] ${hit ? "hit " : "miss"} ses=${ses != null} $kind $method $url'
          '${ses == null ? "" : " keys=${ses.ajaxCache.length}"}');
    }
    final cache = kind == 'ajax' ? ses?.ajaxCache : ses?.webViewCache;
    if (cache != null && cache.containsKey(key)) {
      final meta = kind == 'ajax' ? ses?.ajaxMeta[key] : null;
      return jsonEncode({'v': cache[key], 'meta': meta ?? const {}});
    }
    if (ses == null) {
      // 无会话（模板等场景）：显式降级为空串，交由脚本自行容错。
      return jsonEncode({'v': ''});
    }
    final payload = jsonEncode({
      'u': url,
      'm': method.toUpperCase(),
      'h': headers,
      'b': body,
    });
    return jsonEncode({
      'suspend': true,
      'kind': kind,
      'b64': base64Url.encode(utf8.encode(payload)),
    });
  }

  // ---------------------------------------------------------------------
  // 编码/加密子集（对齐 JsEncodeUtils）
  // ---------------------------------------------------------------------

  static const String _kUA =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';

  /// java.deviceID() / java.androidId()：上游取 ANDROID_ID。
  /// 必须**稳定**——签名类书源把它拼进 sign，每次请求变一个值服务端就不认。
  static const String _kDeviceId = '9774d56d682e549c';

  static String? _b64Decode(String s) {
    final b = _b64Bytes(s);
    if (b == null) return null;
    return utf8.decode(b, allowMalformed: true);
  }

  static Uint8List? _b64Bytes(String s) {
    var t = s.replaceAll(RegExp(r'\s'), '').replaceAll('-', '+').replaceAll('_', '/');
    if (t.isEmpty) return Uint8List(0);
    while (t.length % 4 != 0) {
      t += '=';
    }
    try {
      return base64.decode(t);
    } catch (_) {
      return null;
    }
  }

  static String _hexEncode(String s) =>
      utf8.encode(s).map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  static String? _hexDecode(String hx) {
    final t = hx.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
    if (t.length.isOdd) return null;
    final b = Uint8List(t.length ~/ 2);
    for (var i = 0; i < b.length; i++) {
      b[i] = int.parse(t.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return utf8.decode(b, allowMalformed: true);
  }

  /// 对齐 java.net.URLEncoder：保留 A-Za-z0-9 . - * _，空格 → '+'，其余按 charset 百分号编码。
  static String _javaUrlEncode(String s, String enc) {
    final bytes = _encodeBytes(s, enc);
    final sb = StringBuffer();
    for (final b in bytes) {
      final c = b & 0xff;
      final ch = String.fromCharCode(c);
      final keep = (c >= 0x41 && c <= 0x5A) ||
          (c >= 0x61 && c <= 0x7A) ||
          (c >= 0x30 && c <= 0x39) ||
          ch == '.' ||
          ch == '-' ||
          ch == '*' ||
          ch == '_';
      if (keep) {
        sb.write(ch);
      } else if (c == 0x20) {
        sb.write('+');
      } else {
        sb.write('%${c.toRadixString(16).toUpperCase().padLeft(2, '0')}');
      }
    }
    return sb.toString();
  }

  static List<int> _encodeBytes(String s, String enc) {
    final e = enc.toUpperCase();
    if (e == 'GBK' || e == 'GB2312' || e == 'GB18030') {
      try {
        return gbk.encode(s);
      } catch (_) {}
    }
    return utf8.encode(s);
  }

  /// timeFormat(time) 默认 "yyyy/MM/dd HH:mm"（AppConst.dateFormat）；
  /// timeFormatUTC(time, format, sh) 对齐 SimpleTimeZone(sh 毫秒偏移, "UTC")。
  static String _timeFormat(Map<String, dynamic> p) {
    final time = p['time'] is num ? (p['time'] as num).toInt() : DateTime.now().millisecondsSinceEpoch;
    final utc = p['utc'] == true;
    var d = DateTime.fromMillisecondsSinceEpoch(time, isUtc: false);
    if (utc) {
      final sh = p['sh'] is num ? (p['sh'] as num).toInt() : 0;
      d = DateTime.fromMillisecondsSinceEpoch(time, isUtc: true)
          .add(Duration(milliseconds: sh));
    }
    final fmt = '${p['format'] ?? ''}'.isEmpty
        ? (utc ? 'yyyy-MM-dd HH:mm:ss' : 'yyyy/MM/dd HH:mm')
        : '${p['format']}';
    return _strftime(d, fmt);
  }

  static String _strftime(DateTime d, String fmt) {
    const tokens = [
      'SSS', 'yyyy', 'yy', 'MM', 'dd', 'HH', 'mm', 'ss', 'M', 'd', 'H', 'm', 's'
    ];
    final sb = StringBuffer();
    var i = 0;
    while (i < fmt.length) {
      String? hit;
      for (final t in tokens) {
        if (fmt.startsWith(t, i)) {
          hit = t;
          break;
        }
      }
      if (hit == null) {
        sb.write(fmt[i]);
        i++;
        continue;
      }
      switch (hit) {
        case 'SSS':
          sb.write(d.millisecond.toString().padLeft(3, '0'));
        case 'yyyy':
          sb.write(d.year.toString().padLeft(4, '0'));
        case 'yy':
          sb.write((d.year % 100).toString().padLeft(2, '0'));
        case 'MM':
          sb.write(d.month.toString().padLeft(2, '0'));
        case 'M':
          sb.write(d.month);
        case 'dd':
          sb.write(d.day.toString().padLeft(2, '0'));
        case 'd':
          sb.write(d.day);
        case 'HH':
          sb.write(d.hour.toString().padLeft(2, '0'));
        case 'H':
          sb.write(d.hour);
        case 'mm':
          sb.write(d.minute.toString().padLeft(2, '0'));
        case 'm':
          sb.write(d.minute);
        case 'ss':
          sb.write(d.second.toString().padLeft(2, '0'));
        case 's':
          sb.write(d.second);
      }
      i += hit.length;
    }
    return sb.toString();
  }

  static String _md5(String s) =>
      crypto.md5.convert(utf8.encode(s)).toString();

  static String? _aesBase64DecodeToString(
      String data, String key, String transformation, String iv) {    try {
      final parts = transformation.toUpperCase().split('/');
      if (parts.isEmpty || parts[0] != 'AES') return null;
      final mode = parts.length > 1 ? parts[1] : 'CBC';
      final padding = parts.length > 2 ? parts[2] : 'PKCS5PADDING';
      final keyB = utf8.encode(key);
      final ivB = utf8.encode(iv);
      final dataB = _b64Bytes(data);
      if (dataB == null || dataB.isEmpty) return null;
      final core = mode == 'ECB'
          ? pc.ECBBlockCipher(pc.AESEngine())
          : pc.CBCBlockCipher(pc.AESEngine());
      if (padding == 'NOPADDING' || padding == 'NO') {
        core.init(
            false,
            mode == 'ECB'
                ? pc.KeyParameter(Uint8List.fromList(keyB))
                : pc.ParametersWithIV(
                    pc.KeyParameter(Uint8List.fromList(keyB)),
                    Uint8List.fromList(ivB)));
        final out = Uint8List(dataB.length);
        for (var off = 0; off + 16 <= dataB.length; off += 16) {
          core.processBlock(dataB, off, out, off);
        }
        return utf8.decode(out, allowMalformed: true);
      }
      final cipher = pc.PaddedBlockCipherImpl(pc.PKCS7Padding(), core);
      cipher.init(
          false,
          mode == 'ECB'
              ? pc.PaddedBlockCipherParameters(
                  pc.KeyParameter(Uint8List.fromList(keyB)), null)
              : pc.PaddedBlockCipherParameters(
                  pc.ParametersWithIV(
                      pc.KeyParameter(Uint8List.fromList(keyB)),
                      Uint8List.fromList(ivB)),
                  null));
      return utf8.decode(cipher.process(dataB), allowMalformed: true);
    } catch (e) {
      debugPrint('[js] AES 解密失败：$e');
      return null;
    }
  }

  /// `java.createSymmetricCrypto(transformation, key, iv)`：上游返回一个
  /// SymmetricCrypto 对象（encrypt / encryptBase64 / encryptHex / decrypt /
  /// decryptStr）。书源里的典型写法：
  /// ```js
  /// java.createSymmetricCrypto('AES/CBC/PKCS5Padding', key, iv).decryptStr(ct)
  /// java.createSymmetricCrypto('AES', key).encryptBase64(json)   // 默认 ECB/PKCS5
  /// ```
  /// key/iv 可能是字符串，也可能是 `java.base64DecodeToByteArray()` 的字节数组。
  static Object? _symCrypto(Map<String, dynamic> p) {
    final enc = '${p['op'] ?? 'dec'}' == 'enc';
    final trans = '${p['t'] ?? 'AES/CBC/PKCS5Padding'}'.toUpperCase();
    final out = '${p['out'] ?? 'str'}';
    final parts = trans.split('/');
    final alg = parts[0];
    // Cipher.getInstance("AES") 的默认值是 AES/ECB/PKCS5Padding
    final mode = parts.length > 1 && parts[1].isNotEmpty ? parts[1] : 'ECB';
    final padding =
        parts.length > 2 && parts[2].isNotEmpty ? parts[2] : 'PKCS5PADDING';
    final keyRaw = _symBytes(p['key']);
    if (keyRaw == null || keyRaw.isEmpty) return null;
    final key = _symFitKey(keyRaw, alg);
    final engine = _symEngine(alg);
    final bs = engine.blockSize;
    final ivRaw = _symBytes(p['iv']);
    final iv = _symFitIv(ivRaw, bs);
    final dataRaw = p['data'];

    if (enc) {
      // data 可能是字符串，也可能是 byte[]（Cipher.doFinal(byte[])）
      final plain = dataRaw is List
          ? (_symBytes(dataRaw) ?? Uint8List(0))
          : Uint8List.fromList(utf8.encode('${dataRaw ?? ''}'));
      final res = _symRun(true, engine, mode, padding, key, iv, plain);
      if (res == null) return null;
      switch (out) {
        case 'bytes':
          return res.toList();
        case 'hex':
          return res
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join();
        default:
          return base64.encode(res);
      }
    }

    // 解密：输入可能是 Base64、十六进制，或已经是 byte[]；模式/填充也可能与
    // 声明不符，逐个组合试，挑第一个能解出合法 UTF-8 的结果。
    final inputs = dataRaw is List
        ? <Uint8List>[_symBytes(dataRaw) ?? Uint8List(0)]
        : <Uint8List?>[_b64Bytes(dataRaw?.toString() ?? ''), _hexToBytes(dataRaw?.toString() ?? '')]
            .whereType<Uint8List>()
            .toList();
    final modes = <String>[mode, mode == 'CBC' ? 'ECB' : 'CBC'];
    final paddings = <String>[padding, 'NOPADDING'];
    for (final input in inputs) {
      for (final m in modes) {
        for (final pad in paddings) {
          final r = _symRun(false, engine, m, pad, key, iv, input);
          if (r == null || r.isEmpty) continue;
          if (out == 'bytes') return r.toList();
          String text;
          try {
            text = utf8.decode(r);
          } catch (_) {
            continue;
          }
          return text;
        }
      }
    }
    return out == 'bytes' ? const <int>[] : null;
  }

  /// java.security.MessageDigest.getInstance(alg).digest(bytes)：
  /// 与 Java 逐字节一致（digest 返回 byte[]，书源常接着 new BigInteger(1, …)）。
  static List<int> _digest(String alg, dynamic data) {
    final bytes = _symBytes(data) ?? Uint8List(0);
    switch (alg.toUpperCase().replaceAll(RegExp(r'[-_]'), '')) {
      case 'SHA1':
        return crypto.sha1.convert(bytes).bytes;
      case 'SHA256':
        return crypto.sha256.convert(bytes).bytes;
      case 'SHA384':
        return crypto.sha384.convert(bytes).bytes;
      case 'SHA512':
        return crypto.sha512.convert(bytes).bytes;
      default:
        return crypto.md5.convert(bytes).bytes;
    }
  }

  /// javax.crypto.Mac（HmacSHA1 / HmacSHA256 / HmacSHA512）。
  static List<int> _hmac(String alg, dynamic key, dynamic data) {
    final a = alg.toUpperCase().replaceAll(RegExp(r'[-_]'), '');
    final digest = a.contains('SHA1')
        ? pc.SHA1Digest()
        : (a.contains('SHA512') ? pc.SHA512Digest() : pc.SHA256Digest());
    final mac = pc.HMac(digest, 64)
      ..init(pc.KeyParameter(_symBytes(key) ?? Uint8List(0)));
    return mac.process(_symBytes(data) ?? Uint8List(0));
  }

  static pc.BlockCipher _symEngine(String alg) {    switch (alg) {
      // pointycastle 4 没有单 DES（只有 DESede + DesBase 基类）：DES 书源极少，
      // 用 DESede 兜住（24 字节密钥），CBC/ECB + PKCS5 的封装行为一致。
      case 'DES':
      case 'DESEDE':
      case 'TRIPLEDES':
      case '3DES':
        return pc.DESedeEngine();
      case 'BLOWFISH':
        return pc.BlowfishEngine();
      default:
        return pc.AESEngine();
    }
  }

  static Uint8List? _symBytes(dynamic v) {
    if (v == null) return null;
    if (v is List) {
      final out = <int>[];
      for (final e in v) {
        if (e is num) out.add(e.toInt() & 0xff);
      }
      return out.isEmpty ? null : Uint8List.fromList(out);
    }
    final s = '$v';
    return s.isEmpty ? null : Uint8List.fromList(utf8.encode(s));
  }

  /// SecretKeySpec 语义：长度不合法就截断/补零到最近的合法长度。
  static Uint8List _symFitKey(Uint8List k, String alg) {
    final sizes = switch (alg) {
      'DES' => const [8],
      'DESEDE' || 'TRIPLEDES' || '3DES' => const [16, 24],
      'BLOWFISH' => const [16, 24, 32],
      _ => const [32, 24, 16],
    };
    if (sizes.contains(k.length)) return k;
    for (final s in sizes) {
      if (k.length >= s) return Uint8List.sublistView(k, 0, s);
    }
    final n = sizes.last;
    final out = Uint8List(n);
    out.setRange(0, k.length, k);
    return out;
  }

  static Uint8List _symFitIv(Uint8List? iv, int bs) {
    if (iv == null || iv.isEmpty) return Uint8List(bs);
    if (iv.length == bs) return iv;
    if (iv.length > bs) return Uint8List.sublistView(iv, 0, bs);
    final out = Uint8List(bs);
    out.setRange(0, iv.length, iv);
    return out;
  }

  static Uint8List? _symRun(bool enc, pc.BlockCipher engine, String mode,
      String padding, Uint8List key, Uint8List iv, Uint8List input) {
    try {
      final bs = engine.blockSize;
      final noPad = padding == 'NOPADDING' || padding == 'NO';
      var data = input;
      if (enc && !noPad) {
        final pad = bs - (data.length % bs);
        data = Uint8List.fromList([...data, ...List<int>.filled(pad, pad)]);
      }
      if (data.isEmpty || data.length % bs != 0) return null;
      final core = mode == 'ECB'
          ? pc.ECBBlockCipher(engine)
          : pc.CBCBlockCipher(engine);
      core.init(
          enc,
          mode == 'ECB'
              ? pc.KeyParameter(key)
              : pc.ParametersWithIV(pc.KeyParameter(key), iv));
      final out = Uint8List(data.length);
      for (var off = 0; off + bs <= data.length; off += bs) {
        core.processBlock(data, off, out, off);
      }
      if (!enc && !noPad) {
        final pad = out.last;
        if (pad >= 1 && pad <= bs && pad <= out.length) {
          return Uint8List.sublistView(out, 0, out.length - pad);
        }
        return null;
      }
      return out;
    } catch (e) {
      return null;
    }
  }

  static Uint8List? _hexToBytes(String s) {
    final t = s.replaceAll(RegExp(r'\s'), '');
    if (t.length < 2 || t.length.isOdd) return null;
    if (!RegExp(r'^[0-9a-fA-F]+$').hasMatch(t)) return null;
    final out = Uint8List(t.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = int.parse(t.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // 内部工具
  // ---------------------------------------------------------------------

  static final RegExp _suspRe =
      RegExp(r'__JSSUSP__([a-z]+)__([A-Za-z0-9+/=_\-]+)');

  static String _padB64(String s) {
    var t = s;
    while (t.length % 4 != 0) {
      t += '=';
    }
    return t;
  }

  static String _clip(String s) =>
      s.length > 220 ? '${s.substring(0, 220)}…' : s;

  /// JS 预置环境：桥函数 + java / cookie / cache 子集。
  static const String _prelude = r'''
(function () {
  // setContent 的内容只在本次求值有效：上游每次 AnalyzeRule 求值都是新解析器，
  // 若把覆盖内容挂在运行时上，下一条规则会拿到上一页的 HTML。
  globalThis.__lgContent = null;
  globalThis.__lgContentUrl = '';
  function __lgcall(name, payload) {
    var r = sendMessage('jsbridge', JSON.stringify([name, payload === null || payload === undefined ? null : JSON.stringify(payload)]));
    if (r === null || r === undefined) return null;
    return JSON.parse(r);
  }
  globalThis.__lgcall = __lgcall;
  globalThis.__lgSuspLog = [];
  globalThis.__lgsusp = function (d) {
    // 书源常写 `try { html = java.ajax(url) } catch (e) {}`：legado 的 ajax 是
    // 同步的，这里的“异常”会被脚本吞掉并留下空结果。先把待补的请求记下来，
    // Dart 侧即使没看到抛出的错误也能补网重跑（见 _pendingSusp）。
    try { globalThis.__lgSuspLog.push('__JSSUSP__' + d.kind + '__' + d.b64); } catch (e) {}
    throw new Error('__JSSUSP__' + d.kind + '__' + d.b64);
  };
  function __lgv(d, dft) {
    if (d && d.v !== null && d.v !== undefined) return d.v;
    return dft === undefined ? '' : dft;
  }
  // java.ajax / java.get / java.post 的统一返回：Legado StrResponse 形状。
  // 同时实现 toString，兼容把结果直接当字符串用的脚本。
  function __lgResp(d) {
    var body = d && d.v !== null && d.v !== undefined ? String(d.v) : '';
    var meta = (d && d.meta) || {};
    var hm = meta.headers || {};
    var resp = {
      body: function () { return body; },
      string: function () { return body; },
      bytes: function () { return __lgBytes(body); },
      byteArray: function () { return __lgBytes(body); },
      url: function () { return meta.url ? String(meta.url) : ''; },
      code: function () { return meta.code === undefined || meta.code === null ? 200 : (meta.code | 0); },
      status: function () { return resp.code(); },
      header: function (k) {
        if (k === undefined || k === null) return '';
        var kk = String(k).toLowerCase(), v = hm[kk];
        if (v === undefined) {
          for (var key in hm) { if (String(key).toLowerCase() === kk) { v = hm[key]; break; } }
        }
        return v === undefined || v === null ? '' : String(v);
      },
      headers: function () {
        var out = [];
        for (var key in hm) out.push([key, String(hm[key])]);
        return out;
      },
      headerMap: function () {
        var m = {};
        for (var key in hm) m[key] = String(hm[key]);
        return m;
      },
      toString: function () { return body; },
      valueOf: function () { return body; }
    };
    return resp;
  }
  // 单独代理成对的代理项：书源常用 substring/indexOf 切 HTML，容易切出
  // 「孤立代理项」，QuickJS→Dart 的 UTF-8 转换会整串失败（返回 null）。
  globalThis.__lgClean = function (s) {
    if (typeof s !== 'string') return s;
    var out = '', n = s.length, i, c, d;
    for (i = 0; i < n; i++) {
      c = s.charCodeAt(i);
      if (c >= 0xd800 && c <= 0xdbff) {
        d = i + 1 < n ? s.charCodeAt(i + 1) : 0;
        if (d >= 0xdc00 && d <= 0xdfff) {
          out += s.charAt(i) + s.charAt(i + 1);
          i++;
        } else out += '\ufffd';
      } else if (c >= 0xdc00 && c <= 0xdfff) {
        out += '\ufffd';
      } else out += s.charAt(i);
    }
    return out;
  };
  globalThis.__lgResp = __lgResp;
  // legado 规则 → CSS：`@css:x` 直取；`class.a@b` → `.a b`；`id.x` → `#x`；
  // 末尾 `@text/@html/@attr` 对取元素无意义，丢掉。
  function __lgRuleCss(rule) {
    var r = String(rule === null || rule === undefined ? '' : rule);
    if (/^@css:/i.test(r)) return r.replace(/^@css:/i, '');
    var parts = r.split('@');
    var head = parts[0];
    var tail = [];
    for (var i = 1; i < parts.length; i++) {
      var p = parts[i];
      if (/^(text|html|outerHtml|ownText|all)$/i.test(p)) break;
      tail.push(p);
    }
    function one(seg) {
      var m = /^class\.(.+)$/.exec(seg);
      if (m) return '.' + m[1];
      m = /^id\.(.+)$/.exec(seg);
      if (m) return '#' + m[1];
      m = /^tag\.(.+)$/.exec(seg);
      if (m) return m[1];
      return seg;
    }
    var css = one(head);
    for (var j = 0; j < tail.length; j++) css += ' ' + one(tail[j]);
    return css;
  }
  function __lgSelectAll(html, css) {
    var d = __lgcall('jcompat', {
      op: 'selector', html: String(html), css: String(css || 'html')
    });
    var arr = (d && d.v) || [];
    var out = [];
    for (var i = 0; i < arr.length; i++) {
      var h = arr[i] && arr[i].html;
      if (h) out.push(String(h));
    }
    if (typeof globalThis.__lgElementsFromHtml === 'function') {
      return globalThis.__lgElementsFromHtml(out);
    }
    return out;
  }
  // 预置脚本里没有 javaLibShim 的 b64/toBytes 工具（那份在独立的 IIFE 作用域里），
  // java.strToBytes/bytesToStr 要自己转字节数组。
  function __lgArr(v) {
    if (v === null || v === undefined) return [];
    if (typeof v === 'string') return __lgBytes(v);
    if (v.length !== undefined) return Array.prototype.slice.call(v);
    return [];
  }
  var __lgB64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function __lgB64d(s) {
    var t = String(s === null || s === undefined ? '' : s).replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [], i, n = 0, bits = 0;
    for (i = 0; i < t.length; i++) {
      var c = t.charAt(i);
      if (c === '=') break;
      var v = __lgB64A.indexOf(c);
      if (v < 0) continue;
      n = (n << 6) | v;
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((n >> bits) & 0xff);
      }
    }
    return out;
  }
  function __lgB64e(arr) {
    var s = '', i;
    for (i = 0; i + 2 < arr.length; i += 3) {
      var n = ((arr[i] & 255) << 16) | ((arr[i + 1] & 255) << 8) | (arr[i + 2] & 255);
      s += __lgB64A.charAt((n >> 18) & 63) + __lgB64A.charAt((n >> 12) & 63) +
        __lgB64A.charAt((n >> 6) & 63) + __lgB64A.charAt(n & 63);
    }
    if (i < arr.length) {
      var rem = arr.length - i;
      var n2 = ((arr[i] & 255) << 16) | (rem > 1 ? ((arr[i + 1] & 255) << 8) : 0);
      s += __lgB64A.charAt((n2 >> 18) & 63) + __lgB64A.charAt((n2 >> 12) & 63) +
        (rem > 1 ? __lgB64A.charAt((n2 >> 6) & 63) : '=') + '=';
    }
    return s;
  }
  function __lgBytes(s) {
    var a = [], i, c, d;
    for (i = 0; i < s.length; i++) {
      c = s.charCodeAt(i);
      if (c < 0x80) a.push(c);
      else if (c < 0x800) a.push(0xc0 | (c >> 6), 0x80 | (c & 0x3f));
      else if (c >= 0xd800 && c < 0xdc00) {
        d = s.charCodeAt(++i);
        c = 0x10000 + ((c - 0xd800) << 10) + (d - 0xdc00);
        a.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 0x3f), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
      } else a.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 0x3f), 0x80 | (c & 0x3f));
    }
    return a;
  }
  globalThis.java = {
    __httpRaw: function (method, url, body, headers) {
      var d = __lgcall('ajax', {
        url: String(url),
        method: String(method || 'GET').toUpperCase(),
        headers: headers === null || headers === undefined ? null : headers,
        body: body === null || body === undefined ? null : String(body)
      });
      if (d && d.suspend) __lgsusp(d);
      return d;
    },
    __http: function (method, url, body, headers) {
      return __lgResp(java.__httpRaw(method, url, body, headers));
    },
    // legado `override fun ajax(url: Any): String?` —— 返回**响应体字符串**
    // （`AnalyzeUrl.getStrResponse().body`），不是 StrResponse 对象。
    // 多看阅读等源直接对返回值调 `.match()/.split()`，给对象会 TypeError。
    ajax: function (a, b) {
      var d;
      if (a !== null && a !== undefined && typeof a === 'object' && !Array.isArray(a)) {
        d = java.__httpRaw(a.method ? a.method : 'GET', a.url, a.body, a.headers);
      } else {
        // legado：`url is List` 时取首个元素
        var u = Array.isArray(a) ? (a.length ? a[0] : '') : a;
        d = java.__httpRaw('GET', u, null, b);
      }
      if (d === null || d === undefined) return '';
      return d.v === null || d.v === undefined ? '' : String(d.v);
    },
    connect: function (url, headers) { return java.__http('GET', url, null, headers); },
    getStrResponse: function (url, a, b, c) {
      // (url) | (url, headers) | (url, method, body, headers)
      if (a !== null && a !== undefined && typeof a === 'object') {
        return java.__http('GET', url, null, a);
      }
      if (a === null || a === undefined) return java.__http('GET', url, null, null);
      return java.__http(String(a), url, b, c);
    },
    postStrResponse: function (url, body, headers) { return java.__http('POST', url, body, headers); },
    get: function (a, b) {
      if (b !== undefined) return java.__http('GET', a, null, b);
      var s = String(a);
      if (/^https?:\/\//i.test(s)) return java.__http('GET', s, null, null);
      return __lgv(__lgcall('var.get', { k: s }), null);
    },
    post: function (url, body, headers) { return java.__http('POST', url, body, headers); },
    webView: function (url, opts) {
      var d = __lgcall('webview', { url: String(url), opts: opts === null || opts === undefined ? null : opts });
      if (d && d.suspend) __lgsusp(d);
      return __lgResp(d);
    },
    startBrowserAwait: function (url, opts) { return java.webView(url, opts); },
    startBrowser: function (url, opts) { return java.webView(url, opts); },
    ajaxAll: function (urls) {
      var out = [];
      if (urls) { for (var i = 0; i < urls.length; i++) out.push(java.ajax(urls[i])); }
      return out;
    },
    longToast: function (msg) { __lgcall('toast', { msg: msg === null || msg === undefined ? '' : String(msg) }); },
    // 繁→简：书源多用于标题去重/比较，原样返回不会造成解析失败
    t2s: function (s) { return s === null || s === undefined ? '' : String(s); },
    s2t: function (s) { return s === null || s === undefined ? '' : String(s); },
    refreshExplore: function () { return true; },
    base64Decode: function (s) { return __lgv(__lgcall('b64d', { s: s === null || s === undefined ? '' : String(s) })); },
    base64Encode: function (s) { return __lgv(__lgcall('b64e', { s: s === null || s === undefined ? '' : String(s) })); },
    hexDecodeToString: function (s) { return __lgv(__lgcall('hexd', { s: s === null || s === undefined ? '' : String(s) })); },
    hexEncodeToString: function (s) { return __lgv(__lgcall('hexe', { s: s === null || s === undefined ? '' : String(s) })); },
    encodeURI: function (s, enc) { return __lgv(__lgcall('encuri', { s: s === null || s === undefined ? '' : String(s), enc: enc === null || enc === undefined ? null : String(enc) })); },
    timeFormat: function (time, format) { return __lgv(__lgcall('timeFmt', { time: time, utc: false, format: format === null || format === undefined ? null : String(format) })); },
    timeFormatUTC: function (time, format, sh) { return __lgv(__lgcall('timeFmt', { time: time, utc: true, format: format === null || format === undefined ? null : String(format), sh: sh })); },
    md5Encode: function (s) { return __lgv(__lgcall('md5', { s: String(s) })); },
    md5Encode16: function (s) { return __lgv(__lgcall('md5_16', { s: String(s) })); },
    aesBase64DecodeToString: function (str, key, transformation, iv) {
      return __lgv(__lgcall('aes', { str: String(str), key: String(key), transformation: String(transformation), iv: iv === null || iv === undefined ? '' : String(iv) }), null);
    },
    getString: function (rule) { return __lgv(__lgcall('getString', { rule: String(rule) })); },
    // ---- 加密（SymmetricCrypto）：书源用它解接口密文/加密请求体 ----
    createSymmetricCrypto: function (transformation, key, iv) {
      function mat(x) {
        if (x === null || x === undefined) return null;
        if (typeof x === 'string') return x;
        if (x.length !== undefined) return Array.prototype.slice.call(x);
        return String(x);
      }
      var t = transformation === null || transformation === undefined ? 'AES/CBC/PKCS5Padding' : String(transformation);
      var k = mat(key), v = mat(iv);
      function call(op, data, out) {
        return __lgcall('sym', { op: op, t: t, key: k, iv: v, data: String(data), out: out });
      }
      return {
        encrypt: function (s) { return __lgv(call('enc', s, 'bytes'), []); },
        encryptBase64: function (s) { return __lgv(call('enc', s, 'b64'), null); },
        encryptHex: function (s) { return __lgv(call('enc', s, 'hex'), null); },
        decrypt: function (d) { return __lgv(call('dec', d, 'bytes'), []); },
        decryptStr: function (d) { return __lgv(call('dec', d, 'str'), null); }
      };
    },
    base64DecodeToByteArray: function (s) { return __lgv(__lgcall('b64b', { s: s === null || s === undefined ? '' : String(s) }), []); },
    deviceID: function () { return __lgv(__lgcall('deviceid', {})); },
    androidId: function () { return java.deviceID(); },
    // 以下在 legado 里要么弹 UI、要么只有安卓端才有；给稳定返回值即可，
    // 让脚本继续往下跑（缺成员是 TypeError，整条规则直接空）。
    showBrowser: function () { return true; },
    showReadingBrowser: function () { return true; },
    startBrowserDp: function () { return true; },
    reLoginView: function () { return true; },
    qread: function () { return true; },
    getElement: function (rule) { return __lgv(__lgcall('getElement', { rule: String(rule) })); },
    // 上游返回 jsoup Elements（`java.getElements('class.x@li')` → 可迭代）。
    // 元素包装交给 Packages 层：那边有 jsoup 节点代理与集合方法。
    getElements: function (rule) {
      var list;
      var over = globalThis.__lgContent;
      if (typeof over === 'string' && over) {
        list = __lgSelectAll(over, __lgRuleCss(String(rule)));
      } else {
        var d = __lgcall('getElements', { rule: String(rule) });
        list = (d && d.v) || [];
      }
      if (typeof globalThis.__lgElementsFromHtml === 'function') {
        return globalThis.__lgElementsFromHtml(list);
      }
      return list;
    },
    // HTML 美化：上游 HtmlFormatter 会缩进。源脚本常拿它跑正则，
    // 这里在标签边界换行（属性内部不动），形状一致即可。
    htmlFormat: function (html) {
      var s = html === null || html === undefined ? '' : String(html);
      s = s.replace(/>\s*</g, '>\n<');
      var lines = s.split('\n');
      var out = '', depth = 0;
      for (var i = 0; i < lines.length; i++) {
        var ln = lines[i].replace(/^\s+|\s+$/g, '');
        if (!ln) continue;
        if (/^<\//.test(ln)) depth = depth > 0 ? depth - 1 : 0;
        out += new Array(depth + 1).join('  ') + ln + '\n';
        if (/^<[^!?/][^>]*[^/]>$/.test(ln) && !/^<(br|hr|img|input|meta|link|source)\b/i.test(ln)) {
          if (ln.indexOf('</') < 0) depth++;
        }
      }
      return out;
    },
    strToBytes: function (s, cs) {
      var b64 = __lgv(__lgcall('jcompat', {
        op: 'toBytes', text: s === null || s === undefined ? '' : String(s),
        cs: cs === null || cs === undefined ? 'UTF-8' : String(cs)
      }), '');
      return __lgB64d(b64);
    },
    bytesToStr: function (b, cs) {
      return __lgv(__lgcall('jcompat', {
        op: 'fromBytes', data: __lgB64e(__lgArr(b)),
        cs: cs === null || cs === undefined ? 'UTF-8' : String(cs)
      }), '');
    },
    // ---- 规则/内容上下文（上游 java.setContent + getElements 组合） ----
    // 搬山人：`va.setContent(markup, pageUrl); java.getElements('@css:html')`
    // —— 先把 HTML 灌进当前解析器，再按规则取元素。这里用全局覆盖变量实现，
    // getElements 优先读它（见下）。
    setContent: function (html, url) {
      globalThis.__lgContent = html === null || html === undefined ? '' : String(html);
      globalThis.__lgContentUrl = url === null || url === undefined ? '' : String(url);
      return true;
    },
    getStringList: function (rule) {
      var s = java.getString(rule);
      return s === null || s === undefined || s === '' ? [] : String(s).split('\n');
    },
    // ---- 登录/浏览器交互类：无 UI 的平台上给稳定返回值，别让规则空掉 ----
    getVerificationCode: function () { return ''; },
    upLoginData: function () { return true; },
    reUiView: function () { return true; },
    refreshTocUrl: function () { return true; },
    clearCookie: function (tag) { __lgcall('cookie.del', { tag: String(tag) }); return true; },
    downloadFile: function () { return ''; },
    readFile: function () { return ''; },
    aesEncodeToBase64String: function (str, key, transformation, iv) {
      return java.createSymmetricCrypto(transformation, key, iv).encryptBase64(String(str));
    },
    digestHex: function (v) {
      var arr = __lgArr(v), out = '';
      for (var i = 0; i < arr.length; i++) {
        var x = arr[i] & 0xff;
        out += (x < 16 ? '0' : '') + x.toString(16);
      }
      return out;
    },
    createAsymmetricCrypto: function () {
      return {
        encrypt: function () { return ''; },
        encryptBase64: function () { return ''; },
        encryptHex: function () { return ''; },
        decrypt: function () { return ''; },
        decryptStr: function () { return ''; }
      };
    },
    toURL: function (u) {
      var s = u === null || u === undefined ? '' : String(u);
      return {
        toString: function () { return s; },
        toExternalForm: function () { return s; },
        getPath: function () { return s.replace(/^[a-z]+:\/\/[^\/]+/i, '').split('?')[0]; },
        openConnection: function () { return null; }
      };
    },
    put: function (key, value) { __lgcall('var.put', { k: String(key), v: value === null || value === undefined ? null : String(value) }); return value; },
    log: function (msg) { __lgcall('log', { msg: msg === null || msg === undefined ? '' : String(msg) }); },
    toast: function (msg) { __lgcall('toast', { msg: msg === null || msg === undefined ? '' : String(msg) }); },
    getWebViewUA: function () { return __lgv(__lgcall('ua', {})); },
    getCookie: function (tag, key) { return __lgv(__lgcall('cookie.get', { tag: String(tag), key: key === null || key === undefined ? null : String(key) })); },
    setCookie: function (tag, v) { __lgcall('cookie.set', { tag: String(tag), v: v === null || v === undefined ? '' : String(v) }); return true; },
    randomUUID: function () {
      var b = __lgArr(__lgv(__lgcall('jcompat', { op: 'random', n: 16 }), ''));
      if (!b || b.length < 16) b = __lgB64d(__lgv(__lgcall('jcompat', { op: 'random', n: 16 }), ''));
      var h = '';
      for (var i = 0; i < 16 && i < b.length; i++) {
        var x = b[i] & 0xff;
        h += (x < 16 ? '0' : '') + x.toString(16);
      }
      while (h.length < 32) h += '0';
      return h.slice(0, 8) + '-' + h.slice(8, 12) + '-4' + h.slice(13, 16) + '-' +
        ((parseInt(h.charAt(16), 16) & 3) | 8).toString(16) + h.slice(17, 20) + '-' + h.slice(20, 32);
    },
    queryTTF: function (data) { return __lgv(__lgcall('ttf', { s: String(data) }), null); },
    queryBase64TTF: function (data) { return __lgv(__lgcall('ttfb64', { s: String(data) }), null); },
    replaceFont: function (text, ttf) { return __lgv(__lgcall('font', { text: text === null || text === undefined ? '' : String(text), ttf: String(ttf) })); }
  };
  globalThis.cookie = {
    getCookie: function (tag, key) { return java.getCookie(tag, key); },
    getKey: function (tag) { return String(tag); },
    setCookie: function (tag, v) { __lgcall('cookie.set', { tag: String(tag), v: v === null || v === undefined ? '' : String(v) }); },
    removeCookie: function (tag) { __lgcall('cookie.del', { tag: String(tag) }); }
  };
  globalThis.cache = {
    get: function (key) { return __lgv(__lgcall('cache.get', { k: String(key) }), null); },
    put: function (key, value) { __lgcall('cache.put', { k: String(key), v: value === null || value === undefined ? null : String(value) }); },
    delete: function (key) { __lgcall('cache.delete', { k: String(key) }); }
  };
})();
''';

  /// java-lib 垫层（对照 legado Rhino 的 Java 桥常用面）：
  /// - `String.getBytes()` / `new String(bytes, charset)`（java.lang.String 行为）
  /// - `Base64.getDecoder().decode`（java.util.Base64）
  /// - `DESKeySpec/SecretKeyFactory/Cipher("DES/CBC/PKCS5Padding")/IvParameterSpec`
  ///   —— 纯 JS DES 实现，密文向量用 .NET DES 生成锚定（compat 测试）
  /// - `org.jsoup.Jsoup.connect(url).get()`（同步抓页，走 java.ajax 挂起补网）
  /// - `Packages.*` / `JavaImporter` 哑对象（importPackage 为 no-op）
  /// 运行时按书源作用域各自装配，String 扩展不跨源泄漏。
  static const String _javaLibShim = r'''
(function (g) {
  var $String = String;
  function utf8Encode(s) {
    var out = [];
    for (var i = 0; i < s.length; i++) {
      var c = s.codePointAt(i);
      if (c > 0xffff) i++;
      if (c < 0x80) out.push(c);
      else if (c < 0x800) out.push(0xc0 | (c >> 6), 0x80 | (c & 63));
      else if (c < 0x10000) out.push(0xe0 | (c >> 12), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
      else out.push(0xf0 | (c >> 18), 0x80 | ((c >> 12) & 63), 0x80 | ((c >> 6) & 63), 0x80 | (c & 63));
    }
    return out;
  }
  function utf8Decode(b) {
    var s = '', i = 0;
    while (i < b.length) {
      var c = b[i];
      if (c < 0x80) { s += $String.fromCharCode(c); i++; }
      else if ((c & 0xe0) === 0xc0) { s += $String.fromCharCode(((c & 31) << 6) | (b[i + 1] & 63)); i += 2; }
      else if ((c & 0xf0) === 0xe0) { s += $String.fromCharCode(((c & 15) << 12) | ((b[i + 1] & 63) << 6) | (b[i + 2] & 63)); i += 3; }
      else {
        var cp = ((c & 7) << 18) | ((b[i + 1] & 63) << 12) | ((b[i + 2] & 63) << 6) | (b[i + 3] & 63);
        i += 4;
        cp -= 0x10000;
        s += $String.fromCharCode(0xd800 + (cp >> 10), 0xdc00 + (cp & 0x3ff));
      }
    }
    return s;
  }
  var B64A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  function b64Decode(b) {
    var s = '';
    for (var i = 0; i < b.length; i++) s += $String.fromCharCode((b[i] | 0) & 0xff);
    s = s.replace(/[^A-Za-z0-9+/=]/g, '');
    var out = [], bits = 0, val = 0;
    for (var i = 0; i < s.length; i++) {
      var ch = s[i];
      if (ch === '=' || ch === undefined) break;
      var idx = B64A.indexOf(ch);
      if (idx < 0) continue;
      val = (val << 6) | idx;
      bits += 6;
      if (bits >= 8) { bits -= 8; out.push((val >> bits) & 0xff); }
    }
    return out;
  }

  // ---------- 纯 JS DES（标准表 + CBC/PKCS5） ----------
  var IP = [58,50,42,34,26,18,10,2,60,52,44,36,28,20,12,4,62,54,46,38,30,22,14,6,64,56,48,40,32,24,16,8,
            57,49,41,33,25,17,9,1,59,51,43,35,27,19,11,3,61,53,45,37,29,21,13,5,63,55,47,39,31,23,15,7];
  var FP = [40,8,48,16,56,24,64,32,39,7,47,15,55,23,63,31,38,6,46,14,54,22,62,30,37,5,45,13,53,21,61,29,
            36,4,44,12,52,20,60,28,35,3,43,11,51,19,59,27,34,2,42,10,50,18,58,26,33,1,41,9,49,17,57,25];
  var E = [32,1,2,3,4,5,4,5,6,7,8,9,8,9,10,11,12,13,12,13,14,15,16,17,16,17,18,19,20,21,
           20,21,22,23,24,25,24,25,26,27,28,29,28,29,30,31,32,1];
  var P = [16,7,20,21,29,12,28,17,1,15,23,26,5,18,31,10,2,8,24,14,32,27,3,9,19,13,30,6,22,11,4,25];
  var PC1 = [57,49,41,33,25,17,9,1,58,50,42,34,26,18,10,2,59,51,43,35,27,19,11,3,60,52,44,36,
             63,55,47,39,31,23,15,7,62,54,46,38,30,22,14,6,61,53,45,37,29,21,13,5,28,20,12,4];
  var PC2 = [14,17,11,24,1,5,3,28,15,6,21,10,23,19,12,4,26,8,16,7,27,20,13,2,
             41,52,31,37,47,55,30,40,51,45,33,48,44,49,39,56,34,53,46,42,50,36,29,32];
  var SHIFTS = [1,1,2,2,2,2,2,2,1,2,2,2,2,2,2,1];
  var S = [
    [14,4,13,1,2,15,11,8,3,10,6,12,5,9,0,7,0,15,7,4,14,2,13,1,10,6,12,11,9,5,3,8,
     4,1,14,8,13,6,2,11,15,12,9,7,3,10,5,0,15,12,8,2,4,9,1,7,5,11,3,14,10,0,6,13],
    [15,1,8,14,6,11,3,4,9,7,2,13,12,0,5,10,3,13,4,7,15,2,8,14,12,0,1,10,6,9,11,5,
     0,14,7,11,10,4,13,1,5,8,12,6,9,3,2,15,13,8,10,1,3,15,4,2,11,6,7,12,0,5,14,9],
    [10,0,9,14,6,3,15,5,1,13,12,7,11,4,2,8,13,7,0,9,3,4,6,10,2,8,5,14,12,11,15,1,
     13,6,4,9,8,15,3,0,11,1,2,12,5,10,14,7,1,10,13,0,6,9,8,7,4,15,14,3,11,5,2,12],
    [7,13,14,3,0,6,9,10,1,2,8,5,11,12,4,15,13,8,11,5,6,15,0,3,4,7,2,12,1,10,14,9,
     10,6,9,0,12,11,7,13,15,1,3,14,5,2,8,4,3,15,0,6,10,1,13,8,9,4,5,11,12,7,2,14],
    [2,12,4,1,7,10,11,6,8,5,3,15,13,0,14,9,14,11,2,12,4,7,13,1,5,0,15,10,3,9,8,6,
     4,2,1,11,10,13,7,8,15,9,12,5,6,3,0,14,11,8,12,7,1,14,2,13,6,15,0,9,10,4,5,3],
    [12,1,10,15,9,2,6,8,0,13,3,4,14,7,5,11,10,15,4,2,7,12,9,5,6,1,13,14,0,11,3,8,
     9,14,15,5,2,8,12,3,7,0,4,10,1,13,11,6,4,3,2,12,9,5,15,10,11,14,1,7,6,0,8,13],
    [4,11,2,14,15,0,8,13,3,12,9,7,5,10,6,1,13,0,11,7,4,9,1,10,14,3,5,12,2,15,8,6,
     1,4,11,13,12,3,7,14,10,15,6,8,0,5,9,2,6,11,13,8,1,4,10,7,9,5,0,15,14,2,3,12],
    [13,2,8,4,6,15,11,1,10,9,3,14,5,0,12,7,1,15,13,8,10,3,7,4,12,5,6,11,0,14,9,2,
     7,11,4,1,9,12,14,2,0,6,10,13,15,3,5,8,2,1,14,7,4,10,8,13,15,12,9,0,3,5,6,11]
  ];
  function bytesToBits(b) {
    var bits = [];
    for (var i = 0; i < b.length * 8; i++) bits.push((b[i >> 3] >> (7 - (i & 7))) & 1);
    return bits;
  }
  function bitsToBytes(bits) {
    var b = [];
    for (var i = 0; i < bits.length; i += 8) {
      var v = 0;
      for (var j = 0; j < 8; j++) v = (v << 1) | bits[i + j];
      b.push(v & 0xff);
    }
    return b;
  }
  function permute(src, table, offset) {
    var out = [];
    for (var i = 0; i < table.length; i++) out.push(src[table[i] - 1 + (offset || 0)]);
    return out;
  }
  function desKeySchedule(k) {
    var bits = bytesToBits(k.slice(0, 8));
    var pc1b = permute(bits, PC1);
    var L = pc1b.slice(0, 28), R = pc1b.slice(28);
    var keys = [];
    for (var r = 0; r < 16; r++) {
      var sh = SHIFTS[r];
      for (var i = 0; i < sh; i++) { L.push(L.shift()); R.push(R.shift()); }
      keys.push(permute(L.concat(R), PC2));
    }
    return keys;
  }
  function fexp(R, rk) {
    var e = permute(R, E);
    for (var i = 0; i < 48; i++) e[i] ^= rk[i];
    var out = [];
    for (var b = 0; b < 8; b++) {
      var seg = e.slice(b * 6, b * 6 + 6);
      var row = (seg[0] << 1) | seg[5];
      var col = (seg[1] << 3) | (seg[2] << 2) | (seg[3] << 1) | seg[4];
      var v = S[b][row * 16 + col];
      for (var j = 3; j >= 0; j--) out.push((v >> j) & 1);
    }
    return permute(out, P);
  }
  function desCrypt(block, keys, decrypt) {
    var bits = bytesToBits(block);
    var ipb = permute(bits, IP);
    var L = ipb.slice(0, 32), R = ipb.slice(32);
    for (var r = 0; r < 16; r++) {
      var rk = decrypt ? keys[15 - r] : keys[r];
      var f = fexp(R, rk);
      var next = [];
      for (var i = 0; i < 32; i++) next.push(L[i] ^ f[i]);
      L = R; R = next;
    }
    return bitsToBytes(permute(R.concat(L), FP));
  }
  function desCbc(data, key, iv, decrypt) {
    var keys = desKeySchedule(key);
    var n = data.length - (data.length % 8);
    if (n <= 0) throw new Error('DES: 数据长度不是 8 的倍数');
    var prev = iv.slice(0, 8);
    var out = [];
    for (var i = 0; i < n; i += 8) {
      var b = data.slice(i, i + 8);
      var cb = desCrypt(b, keys, decrypt);
      for (var j = 0; j < 8; j++) out.push(cb[j] ^ prev[j]);
      prev = decrypt ? b : cb;
    }
    if (decrypt) {
      var pad = out[out.length - 1];
      if (pad < 1 || pad > 8) throw new Error('DES: PKCS5 填充非法');
      out = out.slice(0, out.length - pad);
    }
    return out;
  }

  function Str(x, enc) {
    if (this instanceof Str) {
      // `new String(bytes, charset)` → String 对象（java.lang.String(bytes, enc) 同义）
      if (enc !== undefined && x !== null && x !== undefined &&
          typeof x !== 'string' && typeof x.length === 'number') {
        var v = [];
        for (var i = 0; i < x.length; i++) v.push((x[i] | 0) & 0xff);
        return new $String(utf8Decode(v));
      }
      return new $String(x === null || x === undefined ? '' : $String(x));
    }
    return x === null || x === undefined ? '' : $String(x);
  }
  Str.prototype = $String.prototype;
  Str.fromCharCode = $String.fromCharCode;
  Str.fromCodePoint = $String.fromCodePoint;
  try { Str.raw = $String.raw; } catch (_) {}
  $String.prototype.getBytes = function (cs) { return utf8Encode(this.toString()); };
  g.__lgUtf8Encode = utf8Encode;
  g.__lgUtf8Decode = utf8Decode;
  g.__lgDesCbc = desCbc;
  g.String = Str;

  function DESKeySpec(bytes) { this.__key = (bytes || []).slice(0, 8); }
  function IvParameterSpec(bytes) { this.__iv = toBytes(bytes); }
  function SecretKeySpec(bytes, alg) { this.__key = toBytes(bytes); this.__alg = alg ? $String(alg) : ''; }
  var secretKeyFactory = {
    getInstance: function (alg) {
      return {
        generateSecret: function (spec) { return spec; }
      };
    }
  };

  // ---------- 字节数组工具（书源里 byte[] 到处传） ----------
  function toBytes(v) {
    if (v === null || v === undefined) return [];
    if (Array.isArray(v)) return v;
    if (typeof v === 'object' && v.length !== undefined) return Array.prototype.slice.call(v);
    if (typeof v === 'string') return utf8Encode(v);
    return [];
  }
  function bytesToHex(b) {
    var s = '';
    for (var i = 0; i < b.length; i++) {
      var x = (b[i] | 0) & 0xff;
      s += (x < 16 ? '0' : '') + x.toString(16);
    }
    return s;
  }
  function b64Encode(b) {
    var s = '', i;
    for (i = 0; i + 2 < b.length; i += 3) {
      var n = ((b[i] & 255) << 16) | ((b[i + 1] & 255) << 8) | (b[i + 2] & 255);
      s += B64A[(n >> 18) & 63] + B64A[(n >> 12) & 63] + B64A[(n >> 6) & 63] + B64A[n & 63];
    }
    if (i < b.length) {
      var rem = b.length - i;
      var n2 = ((b[i] & 255) << 16) | (rem > 1 ? ((b[i + 1] & 255) << 8) : 0);
      s += B64A[(n2 >> 18) & 63] + B64A[(n2 >> 12) & 63] +
        (rem > 1 ? B64A[(n2 >> 6) & 63] : '=') + '=';
    }
    return s;
  }

  // ---------- java.security.MessageDigest ----------
  // 上游：getInstance(alg) → update(byte[]) → digest() 返回 byte[]。
  // 摘要走 Dart 侧 package:crypto（与 Java 逐字节一致）。
  function MessageDigest(alg) { this.__alg = $String(alg).toUpperCase(); this.__buf = []; }
  MessageDigest.prototype.update = function (v) { this.__buf = this.__buf.concat(toBytes(v)); };
  MessageDigest.prototype.reset = function () { this.__buf = []; };
  MessageDigest.prototype.digest = function (v) {
    if (arguments.length > 0 && v !== undefined) this.update(v);
    var d = g.__lgcall('digest', { alg: this.__alg, data: this.__buf });
    this.__buf = [];
    return d && d.v ? d.v : [];
  };
  MessageDigest.getInstance = function (alg) { return new MessageDigest(alg); };

  // ---------- java.math.BigInteger ----------
  // 签名书源几乎都写成 new BigInteger(1, md5bytes).toString(16)。
  function BigInteger(a, b) {
    var hex = '0';
    if (b !== undefined) hex = bytesToHex(toBytes(b));
    else if (typeof a === 'number') hex = Math.abs(a).toString(16);
    else if (Array.isArray(a)) hex = bytesToHex(toBytes(a));
    else {
      var s = $String(a === undefined || a === null ? '0' : a).trim();
      if (/^0x/i.test(s)) hex = s.substring(2).toLowerCase();
      else if (/^-?[0-9]+$/.test(s)) hex = BigInt(s).toString(16);
      else hex = '0';
      if (/^-/.test(s)) hex = '0';
    }
    hex = hex.replace(/^0+/, '');
    this.__hex = hex === '' ? '0' : hex;
  }
  BigInteger._of = function (h) {
    var o = Object.create(BigInteger.prototype);
    var x = (h || '0').replace(/^0+/, '');
    o.__hex = x === '' ? '0' : x;
    return o;
  };
  BigInteger._big = function (v) { return BigInt('0x' + (v.__hex || '0')); };
  BigInteger.prototype.toString = function (radix) {
    var r = radix === undefined || radix === null ? 10 : radix | 0;
    if (r === 16) return this.__hex;
    return BigInteger._big(this).toString(r);
  };
  BigInteger.prototype.bitLength = function () { return BigInteger._big(this).toString(2).length; };
  BigInteger.prototype.toByteArray = function () {
    var h = this.__hex.length % 2 ? '0' + this.__hex : this.__hex;
    var out = [];
    for (var i = 0; i < h.length; i += 2) out.push(parseInt(h.substring(i, i + 2), 16));
    return out;
  };
  BigInteger.prototype.add = function (o) { return BigInteger._of((BigInteger._big(this) + BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.subtract = function (o) { return BigInteger._of((BigInteger._big(this) - BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.multiply = function (o) { return BigInteger._of((BigInteger._big(this) * BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.divide = function (o) { return BigInteger._of((BigInteger._big(this) / BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.remainder = function (o) { return BigInteger._of((BigInteger._big(this) % BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.mod = function (o) { return this.remainder(o); };
  BigInteger.prototype.modPow = function (e, m) {
    return BigInteger._of(BigInteger._big(this).toString(16) ? powmod(BigInteger._big(this), BigInteger._big(e), BigInteger._big(m)).toString(16) : '0');
  };
  BigInteger.prototype.xor = function (o) { return BigInteger._of((BigInteger._big(this) ^ BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.and = function (o) { return BigInteger._of((BigInteger._big(this) & BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.or = function (o) { return BigInteger._of((BigInteger._big(this) | BigInteger._big(o)).toString(16)); };
  BigInteger.prototype.shiftLeft = function (n) { return BigInteger._of((BigInteger._big(this) << BigInt(n | 0)).toString(16)); };
  BigInteger.prototype.shiftRight = function (n) { return BigInteger._of((BigInteger._big(this) >> BigInt(n | 0)).toString(16)); };
  BigInteger.prototype.compareTo = function (o) {
    var a = BigInteger._big(this), b = BigInteger._big(o);
    return a < b ? -1 : (a > b ? 1 : 0);
  };
  BigInteger.prototype.signum = function () { return this.__hex === '0' ? 0 : 1; };
  BigInteger.ZERO = BigInteger._of('0');
  BigInteger.ONE = BigInteger._of('1');
  BigInteger.TWO = BigInteger._of('2');
  function powmod(b, e, m) { var r = BigInt(1); b = b % m; while (e > BigInt(0)) { if (e & BigInt(1)) r = (r * b) % m; e = e >> BigInt(1); b = (b * b) % m; } return r; }

  // ---------- javax.crypto.Cipher ----------
  // AES/DESede/Blowfish 走 Dart 侧 pointycastle（'sym'），单 DES 走纯 JS。
  function newCipher(trans) {
    return {
      __t: $String(trans),
      init: function (mode, key, iv) {
        this.__mode = (mode === 2 || mode === cipher.DECRYPT_MODE) ? 2 : 1;
        this.__k = (key && key.__key !== undefined) ? key.__key : toBytes(key);
        this.__iv = (iv && iv.__iv !== undefined) ? iv.__iv : toBytes(iv);
        return this;
      },
      doFinal: function (data) {
        var input = toBytes(data);
        var up = this.__t.toUpperCase();
        if (up.indexOf('DES') >= 0 && up.indexOf('EDE') < 0) {
          return desCbc(input, this.__k, this.__iv, this.__mode === 2);
        }
        var d = g.__lgcall('sym', {
          op: this.__mode === 2 ? 'dec' : 'enc', t: this.__t,
          key: this.__k, iv: this.__iv, data: input, out: 'bytes'
        });
        return d && d.v ? d.v : [];
      },
      update: function (data) { return this.doFinal(data); }
    };
  }
  var cipher = { getInstance: function (t) { return newCipher(t); } };
  cipher.DECRYPT_MODE = 2;
  cipher.ENCRYPT_MODE = 1;

  // ---------- javax.crypto.Mac（HMAC-SHA1/SHA256） ----------
  var mac = {
    getInstance: function (alg) {
      return {
        init: function (spec) { this.__k = (spec && spec.__key !== undefined) ? spec.__key : toBytes(spec); },
        doFinal: function (data) {
          var d = g.__lgcall('hmac', { alg: $String(alg), key: this.__k, data: toBytes(data) });
          return d && d.v ? d.v : [];
        }
      };
    }
  };

  // ---------- java.util.Base64 / Arrays / UUID / HashMap / ArrayList ----------
  var base64 = {
    decode: function (v) { return b64Decode(toBytes(v)); },
    encode: function (b) { return toBytes(b); },
    encodeToString: function (b) { return b64Encode(toBytes(b)); },
    getDecoder: function () { return { decode: function (v) { return b64Decode(toBytes(v)); } }; },
    getEncoder: function () { return { encodeToString: function (b) { return b64Encode(toBytes(b)); } }; },
    getUrlDecoder: function () {
      return { decode: function (v) { return b64Decode(toBytes($String(v).replace(/-/g, '+').replace(/_/g, '/'))); } };
    },
    getUrlEncoder: function () {
      return { encodeToString: function (b) { return b64Encode(toBytes(b)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''); } };
    }
  };
  var Arrays = {
    toString: function (a) { return a === null || a === undefined ? 'null' : '[' + Array.prototype.join.call(a, ', ') + ']'; },
    equals: function (a, b) {
      if (a === b) return true;
      if (!a || !b || a.length !== b.length) return false;
      for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
      return true;
    },
    copyOf: function (a, n) { var o = new Array(n); for (var i = 0; i < n; i++) o[i] = i < a.length ? a[i] : 0; return o; },
    copyOfRange: function (a, f, t) { var o = []; for (var i = f; i < t; i++) o.push(i < a.length ? a[i] : 0); return o; },
    fill: function (a, v) { for (var i = 0; i < a.length; i++) a[i] = v; return a; },
    sort: function (a) { Array.prototype.sort.call(a, function (x, y) { return x - y; }); return a; }
  };
  var UUID = {
    randomUUID: function () {
      return {
        toString: function () {
          return hex4() + hex4() + '-' + hex4() + '-4' + hex4().substring(1) + '-a' +
            hex4().substring(1) + '-' + hex4() + hex4() + hex4();
        }
      };
    }
  };
  function hex4() { return ('000' + Math.floor(Math.random() * 0x10000).toString(16)).slice(-4); }
  function HashMap() { this.__m = {}; this.__o = []; }
  HashMap.prototype.put = function (k, v) {
    var s = $String(k);
    if (!(s in this.__m)) this.__o.push(s);
    var old = this.__m[s];
    this.__m[s] = v;
    return old;
  };
  HashMap.prototype.get = function (k) { var s = $String(k); return (s in this.__m) ? this.__m[s] : null; };
  HashMap.prototype.containsKey = function (k) { return $String(k) in this.__m; };
  HashMap.prototype.keySet = function () { return this.__o.slice(); };
  HashMap.prototype.values = function () {
    var o = [];
    for (var i = 0; i < this.__o.length; i++) o.push(this.__m[this.__o[i]]);
    return o;
  };
  HashMap.prototype.size = function () { return this.__o.length; };
  HashMap.prototype.remove = function (k) {
    var s = $String(k); delete this.__m[s];
    var i = this.__o.indexOf(s); if (i >= 0) this.__o.splice(i, 1);
  };
  function ArrayList(a) { this.__a = a ? Array.prototype.slice.call(a) : []; }
  ArrayList.prototype.add = function (v) { this.__a.push(v); return true; };
  ArrayList.prototype.get = function (i) { return this.__a[i]; };
  ArrayList.prototype.size = function () { return this.__a.length; };
  ArrayList.prototype.toArray = function () { return this.__a.slice(); };
  ArrayList.prototype.join = function (sep) { return this.__a.join(sep === undefined ? ',' : sep); };
  ArrayList.prototype.iterator = function () {
    var a = this.__a, i = 0;
    return { hasNext: function () { return i < a.length; }, next: function () { return a[i++]; } };
  };

  // ---------- java.io ----------
  function ByteArrayOutputStream() { this.__b = []; }
  ByteArrayOutputStream.prototype.write = function (v, off, len) {
    if (Array.isArray(v)) {
      var s = off || 0, e = (len === undefined) ? v.length : (s + len);
      for (var i = s; i < e && i < v.length; i++) this.__b.push(v[i] & 0xff);
    } else if (typeof v === 'string') {
      for (var j = 0; j < v.length; j++) this.__b.push(v.charCodeAt(j) & 0xff);
    } else this.__b.push(v & 0xff);
  };
  ByteArrayOutputStream.prototype.writeBytes = function (v) { this.write(toBytes(v)); };
  ByteArrayOutputStream.prototype.toByteArray = function () { return this.__b.slice(); };
  ByteArrayOutputStream.prototype.size = function () { return this.__b.length; };
  ByteArrayOutputStream.prototype.reset = function () { this.__b = []; };
  ByteArrayOutputStream.prototype.toString = function () { return utf8Decode(this.__b); };
  function ByteArrayInputStream(b) { this.__b = toBytes(b); this.__p = 0; }
  ByteArrayInputStream.prototype.read = function () { return this.__p < this.__b.length ? this.__b[this.__p++] : -1; };
  ByteArrayInputStream.prototype.available = function () { return this.__b.length - this.__p; };
  ByteArrayInputStream.prototype.close = function () { };
  function InputStreamReader(is) { this.__is = is; }
  InputStreamReader.prototype.read = function () { return this.__is && this.__is.read ? this.__is.read() : -1; };
  function BufferedReader(r) { this.__r = r; this.__lines = null; this.__i = 0; }
  BufferedReader.prototype.__init = function () {
    if (this.__lines !== null) return;
    var src = this.__r && this.__r.__is ? this.__r.__is.__b : toBytes(this.__r);
    this.__lines = utf8Decode(src).split(/\r?\n/);
  };
  BufferedReader.prototype.readLine = function () {
    this.__init();
    return this.__i < this.__lines.length ? this.__lines[this.__i++] : null;
  };
  BufferedReader.prototype.close = function () { };

  // ---------- java.lang.System / Thread / StringBuilder ----------
  var System = {
    currentTimeMillis: function () { return Date.now(); },
    nanoTime: function () { return Date.now() * 1000000; },
    arraycopy: function (src, sp, dst, dp, n) { for (var i = 0; i < n; i++) dst[dp + i] = src[sp + i]; },
    getProperty: function (k) { return k === 'line.separator' ? '\n' : ''; },
    getenv: function () { return null; },
    out: { println: function (s) { g.__lgcall('log', { msg: s === undefined ? '' : $String(s) }); }, print: function (s) { g.__lgcall('log', { msg: s === undefined ? '' : $String(s) }); } },
    exit: function () { }
  };
  function StringBuilder() { this.__a = []; }
  StringBuilder.prototype.append = function (s) { this.__a.push($String(s === null || s === undefined ? '' : s)); return this; };
  StringBuilder.prototype.toString = function () { return this.__a.join(''); };
  StringBuilder.prototype.reverse = function () { this.__a.reverse(); return this; };

  // ---------- java.net.URLEncoder / URLDecoder ----------
  var URLEncoder = {
    encode: function (s, cs) {
      return encodeURIComponent($String(s)).replace(/%20/g, '+')
        .replace(/[!'()~*]/g, function (c) { return '%' + c.charCodeAt(0).toString(16).toUpperCase(); });
    }
  };
  var URLDecoder = { decode: function (s, cs) { return decodeURIComponent($String(s).replace(/\+/g, ' ')); } };

  // ---------- 装配 ----------
  g.DESKeySpec = DESKeySpec;
  g.IvParameterSpec = IvParameterSpec;
  g.SecretKeySpec = SecretKeySpec;
  g.SecretKeyFactory = secretKeyFactory;
  g.Cipher = cipher;
  g.Base64 = base64;
  g.MessageDigest = MessageDigest;
  g.BigInteger = BigInteger;
  g.Arrays = Arrays;
  g.UUID = UUID;
  g.HashMap = HashMap;
  g.ArrayList = ArrayList;
  g.ByteArrayOutputStream = ByteArrayOutputStream;
  g.ByteArrayInputStream = ByteArrayInputStream;
  g.InputStreamReader = InputStreamReader;
  g.BufferedReader = BufferedReader;
  g.System = System;
  g.StringBuilder = StringBuilder;
  g.URLEncoder = URLEncoder;
  g.URLDecoder = URLDecoder;
  g.JavaImporter = function () {
    var o = { importPackage: function () { }, importClass: function () { } };
    var ks = ['DESKeySpec', 'IvParameterSpec', 'SecretKeySpec', 'SecretKeyFactory', 'Cipher', 'Base64',
      'MessageDigest', 'BigInteger', 'Arrays', 'UUID', 'HashMap', 'ArrayList',
      'ByteArrayOutputStream', 'ByteArrayInputStream', 'InputStreamReader', 'BufferedReader',
      'System', 'StringBuilder', 'URLEncoder', 'URLDecoder'];
    for (var i = 0; i < ks.length; i++) o[ks[i]] = g[ks[i]];
    return o;
  };
  var nioCharset = {
    Charset: {
      forName: function (n) { return { name: function () { return $String(n); } }; },
      isSupported: function () { return true; }
    },
    ByteBuffer: { wrap: function (b) { return b; } }
  };
  // 注意：`Packages` 由 java_compat_js.dart 的完整命名空间树负责（后加载，
  // 覆盖面更大）；这里只补**裸全局**（importPackage 后的写法），避免两套树打架。
  g.__lgBareJava = nioCharset;
  function SecureRandom() { }
  SecureRandom.prototype.nextBytes = function (a) { for (var i = 0; i < a.length; i++) a[i] = Math.floor(Math.random() * 256); };
  SecureRandom.prototype.nextInt = function (n) { return n === undefined ? Math.floor(Math.random() * 2147483647) : Math.floor(Math.random() * n); };
  SecureRandom.prototype.nextLong = function () { return Math.floor(Math.random() * 9007199254740991); };
  g.SecureRandom = SecureRandom;
  g.org = {
    jsoup: {
      Jsoup: {
        connect: function (url) {
          var body;
          try { body = java.ajax(url); } catch (e) { throw e; }
          return { get: function () { return body; }, body: body };
        },
        parse: function (html) { return { select: function () { return []; } }; }
      }
    }
  };
})(this);
''';
}
