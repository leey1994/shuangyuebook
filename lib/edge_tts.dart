import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

/// Edge TTS（微软 Edge「大声朗读」在线语音）合成器。
///
/// 12 款中文在线音色（见 lib/tts_voices.dart）。协议与开源 edge-tts 7.x 一致：
/// wss 握手 + Sec-MS-GEC v2 令牌（CS64 + 定制 SHA256 双摘要），
/// 双消息帧（speech.config / ssml）→ 收二进制音频帧至 turn.end。
/// 支持 `mstts:express-as` 情感风格：叙述类音色默认带感情朗读。
/// 教学/研究用途；失败抛错，由调用方回退系统 TTS。
///
/// 纯 dart（dart:io + dart:math），不引 Flutter —— `dart run tool/edge_smoke.dart` 可独立自检。
class EdgeTts {
  EdgeTts._();

  static const String voiceHsiaoChen = 'zh-TW-HsiaoChenNeural'; // 小臻
  static const String voiceHsiaoYu = 'zh-TW-HsiaoYuNeural'; // 小瑜

  static const String _token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';
  /// 服务端要求的 Edge 版本串。前缀 2- = v2 令牌（与 edge-tts 7.x 同步）。
  static const String _gecVersion = '2-143.0.3650.75';
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

  /// 分句语调（rate%, pitch%）：端点不支持 `mstts:express-as` 风格标签
  /// （实测服务端以「SSML is invalid」断开），改用多段 prosody 起伏制造朗读感。
  static const (int, int) _toneDialogue = (6, 6); // 对话：稍快稍高，说话感
  static const (int, int) _toneExclaim = (4, 8); // 感叹：更快更亮
  static const (int, int) _toneQuestion = (0, 7); // 疑问：抬高
  static const (int, int) _toneEllipsis = (-10, -5); // 省略：放慢压低

  /// 合成一段文本 → MP3 字节（24kHz/48kbps 单声道）。
  ///
  /// [rate]/[pitch] 为 SSML prosody 字符串（如 `+0%`、`-10%`）。
  /// [expressive] 开启分句语调起伏（对话/感叹/疑问/省略号各带小偏差）。
  /// 超长文本按 ~4000 字节 UTF-8 安全分片，多段顺序拼接。
  /// 网络/协议失败抛 [EdgeTtsException]，调用方应回退系统 TTS。
  static Future<Uint8List> synth(
    String text, {
    String voice = voiceHsiaoChen,
    String rate = '+0%',
    String pitch = '+0%',
    bool expressive = true,
    Duration timeout = const Duration(seconds: 45),
  }) async {
    final clean = _cleanText(text);
    if (clean.trim().isEmpty) throw const EdgeTtsException('文本为空');
    final out = BytesBuilder(copy: false);
    for (final chunk in _splitUtf8(clean, 4000)) {
      final part = await _synthChunk(chunk, voice, rate, pitch, expressive)
          .timeout(timeout, onTimeout: () {
        throw const EdgeTtsException('合成超时');
      });
      out.add(part);
    }
    final bytes = out.takeBytes();
    if (bytes.length < 512) throw const EdgeTtsException('合成结果为空');
    return bytes;
  }

  /// Sec-MS-GEC v2 令牌：`<CS64 16 位十六进制>-<SHA256 64 位十六进制>`。
  ///
  /// 输入串 = Windows FILETIME（100ns since 1601，向下取整 5 分钟窗口）
  /// 十进制 + TrustedClientToken。摘要为微软自研变体（非标准 SHA256），
  /// 移植自 edge-tts `drm.py`（CS64 + 改造初始状态/轮常数的 SHA256）。
  /// float64 运算序列与原版一致：ticks 是 3e9 的倍数（512 对齐），无舍入歧义。
  static String secMsGec(DateTime utc, {double skew = 0}) {
    var t = utc.millisecondsSinceEpoch / 1000.0 + skew;
    t += 11644473600; // 1970 → 1601
    t -= t % 300; // 取整 5 分钟窗口
    t *= 1e7; // 秒 → 100ns tick（S_TO_NS / 100）
    final data = ascii.encode('${t.toStringAsFixed(0)}$_token');
    final digest = _sha256Digest(data);
    final cs64 = _cs64Digest(data, digest);
    String hexLe(int w) => [
          w & 0xff,
          (w >> 8) & 0xff,
          (w >> 16) & 0xff,
          (w >> 24) & 0xff,
        ].map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final cs = '${hexLe(cs64[0])}${hexLe(cs64[1])}'.toUpperCase();
    final sha = digest
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join()
        .toUpperCase();
    return '$cs-$sha';
  }

