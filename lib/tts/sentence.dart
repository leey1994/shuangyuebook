// 朗读断句：把一段正文切成「句」。
//
// 为什么按句而不是按段：暂停粒度、上一句/下一句、句级高亮、预取窗口全都依赖
// 这个单位。段落级永远做不出「按下暂停 150ms 内静音」。
//
// 约定：
//  - `start` / `end` 是段内 **UTF-16 code unit** 偏移，可直接
//    `para.substring(s.start, s.end)` 取到原文（高亮按这个范围着色）；
//  - 句末标点与紧随的闭合引号归本句（`他说：“走吧。”` 是一句）；
//  - 超长句（> [maxLen]）在逗号/顿号/空格处二次切分，offsets 仍然连续；
//  - 纯空白不产出句子，但不会让后续偏移错位。
import 'dart:math' as math;

class Sentence {
  const Sentence({
    required this.para,
    required this.index,
    required this.start,
    required this.end,
    required this.text,
  });

  /// 段索引（跨章队列里由上层维护）。
  final int para;

  /// 段内序号（0 起）。
  final int index;

  /// 段内起止（code unit 偏移，end 不含）。
  final int start;
  final int end;

  /// 裁剪后的正文（去首尾空白，标点保留）。
  final String text;

  @override
  String toString() => 'S(para=$para, idx=$index, $start..$end, "$text")';
}

const Set<String> _enders = {
  '。', '！', '？', '!', '?', '\n', // 换行也断句（本地 TXT 常见）
};
const Set<String> _closers = {
  '”', '』', '」', '’', '）', ')', '》', '】', '…', '.', '~',
};
const Set<String> _softBreaks = {'，', '、', '；', ';', ',', ' ', '\t', '：', ':'};

/// 切一段。`maxLen` 是二次切分的阈值（按 rune 数，非字节）。
List<Sentence> splitSentences(
  String para, {
  int paraIndex = 0,
  int maxLen = 120,
}) {
  if (para.trim().isEmpty) return const [];
  final chars = <String>[];
  final offsets = <int>[]; // chars[k] 在 para 里的起始 code unit 偏移
  var off = 0;
  for (final r in para.runes) {
    chars.add(String.fromCharCode(r));
    offsets.add(off);
    off += chars.last.length;
  }
  offsets.add(off); // 哨兵

  final out = <Sentence>[];
  void emit(int a, int b) {
    var s = offsets[a];
    var e = offsets[b];
    while (s < e && _isSpace(para.substring(s, s + 1))) {
      s++;
    }
    while (e > s && _isSpace(para.substring(e - 1, e))) {
      e--;
    }
    if (e > s) {
      out.add(Sentence(
        para: paraIndex,
        index: out.length,
        start: s,
        end: e,
        text: para.substring(s, e),
      ));
    }
  }

  var i = 0;
  while (i < chars.length) {
    while (i < chars.length && _isSpace(chars[i])) {
      i++;
    }
    if (i >= chars.length) break;
    // 先找句末标点（含连续标点与闭合引号）
    var j = i;
    while (j < chars.length) {
      final c = chars[j];
      j++;
      if (_enders.contains(c)) {
        while (j < chars.length &&
            (_enders.contains(chars[j]) || _closers.contains(chars[j]))) {
          j++;
        }
        break;
      }
    }
    // 超长句：跨度超过 maxLen 时在软停顿处二次切分，标点归前句
    var from = i;
    while (offsets[j] - offsets[from] > maxLen) {
      var cut = -1;
      for (var k = from + 1; k < j; k++) {
        if (offsets[k] - offsets[from] > maxLen) break;
        if (_softBreaks.contains(chars[k])) cut = k + 1;
      }
      if (cut <= from) {
        // 一个软停顿都没有：硬切，别让一句话横跨几屏
        cut = from + 1;
        while (cut < j && offsets[cut] - offsets[from] < maxLen) {
          cut++;
        }
      }
      emit(from, cut);
      from = cut;
    }
    emit(from, j);
    i = j;
  }
  return out;
}

/// 整章切句：返回「段 → 句」的扁平列表，保留段索引。
List<Sentence> splitChapter(List<String> paras, {int maxLen = 120}) {
  final out = <Sentence>[];
  for (var p = 0; p < paras.length; p++) {
    out.addAll(splitSentences(paras[p], paraIndex: p, maxLen: maxLen));
  }
  return out;
}

/// 句子偏移 → 渲染文本（可能加了首行缩进）里的区间；越界时返回 null。
///
/// [rendered] 是段落经过缩进/排版后的字符串，[para] 是断句时的原文。
({int start, int end})? spanInRendered(
  String rendered,
  String para,
  Sentence s,
) {
  if (rendered.length < para.length) return null;
  final pad = rendered.length - para.length;
  final a = (s.start + pad).clamp(0, rendered.length);
  final b = (s.end + pad).clamp(a, rendered.length);
  return b > a ? (start: a, end: b) : null;
}

bool _isSpace(String c) =>
    c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\u00A0';

/// 句子里「有几成是汉字/字母/数字」——用于跳过纯符号句（`……`、`***`）。
double visibleRatio(String s) {
  if (s.isEmpty) return 0;
  var visible = 0;
  for (final r in s.runes) {
    final c = String.fromCharCode(r);
    if (RegExp(r'[\u4e00-\u9fffA-Za-z0-9]').hasMatch(c)) visible++;
  }
  return visible / math.max(1, s.runes.length);
}
