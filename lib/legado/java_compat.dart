// Legado（原版阅读）JS 运行时兼容层：`Packages.*` 背后的原生实现。
//
// 原版书源的脚本直接调用真实 Java 类（`Packages.java.util.Base64`、
// `javax.crypto.Cipher`、`java.util.zip.Inflater`、`android.util.Base64`、
// `cn.hutool.*`…）。爽阅的 JS 引擎是 QuickJS，没有 Java 虚拟机，因此这里把
// 这些类的**语义**逐一实现，重活（摘要/HMAC/AES/GZIP/GBK）下沉到 Dart 原生库，
// 轻活（字节数组、BigInteger、字节流、ByteBuffer）在 JS 侧用纯脚本实现。
//
// 桥协议：JS 侧 `__lgcall('jcompat', {op:…})` → [dispatch] → `{'v': …}`。
// 所有二进制一律 base64 传，避免 JSON 数字/编码损耗。
import 'dart:convert';
import 'dart:io' show ZLibDecoder, ZLibEncoder, gzip, zlib;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:fast_gbk/fast_gbk.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html_parser;
import 'package:pointycastle/export.dart' as pc;

/// `Packages.*` 桥：Dart 侧实现。
class JavaCompat {
  JavaCompat._();

  /// 处理一次桥调用；参数与返回值均为 JSON 友好结构。
  static Map<String, dynamic> dispatch(Map<String, dynamic> p) {
    final op = '${p['op'] ?? ''}';
    try {
      switch (op) {
        case 'digest':
          return {'v': _b64e(_digest('${p['alg'] ?? 'MD5'}', _b64d('${p['data'] ?? ''}')))};
        case 'hmac':
          return {
            'v': _b64e(_hmac('${p['alg'] ?? 'HmacMD5'}',
                _b64d('${p['key'] ?? ''}'), _b64d('${p['data'] ?? ''}')))
          };
        case 'cipher':
          return {'v': _b64e(_cipher(p))};
        case 'inflate':
          return {
            'v': _b64e(_inflate(_b64d('${p['data'] ?? ''}'), p['nowrap'] == true))
          };
        case 'deflate':
          return {
            'v': _b64e(_deflate(_b64d('${p['data'] ?? ''}'), p['nowrap'] == true))
          };
        case 'gunzip':
          return {'v': _b64e(gzip.decode(_b64d('${p['data'] ?? ''}')))};
        case 'gzip':
          return {'v': _b64e(gzip.encode(_b64d('${p['data'] ?? ''}')))};
        case 'toBytes':
          return {'v': _b64e(_encodeText('${p['text'] ?? ''}', '${p['cs'] ?? 'UTF-8'}'))};
        case 'fromBytes':
          return {
            'v': _decodeText(_b64d('${p['data'] ?? ''}'), '${p['cs'] ?? 'UTF-8'}')
          };
        case 'random':
          return {'v': _b64e(_randomBytes((p['n'] as num?)?.toInt() ?? 16))};
        case 'selector':
          return {'v': _select(p)};
        case 'text':
          return {'v': _decodeText(_b64d('${p['data'] ?? ''}'), '${p['cs'] ?? 'UTF-8'}')};
        default:
          return {'e': '不支持的 Packages 操作：$op'};
      }
    } catch (e) {
      return {'e': '$e'.replaceFirst('Exception: ', '')};
    }
  }

  // ------------------------------------------------------------------
  // 编码
  // ------------------------------------------------------------------

  static Uint8List _b64d(String s) {
    if (s.isEmpty) return Uint8List(0);
    var t = s.replaceAll(RegExp(r'[\s\r\n]'), '');
    if (t.contains('-') || t.contains('_')) {
      t = t.replaceAll('-', '+').replaceAll('_', '/');
    }
    while (t.length % 4 != 0) {
      t += '=';
    }
    try {
      return base64.decode(t);
    } catch (_) {
      return Uint8List(0);
    }
  }

  static String _b64e(List<int> b) => base64.encode(b);

  static List<int> _encodeText(String s, String cs) {
    final c = cs.toUpperCase().replaceAll('_', '-');
    if (c.startsWith('GBK') || c.startsWith('GB2312') || c.startsWith('GB18030')) {
      return gbk.encode(s);
    }
    return utf8.encode(s);
  }