  // ---------- v2 令牌摘要（镜像 edge-tts drm.py；Dart int 天然按 64 位回绕，
  //            所有中间量只取低 32 位，与 Python 大整数结果一致） ----------

  static const int _u32 = 0xFFFFFFFF;

  static const List<int> _sha256Initial = [
    0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, //
    0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19,
  ];
  static const List<int> _sha256State = [
    0xFD9FBEA2, 0x91243CE7, 0xBE499094, 0xCD2E1E0A, //
    0x6C006F49, 0x04BD35AB, 0xFEB0A7E4, 0x03EFFBD2,
  ];
  static const List<int> _sha256Schedule = [
    0xEB24BF9E, 0x1558691F, 0xA0C09EE2, 0x0CFA32BA, //
    0xA622EE8C, 0xD1DD9491, 0xC0DD25A0, 0xF9E70AB6,
    0xF0C31573, 0x7058CE4E, 0x7188E606, 0x00E5AB33,
    0xD258B060, 0x72766564,
  ];
  static const List<int> _sha256RoundConstants = [
    0x428A2F98, 0x71374491, 0xB5C0FBCF, 0xE9B5DBA5, //
    0x3956C25B, 0x59F111F1, 0x923F82A4, 0xAB1C5ED5,
    0xD807AA98, 0x12835B01, 0x243185BE, 0x550C7DC3,
    0x72BE5D74, 0x80DEB1FE, 0x9BDC06A7, 0xC19BF174,
    0xE49B69C1, 0xEFBE4786, 0x0FC19DC6, 0x240CA1CC,
    0x2DE92C6F, 0x4A7484AA, 0x5CB0A9DC, 0x76F988DA,
    0x983E5152, 0xA831C66D, 0xB00327C8, 0xBF597FC7,
    0xC6E00BF3, 0xD5A79147, 0x06CA6351, 0x14292967,
    0x27B70A85, 0x2E1B2138, 0x4D2C6DFC, 0x53380D13,
    0x650A7354, 0x766A0ABB, 0x81C2C92E, 0x92722C85,
    0xA2BFE8A1, 0xA81A664B, 0xC24B8B70, 0xC76C51A3,
    0xD192E819, 0xD6990624, 0xF40E3585, 0x106AA070,
    0x19A4C116, 0x1E376C08, 0x2748774C, 0x34B0BCB5,
    0x391C0CB3, 0x4ED8AA4A, 0x5B9CCA4F, 0x682E6FF3,
    0x748F82EE, 0x78A5636F, 0x84C87814, 0x8CC70208,
    0x90BEFFFA, 0xA4506CEB, 0xBEF9A3F7, 0xC67178F2,
  ];
  static const int _sha256Adjustment = 0xC9DC06A7;
  static const int _sha256Sigma0Adjustment = 0x059C0B80;
  static const int _sha256Sigma1Adjustment = 0x000B92C0;

  /// 第 14 号轮常数被替换过的轮常数表。
  static final List<int> _sha256BlockConstants = [
    ..._sha256RoundConstants.take(14),
    _sha256Adjustment,
    ..._sha256RoundConstants.skip(15),
  ];

  /// CS64：系数表（值, 偏移）。
  static const List<(int, int)> _cs64Coefficients = [
    (0xE82E91B1, 0xB32700D0), (0x44DE24C6, 0x88DFF51D), //
    (0x3BEB65BC, 0x29514038), (0xC89C5933, 0xB328CBDF),
    (0x8D1EC211, 0xD405B4D5), (0x314EF5D5, 0x26E55F3C),
    (0xE92491B1, 0x607801C6), (0xF0A5B9D5, 0x82B2C1FB),
    (0x06064CF3, 0xFA51A3DA), (0xDA79FA60, 0x207CC464),
    (0xBED20560, 0x3C3C74F3), (0x89F9C9F8, 0xD2D14B61),
    (0x35FA38C6, 0xBB04A2C1), (0xCB49E3C6, 0xC5626167),
  ];
  static const int _cs64Factor = 0x82893933;
  static const int _cs64Adjustment0 = 0xF2F90B1A;
  static const int _cs64Adjustment1 = 0x0B1A0000;

  /// 32 位循环左移 16。
  static int _rol16(int value) =>
      (((value & _u32) << 16) | ((value & _u32) >> 16)) & _u32;

