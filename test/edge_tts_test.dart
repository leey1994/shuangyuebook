import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/edge_tts.dart';

/// Edge TTS 纯函数属性测试（不联网）：
/// GEC 签名（64 位大写 hex、5 分钟窗口、float64≡整数序列）、SSML 转义、
/// UTF-8 安全分片、时间串格式。帧解析由 tool/edge_smoke.dart 网络实测把关。
void main() {
  const token = '6A5AA1D4EAFF4E9FB37E23D68491D6F4';

  group('Sec-MS-GEC', () {
    test('输出 64 位大写 hex', () {
      final g = EdgeTts.secMsGec(DateTime.utc(2026, 10, 7, 14, 45, 52));
      expect(g, matches(RegExp(r'^[0-9A-F]{64}$')));
    });

    test('5 分钟窗口：窗口内同值，跨窗口必变', () {
      final base = DateTime.utc(2026, 10, 7, 14, 45, 52);
      final secs = base.millisecondsSinceEpoch ~/ 1000 + 11644473600;
      final until = 300 - secs % 300; // 距下一边界的秒数
      final g0 = EdgeTts.secMsGec(base);
      // 落在窗口内第 295 秒（恒同窗）→ 同值
      expect(EdgeTts.secMsGec(base.add(Duration(seconds: until - 5))), g0);
      // 跨过边界 5 秒 → 必不同值
      expect(EdgeTts.secMsGec(base.add(Duration(seconds: until + 5))),
          isNot(g0));
    });

    test('skew 校时推进窗口', () {
      final base = DateTime.utc(2026, 10, 7, 14, 45, 52);
      final secs = base.millisecondsSinceEpoch ~/ 1000 + 11644473600;
      final until = 300 - secs % 300;
      final g0 = EdgeTts.secMsGec(base);
      expect(EdgeTts.secMsGec(base, skew: until - 1.0), g0);
      expect(EdgeTts.secMsGec(base, skew: until + 1.0), isNot(g0));
    });

    test('float64 运算序列与整数序列等价（ticks 恒 32 对齐）', () {
      for (final base in [
        DateTime.utc(1996, 1, 1),
        DateTime.utc(2026, 10, 7, 14, 45, 52),
        DateTime.utc(2099, 12, 31, 23, 59, 59),
      ]) {
        final secs = base.millisecondsSinceEpoch ~/ 1000 + 11644473600;
        final tInt = (secs - secs % 300) * 10000000; // 整数 ticks
        final want = sha256
            .convert(ascii.encode('$tInt$token'))
            .toString()
            .toUpperCase();
        expect(EdgeTts.secMsGec(base), want, reason: '$base');
      }
    });
  });

  group('SSML', () {
    test('转义 & < >，文本节点引号保留', () {
      final s = EdgeTts.mkSsml('A<B>&"C"', voice: 'v');
      expect(s, contains('A&lt;B&gt;&amp;"C"'));
      expect(s, isNot(contains('A<B>')));
    });

    test('剔除不兼容控制字符', () {
      expect(EdgeTts.cleanText('a\x00b\x08c\x1Fd'), 'a b c d');
    });

    test('结构：voice/prosody 包裹', () {
      final s = EdgeTts.mkSsml('你好', voice: 'zh-TW-HsiaoChenNeural');
      expect(s, contains("<voice name='zh-TW-HsiaoChenNeural'>"));
      expect(s, contains("<prosody pitch='+0%' rate='+0%' volume='+0%'>"));
      expect(s.trimRight(), endsWith('</speak>'));
    });
  });

  group('splitUtf8', () {
    test('不切断多字节字符、可逆、片长受控', () {
      const text = '中文测试😀汉字内容 content 混合😀';
      for (final n in [1, 3, 4, 5, 7, 13]) {
        final parts = EdgeTts.splitUtf8(text, n);
        expect(parts.join(), text, reason: 'maxBytes=$n');
        for (final p in parts) {
          // 每片可严格解码（无截断的多字节序列）
          expect(utf8.decode(utf8.encode(p)), p);
          // 片长 ≤ max(n, 4)：小 n 时整字符保留允许略超
          expect(utf8.encode(p).length, lessThanOrEqualTo(n.clamp(4, 1 << 30)),
              reason: 'maxBytes=$n piece=$p');
        }
      }
    });
  });

  group('jsDate', () {
    test('与 edge-tts date_to_string 同格式', () {
      expect(
        EdgeTts.jsDate(DateTime.utc(2026, 10, 7, 14, 45, 52)),
        'Wed Oct 07 2026 14:45:52 GMT+0000 (Coordinated Universal Time)',
      );
    });
  });
}
