import 'package:flutter/painting.dart';

/// 阅读器分页引擎：按可视尺寸把段落切成页。
///
/// 每个段落单独测量（与渲染时的 Text 一一对应）；
/// 超过一页的长段落按二分查找切分成多段。
///
/// [indent]：首行缩进前缀（如两个全角空格）。渲染端会给每个段落加上它，
/// 测量必须带同样的前缀，否则首行宽度差两字会把「量成一行的段落」
/// 排成两行，造成溢出或页码错位。页面里仍存原文，渲染端再补缩进。
///
/// 可续排实现见 [ParaPaginator]：`pump()` 允许分批推进（长章节首屏不再
/// 卡在 build 里一次性排完），[paginateParas] 只是一次排完的薄封装。
List<List<String>> paginateParas({
  required List<String> paras,
  required double width,
  required double height,
  required TextStyle style,
  required double paraSpacing,
  TextScaler textScaler = TextScaler.noScaling,
  String indent = '',
}) {
  final pager = ParaPaginator(
    paras: paras,
    width: width,
    height: height,
    style: style,
    paraSpacing: paraSpacing,
    textScaler: textScaler,
    indent: indent,
  );
  pager.runAll();
  return pager.pages;
}

/// 可分批推进的分页器：[pump] 在给定时间预算内继续排版，
/// 已排好的页实时出现在 [pages] 里（列表原地增长，可直接渲染）。
class ParaPaginator {
  ParaPaginator({
    required this.paras,
    required this.width,
    required this.height,
    required this.style,
    required this.paraSpacing,
    this.textScaler = TextScaler.noScaling,
    this.indent = '',
  }) {
    if (width <= 0 || height <= 0) {
      // 尺寸未知：退化成「全部塞一页」，与原实现一致
      pages.add(List<String>.of(paras));
      _finished = true;
    }
  }

  final List<String> paras;
  final double width;
  final double height;
  final TextStyle style;
  final double paraSpacing;
  final TextScaler textScaler;
  final String indent;

  /// 已排好的页（原地增长；排完后长度即总页数）。
  final List<List<String>> pages = [];

  final Map<String, double> _mcache = {};
  final List<String> _current = [];
  double _used = 0;
  int _p = 0;
  String _rest = '';
  bool _restLoaded = false;
  bool _finished = false;

  bool get done => _finished;

  /// 测量缓存：同一字符串（含二分查找的重复前缀）只布局一次。
  double _measure(String t) {
    final full = indent + t;
    if (full.isEmpty) return 0;
    final hit = _mcache[full];
    if (hit != null) return hit;
    final tp = TextPainter(
      text: TextSpan(text: full, style: style),
      textDirection: TextDirection.ltr,
      textScaler: textScaler,
    )..layout(maxWidth: width);
    final h = tp.height;
    tp.dispose();
    _mcache[full] = h;
    return h;
  }

  /// 长段落切分：返回能放进一页的前缀。
  String _cutToFit(String t) {
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
      if (_measure(t.substring(0, cut)) <= height) {
        lo = cut;
      } else {
        hi = cut - 1;
      }
    }
    final end = lo.clamp(1, t.length).toInt();
    return t.substring(0, end);
  }

  /// 一次排完（[paginateParas] 用）。
  void runAll() {
    while (!_finished) {
      _advance();
    }
  }

  /// 在 [budget] 时间内尽量推进；返回时 [pages] 可安全渲染。
  void pump(Duration budget) {
    if (_finished) return;
    final sw = Stopwatch()..start();
    do {
      _advance();
    } while (!_finished && sw.elapsed < budget);
  }

  void _advance() {
    if (_p >= paras.length) {
      _close();
      return;
    }
    if (!_restLoaded) {
      _rest = paras[_p];
      _restLoaded = true;
    }
    if (_rest.isEmpty) {
      _p++;
      _restLoaded = false;
      return;
    }
    final h = _measure(_rest);
    final gap = _current.isNotEmpty ? paraSpacing : 0.0;
    if (gap + h <= height - _used) {
      _used += gap + h;
      _current.add(_rest);
      _rest = '';
      return;
    }
    // 放不下
    if (_current.isEmpty) {
      // 一段就超过一页：切开
      final head = _cutToFit(_rest);
      if (head.isEmpty) {
        // 兜底，防死循环
        _current.add(_rest);
        _rest = '';
      } else {
        pages.add(<String>[head]);
        _rest = _rest.substring(head.length);
      }
    } else {
      pages.add(List<String>.of(_current));
      _current.clear();
      _used = 0;
    }
  }

  void _close() {
    if (_current.isNotEmpty) {
      pages.add(List<String>.of(_current));
      _current.clear();
    }
    if (pages.isEmpty) pages.add(<String>[]);
    _finished = true;
  }
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
