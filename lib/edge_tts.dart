import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Edge TTS（微软 Edge「大声朗读」在线语音）合成器。
///
/// 用于台湾腔女声（小臻 `zh-TW-HsiaoChenNeural` / 小瑜 `zh-TW-HsiaoYuNeural`）。
/// 协议与开源 edge-tts 一致：wss 握手 + Sec-MS-GEC 签名，
/// 双消息帧（speech.config / ssml）→ 收二进制音频帧至 turn.end。
/// 教学/研究用途；失败抛错，由调用方回退系统 TTS。
///
/// 纯 dart（dart:io + crypto），不引 Flutter —— `dart run tool/edge_smoke.dart` 可独立自检。
class EdgeTts {
  EdgeTts._();

  static const String voiceHsiaoChen = 'zh-TW-HsiaoChenNeural'; // 小臻
  static const String voiceHsiaoYu = 'zh-TW-HsiaoYuNeural'; // 小瑜

  static const String _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  static const String _gecVersion = '1-143.0.3650.75';
  static const String _ua =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0';
  static const String _origin =
      'chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold';
  static const String _wssBase =
      'wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1'
      '?TrustedClientToken=$_token';

  /// 本机与服务器时钟偏差（秒）。握手 403 时按服务器 Date 校正后重试一次。
  static double skewSeconds = 0;

  static const Duration _connectTimeout = Duration(seconds: 12);
  static const Duration _idleTimeout = Duration(seconds: 25);

  /// WS 专用 HttpClient：`userAgent = null` 抑制 dart 默认
  /// `Dart/x (dart:io)` UA（服务端只认 Edge/Chrome UA，否则 403）。
  static HttpClient? _wsClient;
  static HttpClient _edgeWsClient() =>
      _wsClient ??= HttpClient()..userAgent = null;

  /// 合成一段文本 → MP3 字节（24kHz/48kbps 单声道）。
  ///
  /// [rate]/[pitch] 为 SSML prosody 字符串（如 `+0%`、`-10%`）。
  /// 超长文本按 ~4000 字节 UTF-8 安全分片，多段顺序拼接。
  /// 网络/协议失败抛 [EdgeTtsException]，调用方应回退系统 TTS。
  static Future<Uint8List> synth(
    String text, {
    String voice = voiceHsiaoChen,
    String rate = '+0%',
    String pitch = '+0%',
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final clean = _cleanText(text);
    if (clean.trim().isEmpty) throw const EdgeTtsException('文本为空');
    final out = BytesBuilder(copy: false);
    for (final chunk in _splitUtf8(clean, 4000)) {
      final part = await _synthChunk(chunk, voice, rate, pitch)
          .timeout(timeout, onTimeout: () {
        throw const EdgeTtsException('合成超时');
      });
      out.add(part);
    }
    final bytes = out.takeBytes();
    if (bytes.length < 512) throw const EdgeTtsException('合成结果为空');
    return bytes;
  }

  /// Sec-MS-GEC 签名：Windows FILETIME（100ns since 1601）向下取整 5 分钟，
  /// 与 TrustedClientToken 拼接后 SHA256 大写十六进制。
  /// 与原版 float64 运算序列一致：ticks 最终为 3e9 的倍数（512 对齐），无舍入歧义。
  static String secMsGec(DateTime utc, {double skew = 0}) {
    var t = utc.millisecondsSinceEpoch / 1000.0 + skew;
    t += 11644473600; // 1970 → 1601
    t -= t % 300; // 取整 5 分钟窗口
    t *= 1e7; // 秒 → 100ns tick（S_TO_NS / 100）
    final s = '${t.toStringAsFixed(0)}$_token';
    return sha256.convert(ascii.encode(s)).toString().toUpperCase();
  }

  /// 与 edge-tts date_to_string 一致的时间串（UTC，英语星期/月份缩写）。
  static String jsDate(DateTime utc) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    String p2(int n) => n.toString().padLeft(2, '0');
    final d = utc;
    return '${wd[d.weekday - 1]} ${mo[d.month - 1]} ${p2(d.day)} ${d.year} '
        '${p2(d.hour)}:${p2(d.minute)}:${p2(d.second)} '
        'GMT+0000 (Coordinated Universal Time)';
  }

  /// XML 文本转义 + 剔除不兼容控制字符（与 edge-tts remove_incompatible_characters 等价）。
  static String cleanText(String text) => _cleanText(text);