  static String _decodeText(List<int> bytes, String cs) {
    final c = cs.toUpperCase().replaceAll('_', '-');
    if (c.startsWith('GBK') || c.startsWith('GB2312') || c.startsWith('GB18030')) {
      try {
        return gbk.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
    if (c.startsWith('ISO-8859-1') || c.startsWith('LATIN')) {
      return latin1.decode(bytes);
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  static List<int> _randomBytes(int n) {
    final r = Random.secure();
    return List<int>.generate(n, (_) => r.nextInt(256));
  }

  // ------------------------------------------------------------------
  // 摘要 / HMAC
  // ------------------------------------------------------------------

  static crypto.Hash _hashOf(String alg) {
    final a = alg.toUpperCase().replaceAll('-', '').replaceAll('_', '');
    if (a == 'MD5') return crypto.md5;
    if (a == 'SHA1') return crypto.sha1;
    if (a == 'SHA256') return crypto.sha256;
    if (a == 'SHA512') return crypto.sha512;
    if (a == 'SHA224') return crypto.sha224;
    if (a == 'SHA384') return crypto.sha384;
    if (a == 'SHA3256') return crypto.sha256;
    throw StateError('不支持的摘要算法：$alg');
  }

  static List<int> _digest(String alg, List<int> data) =>
      _hashOf(alg).convert(data).bytes;

  static List<int> _hmac(String alg, List<int> key, List<int> data) {
    final a = alg.toUpperCase().startsWith('HMAC')
        ? alg.substring(4)
        : alg;
    return crypto.Hmac(_hashOf(a), key).convert(data).bytes;
  }

  // ------------------------------------------------------------------
  // Cipher（AES / DES / 3DES）
  // ------------------------------------------------------------------

  static List<int> _cipher(Map<String, dynamic> p) {
    final trans = '${p['trans'] ?? 'AES/CBC/PKCS5Padding'}'.toUpperCase();
    final encrypt = p['enc'] != false;
    final key = _b64d('${p['key'] ?? ''}');
    final iv = p['iv'] == null ? null : _b64d('${p['iv']}');
    final aad = p['aad'] == null ? null : _b64d('${p['aad']}');
    var data = _b64d('${p['data'] ?? ''}');
    final parts = trans.split('/');
    var alg = parts[0];
    if (alg == 'AES_128' || alg == 'AES_256') alg = 'AES';
    final mode = parts.length > 1 ? parts[1] : 'ECB';
    final pad = parts.length > 2 ? parts[2] : 'NOPADDING';
    if (alg == 'AES') {
      return _aes(mode, pad, key, iv, aad, data, encrypt);
    }
    if (alg == 'DES' || alg == 'DESEDE' || alg == 'TRIPLEDES') {
      // DES 走 JS 侧既有实现，这里不重复；显式报错便于定位
      throw StateError('DES 由 JS 实现处理，请勿走 Packages 桥');
    }
    throw StateError('不支持的加密算法：$trans');
  }

  static List<int> _aes(String mode, String pad, List<int> keyIn, List<int>? iv,
      List<int>? aad, List<int> data, bool encrypt) {
    // Java 侧密钥不足长度会抛 InvalidKeyException；书源普遍用 16/24/32，
    // 少量用短 key + 补零，这里按补零对齐（更宽容，不会更差）。
    var key = keyIn;
    if (key.length != 16 && key.length != 24 && key.length != 32) {
      final target = key.length <= 16
          ? 16
          : key.length <= 24
              ? 24
              : 32;
      key = List<int>.from(key)..addAll(List<int>.filled(target - key.length, 0));
    }
    final kp = pc.KeyParameter(Uint8List.fromList(key));
    final ivBytes = iv ?? const <int>[];
    final wantsPad = pad.contains('PKCS5') || pad.contains('PKCS7');

    if (mode == 'GCM') {
      final gcm = pc.GCMBlockCipher(pc.AESEngine());
      gcm.init(
        encrypt,
        pc.AEADParameters(kp, 128, Uint8List.fromList(ivBytes),
            Uint8List.fromList(aad ?? const [])),
      );
      return gcm.process(Uint8List.fromList(data));
    }
    if (mode == 'CTR' || mode == 'CFB' || mode == 'OFB') {
      // 三者对「整段数据」语义一致（无填充、无块对齐要求）
      final c = pc.CTRStreamCipher(pc.AESEngine());
      c.init(encrypt, pc.ParametersWithIV(kp, Uint8List.fromList(ivBytes)));
      return c.process(Uint8List.fromList(data));
    }
    if (mode != 'CBC' && mode != 'ECB') {
      throw StateError('不支持的 AES 模式：$mode');
    }
    final params = pc.ParametersWithIV(
        kp, Uint8List.fromList(mode == 'CBC' ? ivBytes : const []));
    final cipher = mode == 'CBC'
        ? pc.CBCBlockCipher(pc.AESEngine())
        : pc.ECBBlockCipher(pc.AESEngine());
    cipher.init(encrypt, params);
    var input = Uint8List.fromList(data);
    if (wantsPad && encrypt) {
      final n = 16 - input.length % 16;
      final padded = Uint8List(input.length + n)..setAll(0, input);
      padded.fillRange(input.length, padded.length, n);
      return cipher.process(padded);
    }
    if (wantsPad) {
      final out = cipher.process(input);
      if (out.isEmpty) return out;
      final n = out[out.length - 1];
      if (n <= 0 || n > 16 || n > out.length) return out; // 非法填充：原样返回
      return out.sublist(0, out.length - n);
    }
    if (input.length % 16 != 0) {
      final n = 16 - input.length % 16;
      input = Uint8List(input.length + n)..setAll(0, input);
    }
    return cipher.process(input);
  }

  // ------------------------------------------------------------------
  // 压缩
  // ------------------------------------------------------------------

  static List<int> _inflate(List<int> data, bool nowrap) {
    final bytes = Uint8List.fromList(data);
    return nowrap ? ZLibDecoder(raw: true).convert(bytes) : zlib.decode(bytes);
  }

  static List<int> _deflate(List<int> data, bool nowrap) {
    final bytes = Uint8List.fromList(data);
    return nowrap ? ZLibEncoder(raw: true).convert(bytes) : zlib.encode(bytes);
  }

  // ------------------------------------------------------------------
  // org.jsoup 选择器（宿主侧解析 HTML，JS 侧只拿结果）
  // ------------------------------------------------------------------

  static dynamic _select(Map<String, dynamic> p) {
    final htmlText = '${p['html'] ?? ''}';
    final css = '${p['css'] ?? ''}';
    final limit = (p['limit'] as num?)?.toInt() ?? 200;
    final mode = '${p['mode'] ?? 'elements'}';
    final doc = _parseFragment(htmlText);
    if (mode == 'text') {
      return _cleanText(doc.documentElement?.text ?? '');
    }
    if (mode == 'document') {
      return [
        {
          'html': htmlText,
          'text': _cleanText(doc.documentElement?.text ?? ''),
          'attrs': <String, String>{},
        }
      ];
    }
    Iterable<dom.Element> nodes;
    try {
      nodes = doc.querySelectorAll(css);
    } catch (_) {
      return [];
    }
    final out = <Map<String, dynamic>>[];
    for (final el in nodes.take(limit)) {
      out.add({
        'html': el.outerHtml,
        'text': _cleanText(el.text),
        'attrs': Map<String, String>.fromEntries(
            el.attributes.entries.map((e) => MapEntry('${e.key}', '${e.value}'))),
      });
    }
    return out;
  }

  /// HTML5 片段解析：表格类标签（`<tr>`/`<td>`…）直接交给解析器会被丢弃
  /// （"in body" 插入模式），`result.select('td')` 便 0 命中。撑一个 `<table>`
  /// 外壳再解析，选到的元素 outerHtml 仍是原片段。
  static dom.Document _parseFragment(String htmlText) {
    final t = htmlText.trimLeft().toLowerCase();
    const tableTags = <String>[
      '<tr', '<td', '<th', '<tbody', '<thead', '<tfoot', '<caption', '<col',
    ];
    for (final tag in tableTags) {
      if (t.startsWith(tag)) {
        return html_parser.parse('<table>$htmlText</table>');
      }
    }
    return html_parser.parse(htmlText);
  }

  /// 与 jsoup `Element.text()` 对齐：块级标签补空格、压缩空白。
  static String _cleanText(String s) =>
      s.replaceAll(RegExp(r'\s+'), ' ').trim();
}
