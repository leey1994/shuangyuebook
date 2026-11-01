// 分页 / 目录落盘的粗略基准（不是断言测试，数字看输出）。
//
//   flutter test tool/bench_paginate_test.dart
//
// 目的：给「字号改动后整章重排」「每次开章重编码目录」这类热路径一个数量级，
// 免得优化方案只凭感觉。
import 'dart:convert';

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/paginate.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const style = TextStyle(fontSize: 20, height: 1.7);
  // 典型一章：40 段 × 150 字 ≈ 6000 字
  final paras = List.generate(
    40,
    (i) => '第$i段。' + ('天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏。' * 10),
  );

  test('paginate 60 章 × 6000 字', () {
    // 预热
    paginateParas(
        paras: paras, width: 360, height: 600, style: style, paraSpacing: 12);
    final sw = Stopwatch()..start();
    var pages = 0;
    for (var i = 0; i < 60; i++) {
      pages += paginateParas(
              paras: paras, width: 360, height: 600, style: style, paraSpacing: 12)
          .length;
    }
    sw.stop();
    // ignore: avoid_print
    print('[bench] 60 章 `paginateParas`: ${sw.elapsedMilliseconds}ms '
        '(${(sw.elapsedMicroseconds / 60000).toStringAsFixed(2)}ms/章, $pages 页)');
  });

  test('目录 jsonEncode（每次开章都会跑一遍 _rememberDetail 的编码）', () {
    final chapters = [
      for (var i = 0; i < 2000; i++)
        {'title': '第$i章 标题标题标题', 'url': 'https://example.com/book/123456/$i.html'}
    ];
    final sw = Stopwatch()..start();
    var bytes = 0;
    for (var i = 0; i < 20; i++) {
      bytes = jsonEncode(chapters).length;
    }
    sw.stop();
    // ignore: avoid_print
    print('[bench] 2000 章目录 jsonEncode ×20: ${sw.elapsedMilliseconds}ms '
        '(约 ${(sw.elapsedMicroseconds / 20000).toStringAsFixed(2)}ms/次, ${bytes ~/ 1024}KB)');
  });
}
