// 离线解析实证：拿真实站点响应 HTML + 样本里的真实书源规则，跑引擎的
// parseSearchPage，定位「有响应但 0 结果」发生在哪一环（不联网、可重复）。
//
// 用例（对应兼容性报告里的定案）：
//   1. 若雨中文：HTTP 200 + 表格完整，但 bookUrl 规则是 @js: → 整行被丢弃
//   2. 抖音小说：结果页完整，bookList 用 `:has(a)` → 选择器支持度问题
//   3. 伪速读谷：POST 返回有效结果页（含 .item），验证解析链本身可用
//   4. 故事族：小响应页（2809B）解析行为留档
//
// 运行：flutter test tool/legado_parse_case_test.dart -r expanded
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/source_store.dart';

const _base = 'C:/Users/leey1/AppData/Local/Temp/opencode/legado_batch';

void main() {
  test('offline parse cases for compat report', () async {
    final sample =
        (jsonDecode(await File('$_base/sample_all.json').readAsString())
                as List)
            .cast<Map>();

    BookSource pick(String urlPart) {
      final e = sample.firstWhere(
        (e) => (e['bookSourceUrl'] ?? '').toString().contains(urlPart),
        orElse: () => throw StateError('样本里找不到 $urlPart'),
      );
      return BookSource.fromJson(e);
    }

    Future<void> runCase(
      String tag,
      BookSource bs,
      String htmlPath, {
      List<String> cssProbes = const [],
    }) async {
      final html = await File(htmlPath).readAsString();
      final repo = OnlineRepo(store: SourceStore(initial: [bs]));
      final books = repo.parseSearchPage(bs, html);
      print('【$tag】parseSearchPage → ${books.length} 本');
      for (final b in books.take(3)) {
        print('   · ${b.name} | ${b.author} | ${b.bookUrl}');
      }
      final engine = AnalyzeRule(html, baseUrl: bs.bookSourceUrl);
      final listRule = bs.searchRule?.bookList ?? '';
      final rows = engine.getRawList(listRule);
      print('   bookList「$listRule」→ ${rows.length} 行');
      if (rows.isNotEmpty) {
        final it = rows.first;
        final name = engine.getString(bs.searchRule!.name ?? '', ctx: it);
        final url = engine.getString(bs.searchRule!.bookUrl ?? '', ctx: it);
        print('   首行 name=${name ?? '(空)'}');
        print('   首行 bookUrl=${url ?? '(空 ← 被丢弃的直接原因)'}');
      }
      for (final sel in cssProbes) {
        print('   CSS「$sel」→ 命中 ${engine.getElements(sel).length} 个元素');
      }
      print('');
    }

    // 1) 若雨中文：站点响应完好；bookUrl=@js → 期望 rows>0、books=0
    await runCase(
      '若雨中文 (a1)',
      pick('3yt.info'),
      '$_base/html/a1_ruoyu.html',
      cssProbes: ['table.table_01 tbody tr', 'table.table_01 tr'],
    );

    // 2) 抖音小说：结果页完好；bookList 含 :has(a)
    await runCase(
      '抖音小说 (a3)',
      pick('douyinxs.com'),
      '$_base/html/a3_douyin.html',
      cssProbes: [
        '.novelslist2 ul li',
        '.novelslist2 ul li:has(a)',
        'li:has(a)',
      ],
    );

    // 3) 伪速读谷：POST 有效响应（带表单头）→ 解析链应该通
    await runCase(
      '伪速读谷 (a4)',
      pick('sudugu.cc'),
      '$_base/html/a4_sudugu.html',
      cssProbes: ['.item', '.itemtxt h3 a'],
    );

    // 4) 故事族：留档（判站点页 vs 解析）
    await runCase(
      '故事族 (a2)',
      pick('gushizu.com'),
      '$_base/html/a2_gushizu.html',
      cssProbes: ['a.flex-wrp', '.novel-list a', 'a.flex-wrp, .novel-list a'],
    );
  }, timeout: const Timeout(Duration(minutes: 5)));
}
