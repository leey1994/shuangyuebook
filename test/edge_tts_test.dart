import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/edge_tts.dart';

// 基准值来自 edge-tts 7.3.1（Python）`generate_sec_ms_gec_v2`：
//   python -c "from edge_tts.drm import generate_sec_ms_gec_v2; \
//              print(generate_sec_ms_gec_v2(unix_timestamp=1750000000.0))"
void main() {
  test('Sec-MS-GEC v2 令牌与 edge-tts 输出逐字节一致', () {
    final vectors = <double, String>{
      1750000000.0:
          'B029A7426816F097-4579D112DC47FC3BF432B499C0A282F427C659474AF9BF5FA33CE2C003F9E9C2',
      1760000000.0:
          '6D50DDDB91812C33-DD68EFB01898B0750C9797D51A5FF93471DFDAE6888A1039D532CBDCCE54545D',
      1788888888.5:
          'A2B9A2A784D955CD-4BB7966AC4BE182B5A14812F755EBF7AEE9EF8A5E3F4B275914048729BF4B28B',
      1800000000.0:
          '99E54519B490BE5C-E162DB0977FBDCB9B86DD8148BF1BCDC3C0303176CE39852A42B415935C20654',
    };
    vectors.forEach((ts, expected) {
      final utc = DateTime.fromMillisecondsSinceEpoch((ts * 1000).round());
      expect(EdgeTts.secMsGec(utc), expected, reason: 'ts=$ts');
    });
  });

  test('SSML：最多两段 prosody（端点硬限制）、情绪句起整体带语调', () {
    const text = '他站在山顶。\n“真美啊！”她喊道。风停了……';
    final expressive = EdgeTts.mkSsml(text, voice: 'zh-CN-XiaoxiaoNeural');
    expect(expressive, contains("xml:lang='zh-CN'"));
    // 叙述前缀一段 + 情绪段一段，绝不超两段（三段会被服务端拒收）
    expect('<prosody'.allMatches(expressive).length, 2);
    expect(expressive, contains("pitch='+8%'")); // 感叹句语调
    expect(expressive, contains("rate='+4%'"));
    expect(expressive, contains("pitch='+0%'")); // 前缀平铺

    final plain = EdgeTts.mkSsml(
      text,
      voice: 'zh-TW-HsiaoChenNeural',
      expressive: false,
    );
    expect('<prosody'.allMatches(plain).length, 1);
    expect(plain, contains("xml:lang='zh-TW'"));
  });
}
