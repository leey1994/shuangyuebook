// owllook 内置源真实链路探针（默认跳过，OWLLOOK_LIVE=1 才跑）。
//   $env:OWLLOOK_LIVE='1'; flutter test test/owllook_live_test.dart
// 用来定位「搜书 → 详情目录 → 正文」到底断在哪一跳。
@Tags(['native'])

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/sources/owllook_source.dart';

void main() {
  final live = Platform.environment['OWLLOOK_LIVE'] == '1';
  final kw = Platform.environment['OWLLOOK_KW'] ?? '诡秘之主';

  test('真实章节页 HTML → 正文段落（布局变体回归）', () async {
    final f = Platform.environment['OWLLOOK_HTML'];
    if (f == null || !File(f).existsSync()) {
      markTestSkipped('设 OWLLOOK_HTML=<真实正文页 HTML 文件> 才跑');
      return;
    }
    final html = File(f).readAsStringSync();
    final paras = OwllookSource.parseOwllookContent(html);
    // ignore: avoid_print
    print('段落数=${paras.length} 前2段=${paras.take(2).toList()}');
    expect(paras, isNotEmpty, reason: '另一种正文布局也必须解析出正文');
  });

  test('owllook 搜索 → 详情目录 → 正文', () async {
    if (!live) {
      markTestSkipped('设 OWLLOOK_LIVE=1 才跑真实网络探针');
      return;
    }
    final src = OwllookSource();
    // ignore: avoid_print
    print('搜索词: $kw');
    final books = await src.search(kw);
    // ignore: avoid_print
    print('搜索结果: ${books.length} → ${books.take(3).map((b) => '${b.title}|${b.url}').toList()}');
    expect(books, isNotEmpty, reason: '搜索应有结果');
    final b = books.first;
    // ignore: avoid_print
    print('打开详情: ${b.title} @ ${b.url}');
    final detail = await src.fetchDetail(b);
    // ignore: avoid_print
    print('目录: ${detail.chapters.length} 章 → ${detail.chapters.take(2).map((c) => '${c.title}|${c.url}').toList()}');
    expect(detail.chapters, isNotEmpty, reason: '目录不应为空');
    final paras = await src.fetchChapter(detail, detail.chapters.first);
    // ignore: avoid_print
    print('正文: ${paras.length} 段 → ${paras.take(2).toList()}');
    expect(paras, isNotEmpty, reason: '正文不应为空');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
