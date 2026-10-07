import 'package:flutter/painting.dart';

/// 阅读器分页引擎：按可视尺寸把段落切成页。
///
/// 每个段落单独测量（与渲染时的 Text 一一对应）；
/// 超过一页的长段落按二分查找切分成多段。
List<List<String>> paginateParas({
  required List<String> paras,
  required double width,
  required double height,
  required TextStyle style,
  required double paraSpacing,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  if (width <= 0 || height <= 0) return [paras];

  // 测量缓存：同一字符串（含二分查找的重复前缀）只布局一次
  final mcache = <String, double>{};
  double measure(String t) {
    if (t.isEmpty) return 0;
    final hit = mcache[t];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(text: t, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: width);
    final h = tp.height;
    tp.dispose();
    mcache[t] = h;
    return h;
  }

  // 长段落切分：返回能放进一页的前缀。
  String cutToFit(String t) {
    var lo = 1, hi = t.length;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      // 避免切开代理对（emoji 等）
      var cut = mid;
      if (cut < t.length &&
          t.codeUnitAt(cut - 1) >= 0xD800 &&
          t.codeUnitAt(cut - 1) <= 0xDBFF) {
        cut -= 1;
      }
      if (cut <= lo) break;
      if (measure(t.substring(0, cut)) <= height) {
        lo = cut;
      } else {
        hi = cut - 1;
      }
    }
    final end = lo.clamp(1, t.length).toInt();
    return t.substring(0, end);
  }

  final pages = <List<String>>[];
  var current = <String>[];
  var used = 0.0;

  for (var p in paras) {
    var rest = p;
    while (rest.isNotEmpty) {
      final h = measure(rest);
      final gap = current.isNotEmpty ? paraSpacing : 0.0;
      if (gap + h <= height - used) {
        used += gap + h;
        current.add(rest);
        rest = '';
        continue;
      }
      // 放不下
      if (current.isEmpty) {
        // 一段就超过一页：切开
        final head = cutToFit(rest);
        if (head.isEmpty) {
          // 兜底，防死循环
          current.add(rest);
          rest = '';
        } else {
          pages.add([head]);
          rest = rest.substring(head.length);
        }
      } else {
        pages.add(current);
        current = [];
        used = 0;
      }
    }
  }
  if (current.isNotEmpty) pages.add(current);
  if (pages.isEmpty) pages.add([]);
  return pages;
}

/// 简易自检（flutter test 可直接调用）。
void assertPaginateWorks() {
  const style = TextStyle(fontSize: 16, height: 1.5);
  final pages = paginateParas(
    paras: List.generate(
        200, (i) => '第$i段测试文字，内容长度中等。'.padRight(30)),
    width: 300,
    height: 500,
    style: style,
    paraSpacing: 8,
  );
  assert(pages.length > 1, '200 段文字应切成多页');
  final flat = pages.expand((p) => p).toList();
  assert(flat.length == 200, '分页不应丢失段落');
}