  /// 小端 32 位拆字；不足 4 字节补零；词数为奇数时补一个 0 词。
  static List<int> _wordsLe4Even(List<int> data) {
    final padded = [...data];
    while (padded.length % 4 != 0) {
      padded.add(0);
    }
    if (padded.isEmpty) return const [];
    final words = <int>[];
    for (var i = 0; i < padded.length; i += 4) {
      words.add(padded[i] |
          (padded[i + 1] << 8) |
          (padded[i + 2] << 16) |
          (padded[i + 3] << 24));
    }
    if (words.length.isOdd) words.add(0);
    return words;
  }

  static int _sigma0(int v) =>
      ((v >> 7) ^ (v << 25) ^ (v >> 18) ^ (v << 14) ^ (v >> 3)) & _u32;
  static int _sigma1(int v) =>
      ((v >> 17) ^ (v << 15) ^ (v >> 19) ^ (v << 13) ^ (v >> 10)) & _u32;

  static int _be(List<int> bytes) {
    var v = 0;
    for (final b in bytes) {
      v = (v << 8) | b;
    }
    return v;
  }

  /// SHA256 轮函数（[firstRound] = 14 时用替换常数的表）。
  /// `e * 0x100000001 >> s` 是 ROTR 的无分支写法；高位垃圾不影响低 32 位。
  static List<int> _sha256Rounds(
    List<int> state,
    List<int> words, [
    int firstRound = 0,
  ]) {
    var a = state[0], b = state[1], c = state[2], d = state[3];
    var e = state[4], f = state[5], g = state[6], h = state[7];
    final constants =
        firstRound == 14 ? _sha256BlockConstants : _sha256RoundConstants;
    for (var i = firstRound; i < 64; i++) {
      final rotE = e * 0x100000001;
      final rotA = a * 0x100000001;
      final t1 = h +
          ((rotE >> 6) ^ (rotE >> 11) ^ (rotE >> 25)) +
          (g ^ (e & (f ^ g))) +
          constants[i] +
          words[i];
      final t2 = ((rotA >> 2) ^ (rotA >> 13) ^ (rotA >> 22)) +
          ((a & b) | (c & (a | b)));
      h = g;
      g = f;
      f = e;
      e = (d + t1) & _u32;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _u32;
    }
    return [a, b, c, d, e, f, g, h];
  }

  static void _expandSchedule(List<int> words, [int firstWord = 16]) {
    for (var index = firstWord; index < 64; index++) {
      final x = words[index - 2], y = words[index - 15];
      final s1 = (x >> 17) ^ (x << 15) ^ (x >> 19) ^ (x << 13) ^ (x >> 10);
      final s0 = (y >> 7) ^ (y << 25) ^ (y >> 18) ^ (y << 14) ^ (y >> 3);
      words.add((s1 + words[index - 7] + s0 + words[index - 16]) & _u32);
    }
  }

  /// 前 7 字节折进初始状态的 SHA256 初值。
  static List<int> _sha256Init(List<int> data) {
    final words = List<int>.filled(14, 0, growable: true);
    words.add(_be(data.sublist(0, 3)));
    words.add(_be(data.sublist(3, 7)));
    for (var index = 16; index < 30; index++) {
      var value = _sha256Schedule[index - 16];
      if (index - 2 >= 14) {
        value += index == 16
            ? (_sigma1(words[index - 2]) ^ _sha256Sigma1Adjustment)
            : _sigma1(words[index - 2]);
      }
      if (index - 7 >= 14) value += words[index - 7];
      if (index - 15 >= 14) {
        value += index == 29
            ? (_sigma0(words[index - 15]) ^ _sha256Sigma0Adjustment)
            : _sigma0(words[index - 15]);
      }
      words.add(value & _u32);
    }
    words.add((_sigma1(words[28]) +
            words[23] +
            _sigma0(words[15]) +
            words[14] +
            _sha256Adjustment -
            _sha256RoundConstants[14]) &
        _u32);
    _expandSchedule(words, 31);
    final working = _sha256Rounds(_sha256State, words, 14);
    return [
      for (var i = 0; i < 8; i++) (_sha256Initial[i] + working[i]) & _u32,
    ];
  }