  /// UTF-8 字节安全分片（不切断多字节字符）。
  static List<String> splitUtf8(String text, int maxBytes) =>
      _splitUtf8(text, maxBytes);

  /// 解析服务端二进制帧，取出 audio/mpeg 负载。
  /// 与 edge-tts `get_headers_and_data` 同构：头区 = [0, hl)（含 2 字节长度前缀），
  /// 体 = [hl+2, end)。流终止帧（无 Content-Type 且无数据）返回 null 跳过。
  static Uint8List? parseAudioFrame(List<int> msg) {
    if (msg.length < 2) throw const EdgeTtsException('二进制帧过短');
    final hl = (msg[0] << 8) | msg[1];
    if (hl > msg.length) throw const EdgeTtsException('二进制帧头长度非法');
    // 首行含二进制长度前缀但仍有冒号，后续行干净。
    final headerStr = String.fromCharCodes(msg.sublist(0, hl));
    String? path;
    String? contentType;
    for (final line in headerStr.split('\r\n')) {
      final i = line.indexOf(':');
      if (i <= 0) continue;
      final k = line.substring(0, i);
      final v = line.substring(i + 1).trim();
      if (k.endsWith('Path')) path = v;
      if (k.endsWith('Content-Type')) contentType = v;
    }
    if (path != 'audio') {
      throw EdgeTtsException('未知音频帧 Path=$path');
    }
    final raw =
        hl + 2 <= msg.length ? msg.sublist(hl + 2) : const <int>[];
    if (contentType == null) {
      // 服务端流终止帧：无 Content-Type 且无数据 → 跳过。
      if (raw.isEmpty) return null;
      throw const EdgeTtsException('无 Content-Type 却带数据');
    }
    if (contentType != 'audio/mpeg') {
      throw EdgeTtsException('非预期 Content-Type=$contentType');
    }
    if (raw.isEmpty) throw const EdgeTtsException('音频帧为空');
    // MP3 帧头恒为 0xFF，前导 0x0D/0x0A 只可能是帧间填充，剥掉。
    var start = 0;
    while (start < raw.length &&
        (raw[start] == 0x0D || raw[start] == 0x0A)) {
      start++;
    }
    final audio = raw.sublist(start);
    if (audio.isEmpty) throw const EdgeTtsException('音频帧为空');
    return Uint8List.fromList(audio);
  }

  // ---------- 内部 ----------

  static Future<Uint8List> _synthChunk(
    String text,
    String voice,
    String rate,
    String pitch,
  ) async {
    try {
      return await _synthOnce(text, voice, rate, pitch);
    } catch (_) {
      // 403 多为时钟偏差：校时后重试一次；彻底断网则同步失败，同样再试一次快速失败。
      try {
        await syncClockSkew();
      } catch (_) {}
      return _synthOnce(text, voice, rate, pitch);
    }
  }

  static Future<Uint8List> _synthOnce(
    String text,
    String voice,
    String rate,
    String pitch,
  ) async {
    final gec = secMsGec(DateTime.now().toUtc(), skew: skewSeconds);
    final connId = _randHex(16);
    final uri = Uri.parse(
        '$_wssBase&ConnectionId=$connId&Sec-MS-GEC=$gec'
        '&Sec-MS-GEC-Version=$_gecVersion');
    WebSocket? ws;
    try {
      ws = await WebSocket.connect(
        uri.toString(),
        headers: {
          'User-Agent': _ua,
          'Origin': _origin,
          'Pragma': 'no-cache',
          'Cache-Control': 'no-cache',
          'Accept-Language': 'en-US,en;q=0.9',
          'Cookie': 'muid=${_randHex(16).toUpperCase()};',
        },
        customClient: _edgeWsClient(),
        compression: CompressionOptions.compressionOff,
      ).timeout(_connectTimeout, onTimeout: () {
        throw const EdgeTtsException('握手超时');
      });
      final ts = jsDate(DateTime.now().toUtc());
      final requestId = _randHex(16);
      ws.add(
        'X-Timestamp:$ts\r\n'
        'Content-Type:application/json; charset=utf-8\r\n'
        'Path:speech.config\r\n\r\n'
        '{"context":{"synthesis":{"audio":{"metadataoptions":'
        '{"sentenceBoundaryEnabled":"true","wordBoundaryEnabled":"false"},'
        '"outputFormat":"audio-24khz-48kbitrate-mono-mp3"}}}}\r\n',
      );
      ws.add(
        'X-RequestId:$requestId\r\n'
        'Content-Type:application/ssml+xml\r\n'
        'X-Timestamp:${ts}Z\r\n' // 末尾 Z 是微软既有 bug，照抄
        'Path:ssml\r\n\r\n'
        '${mkSsml(text, voice: voice, rate: rate, pitch: pitch)}',
      );
      final out = BytesBuilder(copy: false);
      await for (final msg in ws.timeout(_idleTimeout)) {
        if (msg is String) {
          final p = _textPath(msg);
          if (p == 'turn.end') break;
          // response / turn.start / audio.metadata → 忽略
        } else if (msg is List<int>) {
          final audio = parseAudioFrame(msg);
          if (audio != null) out.add(audio);
        }
      }
      return out.takeBytes();
    } finally {
      if (ws != null) {
        try {
          await ws.close();
        } catch (_) {}
      }
    }
  }

