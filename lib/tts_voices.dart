// 在线音色表（Edge TTS）：prefs 值 → (显示名, 合成音色 id)。
// 阅读器听书面板、听书页与「我的 → 听书设置」共用这一张表。
const Map<String, (String, String)> kEdgeVoices = {
  '__edge_hsiaochen__': ('小臻（在线）', 'zh-TW-HsiaoChenNeural'),
  '__edge_hsiaoyu__': ('小瑜（在线）', 'zh-TW-HsiaoYuNeural'),
  '__edge_xiaoxiao__': ('晓晓·甜美女声（在线）', 'zh-CN-XiaoxiaoNeural'),
  '__edge_yunxi__': ('云希·阳光青年（在线）', 'zh-CN-YunxiNeural'),
  '__edge_yunjian__': ('云健·解说男声（在线）', 'zh-CN-YunjianNeural'),
  '__edge_yunxia__': ('云夏·清亮少年（在线）', 'zh-CN-YunxiaNeural'),
  '__edge_xiaoyi__': ('晓伊·活力女声（在线）', 'zh-CN-XiaoyiNeural'),
  '__edge_yunyang__': ('云扬·新闻播报（在线）', 'zh-CN-YunyangNeural'),
  '__edge_xiaobei__': ('晓北·东北味（在线）', 'zh-CN-liaoning-XiaobeiNeural'),
  '__edge_xiaoni__': ('晓妮·陕西味（在线）', 'zh-CN-shaanxi-XiaoniNeural'),
  '__edge_hiumaan__': ('晓曼·粤语女声（在线）', 'zh-HK-HiuMaanNeural'),
  '__edge_yunjhe__': ('云哲·台湾男声（在线）', 'zh-TW-YunJheNeural'),
};

/// 默认在线音色（prefs 里存的是 [kEdgeVoices] 的 key）。
const String kVoiceDefaultKey = '__edge_hsiaochen__';

/// prefs 音色值 → 显示名（'' = 系统语音）。
String ttsVoiceLabel(String prefsValue) {
  if (prefsValue.isEmpty) return '系统语音';
  final v = kEdgeVoices[prefsValue];
  if (v == null) return '系统语音';
  return v.$1.replaceAll('（在线）', '');
}

/// prefs 语速（0.1~1.0，0.5 = 常速）→ 倍率文本（如 1.2x）。
String ttsRateLabel(double rate) => '${(rate / 0.5).toStringAsFixed(1)}x';