  /// 摘要（自研变体，非标准 SHA256），返回 32 字节。
  static List<int> _sha256Digest(List<int> data) {
    if (data.length < 7) throw const EdgeTtsException('令牌盐不足 7 字节');
    final length = 57 + data.length;
    final padded = <int>[...data.sublist(7), 0x80];
    padded.addAll(List<int>.filled((55 - length) % 64, 0));
    final bits = length * 8;
    for (var i = 7; i >= 0; i--) {
      padded.add((bits >> (i * 8)) & 0xff);
    }
    var state = _sha256Init(data.sublist(0, 7));
    for (var offset = 0; offset < padded.length; offset += 64) {
      final words = <int>[
        for (var j = 0; j < 16; j++)
          _be(padded.sublist(offset + j * 4, offset + j * 4 + 4)),
      ];
      _expandSchedule(words);
      final working = _sha256Rounds(state, words);
      state = [
        for (var i = 0; i < 8; i++) (state[i] + working[i]) & _u32,
      ];
    }
    final out = <int>[];
    for (final w in state) {
      out
        ..add((w >> 24) & 0xff)
        ..add((w >> 16) & 0xff)
        ..add((w >> 8) & 0xff)
        ..add(w & 0xff);
    }
    return out;
  }

  /// CS64 摘要：返回两个 32 位词。
  static List<int> _cs64Digest(List<int> data, List<int> digest) {
    var keyA =
        digest[0] | (digest[1] << 8) | (digest[2] << 16) | (digest[3] << 24);
    var keyB =
        digest[4] | (digest[5] << 8) | (digest[6] << 16) | (digest[7] << 24);
    keyA |= 1;
    keyB |= 1;
    final factors = [
      (keyA * _cs64Factor) & _u32,
      (keyB * _cs64Factor) & _u32,
    ];
    final terms = <int>[
      for (var i = 0; i < _cs64Coefficients.length; i++)
        (_cs64Coefficients[i].$1 * factors[i % 2]) & _u32,
    ];
    final offsets = <int>[for (final c in _cs64Coefficients) c.$2];
    final dataWords = _wordsLe4Even([0, ...data]);
    for (var index = 0; index < dataWords.length; index++) {
      final word = dataWords[index];
      var term = word * (index.isEven ? keyA : keyB);
      var offset = _rol16(word) * (index.isEven ? 0xEF0569FB : 0xC31713DB);
      if (index == 0) {
        term += _cs64Adjustment0 * factors[0];
        offset += _cs64Adjustment1;
      }
      terms.add(term & _u32);
      offsets.add(offset & _u32);
    }
    var swapAcc = 0, swapLast = 0, st = 0, acc = 0;
    for (var index = 0; index < terms.length; index += 2) {
      final x = terms[index], y = terms[index + 1];
      var t = _rol16((offsets[index] + x) & _u32);
      var q = (t * 0x76F50F34) & _u32;
      swapAcc += (_rol16(q) * 0xC3EFEA97 + q) & _u32;
      t = _rol16((offsets[index + 1] + y) & _u32);
      q = (t * 0x1881CE3C) & _u32;
      swapLast = (_rol16(q) * 0x35BD1EC9 + q) & _u32;
      swapAcc = (swapAcc + swapLast) & _u32;

      st = (st * keyA + x) & _u32;
      st = (_rol16(st) * 0xCF98B111) & _u32;
      st = (_rol16(st) * 0x87085B9F) & _u32;
      st = (_rol16(st) * 0x12CEB96D) & _u32;
      st = (_rol16(st) * 0x257E1D83) & _u32;
      acc += st;
      t = (st * keyB + y) & _u32;
      t = (_rol16(t) * 0xA27416F5) & _u32;
      t = (_rol16(t) * 0xD38396FF) & _u32;
      st = (_rol16((_rol16(t) * 0x7C932B89) & _u32) * 0xBFA49F69) & _u32;
      acc = (acc + st) & _u32;
    }
    return [swapLast ^ st, swapAcc ^ acc];
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
    bool expressive,
  ) async {
    try {
      return await _synthOnce(text, voice, rate, pitch, expressive);
    } catch (_) {
      // 语调起伏被拒（端点校验变动）时，退回单段平铺再试一次。
      if (expressive) {
        try {
          return await _synthOnce(text, voice, rate, pitch, false);
        } catch (_) {}
      }
      // 403 多为时钟偏差：校时后重试一次；彻底断网则同步失败，同样再试一次快速失败。
      try {
        await syncClockSkew();
      } catch (_) {}
      return _synthOnce(text, voice, rate, pitch, expressive);
    }
  }

