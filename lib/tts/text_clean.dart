// 朗读前文本清洗：只影响「读出来的内容」，不动原文偏移（高亮仍用原文）。
//
// 目标不是排版，而是别让广告/网址/零宽字符把语音念得莫名其妙：
//  - 零宽字符、BOM、软连字符 → 删；
//  - http(s)/www 链接 → 删（念出来是一串无意义字母）；
//  - 连续重复的逗号/顿号/分号 → 压成一个（省略号保留，它有停顿语义）；
//  - 连续空白 → 一个空格。
import 'dart:math' as math;

final RegExp _invisible = RegExp(r'[\u200b-\u200f\u2028-\u202f\u2060\ufeff\u00ad]');
final RegExp _url = RegExp(r'(https?://\S+|www\.\S+)', caseSensitive: false);
final RegExp _repeatSoft = RegExp(r'([，,、；;])\1+');
final RegExp _spaces = RegExp(r'\s+');

String cleanForSpeech(String input) {
  var t = input.replaceAll(_invisible, '');
  t = t.replaceAll(_url, '');
  t = t.replaceAllMapped(_repeatSoft, (m) => m[1]!);
  t = t.replaceAll(_spaces, ' ');
  // 清洗后可能只剩标点；调用方据此跳过朗读
  return t.trim();
}

/// 清洗后是否还有值得读的内容（汉字/字母/数字占比）。
bool hasSpeakableText(String input) {
  final t = cleanForSpeech(input);
  if (t.isEmpty) return false;
  var visible = 0;
  for (final r in t.runes) {
    final c = String.fromCharCode(r);
    if (RegExp(r'[\u4e00-\u9fffA-Za-z0-9]').hasMatch(c)) visible++;
  }
  return visible / math.max(1, t.runes.length) >= 0.1;
}