  /// SSML 文档（与 edge-tts mkssml 同构）。
  static String mkSsml(
    String text, {
    required String voice,
    String rate = '+0%',
    String pitch = '+0%',
  }) {
    final esc = _cleanText(text)
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;');
    return "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
        "<voice name='$voice'>"
        "<prosody pitch='$pitch' rate='$rate' volume='+0%'>"
        '$esc'
        '</prosody></voice></speak>';
  }

  /// 取文本帧头部的 Path 值。
  static String? _textPath(String msg) {
    final i = msg.indexOf('\r\n\r\n');
    final head = i < 0 ? msg : msg.substring(0, i);
    for (final line in head.split('\r\n')) {
      final j = line.indexOf(':');
      if (j <= 0) continue;
      if (line.substring(0, j) == 'Path') return line.substring(j + 1).trim();
    }
    return null;
  }

  /// 校时：读 voices/list 响应的 Date 头，记录服务器-本机偏差。
  static Future<void> syncClockSkew() async {
    final c = HttpClient()..connectionTimeout = const Duration(seconds: 8);
    try {
      final req = await c
          .getUrl(Uri.parse(
              'https://speech.platform.bing.com/consumer/speech/'
              'synthesize/readaloud/voices/list?trustedclienttoken=$_token'))
          .timeout(const Duration(seconds: 8));
      final resp = await req.close().timeout(const Duration(seconds: 8));
      try {
        await resp.drain<void>();
      } catch (_) {}
      final d = resp.headers.value(HttpHeaders.dateHeader);
      if (d != null) {
        final server = HttpDate.parse(d); // FormatException 由调用方兜
        skewSeconds = server.difference(DateTime.now()).inMilliseconds / 1000.0;
      }
    } finally {
      c.close(force: true);
    }
  }

  static String _cleanText(String text) {
    final b = StringBuffer();
    for (final r in text.runes) {
      if (r <= 8 || (r >= 11 && r <= 12) || (r >= 14 && r <= 31)) {
        b.write(' ');
      } else {
        b.writeCharCode(r);
      }
    }
    return b.toString();
  }

  static List<String> _splitUtf8(String text, int maxBytes) {
    final bytes = utf8.encode(text);
    if (bytes.length <= maxBytes) return [text];
    final chunks = <String>[];
    var start = 0;
    while (start < bytes.length) {
      var end = start + maxBytes;
      if (end >= bytes.length) {
        end = bytes.length;
      } else {
        // 回退到 UTF-8 字符边界（continuation byte 10xxxxxx）。
        while (end > start && (bytes[end] & 0xC0) == 0x80) {
          end--;
        }
        if (end == start) {
          // maxBytes < 首字符长度：整字符保留（宁超不切）
          end = start + 1;
          while (end < bytes.length && (bytes[end] & 0xC0) == 0x80) {
            end++;
          }
        }
      }
      chunks.add(utf8.decode(bytes.sublist(start, end)));
      start = end;
    }
    return chunks;
  }

  static String _randHex(int bytes) {
    final r = Random.secure();
    final b = List<int>.generate(bytes, (_) => r.nextInt(256));
    final hex = StringBuffer();
    for (final x in b) {
      hex.write(x.toRadixString(16).padLeft(2, '0'));
    }
    return hex.toString();
  }
}

/// Edge TTS 合成失败（网络/协议/超时），调用方回退系统 TTS。
class EdgeTtsException implements Exception {
  const EdgeTtsException(this.message);
  final String message;
  @override
  String toString() => 'EdgeTtsException: $message';
}