  static Future<Uint8List> _synthOnce(
    String text,
    String voice,
    String rate,
    String pitch,
    bool expressive,
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
        '${mkSsml(text, voice: voice, rate: rate, pitch: pitch, expressive: expressive)}',
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
      final bytes = out.takeBytes();
      // 服务端静默拒绝（风格不支持等）时会给一个无音频的 turn.end —— 视作失败，
      // 让 [_synthChunk] 有机会剥掉风格 / 校时后重试。
      if (bytes.length < 512) throw const EdgeTtsException('合成结果为空');
      return bytes;
    } finally {
      if (ws != null) {
        try {
          await ws.close();
        } catch (_) {}
      }
    }
  }

  /// SSML 文档（与 edge-tts mkssml 同构：speak > voice > prosody*）。
  ///
  /// [expressive] 时按句识别情绪，拆成「叙述前缀 + 情绪段」两段 prosody
  /// （端点上限 2 段），制造朗读感；否则整段单 prosody 平铺。
  static String mkSsml(
    String text, {
    required String voice,
    String rate = '+0%',
    String pitch = '+0%',
    bool expressive = true,
  }) {
    final clean = _cleanText(text);
    final baseRate = _pct(rate), basePitch = _pct(pitch);
    final body = StringBuffer();
    for (final (seg, dr, dp)
        in expressive ? _toneSegments(clean) : [(clean, 0, 0)]) {
      body.write("<prosody pitch='${_fmtPct(basePitch + dp)}' "
          "rate='${_fmtPct(baseRate + dr)}' volume='+0%'>"
          '${_esc(seg)}</prosody>');
    }
    final parts = voice.split('-');
    final lang = parts.length >= 2 ? '${parts[0]}-${parts[1]}' : 'zh-CN';
    return "<speak version='1.0' "
        "xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='$lang'>"
        "<voice name='$voice'>"
        '$body'
        '</voice></speak>';
  }

  /// 分句 → 最多两段 prosody（端点硬限制：3 段即「SSML is invalid」）。
  ///
  /// 规则：叙述前缀平铺；从第一句「有情绪的话」（对话 / 感叹 / 疑问 / 省略号）
  /// 起，到段尾整体带上该句的语调 —— 一次抬升、后半段浸在情绪里，
  /// 不会像逐句跳音那样忽高忽低。整段无情绪句则单段平铺。
  static List<(String, int, int)> _toneSegments(String text) {
    final sentences = <(String, int, int)>[];
    final buf = StringBuffer();
    final rs = text.runes.toList();
    void flush() {
      final s = buf.toString();
      buf.clear();
      final visible =
          s.replaceAll(RegExp(r'''[\s。！？!?…、，,．.“”「」『』‘’"'：:；;（）()—\-~·]+'''), '');
      if (visible.isEmpty) {
        sentences.add((s, 0, 0)); // 纯标点/空白：不丢弃（保持文本完整），按平铺算
        return;
      }
      final t = s.trimRight();
      sentences.add(switch (t) {
        _ when t.endsWith('！') || t.endsWith('!') =>
          (s, _toneExclaim.$1, _toneExclaim.$2),
        _ when t.endsWith('？') || t.endsWith('?') =>
          (s, _toneQuestion.$1, _toneQuestion.$2),
        _ when t.endsWith('…') => (s, _toneEllipsis.$1, _toneEllipsis.$2),
        _ when t.contains('“') ||
                t.contains('”') ||
                t.contains('「') ||
                t.contains('」') =>
          (s, _toneDialogue.$1, _toneDialogue.$2),
        _ => (s, 0, 0),
      });
    }

    for (var i = 0; i < rs.length; i++) {
      final c = String.fromCharCode(rs[i]);
      buf.write(c);
      final ender = c == '\n' || '。！？!?'.contains(c);
      final last = i == rs.length - 1;
      final nextEnder = !last &&
          ('。！？!?…'.contains(String.fromCharCode(rs[i + 1])));
      if ((ender && !nextEnder) || last) flush();
    }

    var first = -1;
    for (var i = 0; i < sentences.length; i++) {
      final (_, r, p) = sentences[i];
      if (r != 0 || p != 0) {
        first = i;
        break;
      }
    }
    if (first < 0) return [(text, 0, 0)];
    final tone = sentences[first];
    if (first == 0) return [(text, tone.$2, tone.$3)];
    var offset = 0;
    for (var i = 0; i < first; i++) {
      offset += sentences[i].$1.length;
    }
    return [
      (text.substring(0, offset), 0, 0),
      (text.substring(offset), tone.$2, tone.$3),
    ];
  }

  /// 解析 `+12%` / `-8%` 形式的百分比；非法返回 0。
  static int _pct(String s) =>
      int.tryParse(s.replaceAll('%', '').replaceAll('+', '')) ?? 0;

  /// 格式化百分比并夹取到安全区间（音调 ±60，语速 -60~+150）。
  static String _fmtPct(int v) {
    final clamped = v.clamp(-60, 150);
    return '${clamped >= 0 ? '+' : ''}$clamped%';
  }

  static String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

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
