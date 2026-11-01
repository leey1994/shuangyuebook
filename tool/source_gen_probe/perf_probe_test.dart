// 诊断：AI 生成书源「搜索结果一多就卡」——逐阶段计时定位瓶颈。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/source_generator.dart';

const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/122.0.0.0 Safari/537.36';

void main() {
  // 注意：不要 ensureInitialized —— flutter test 的 binding 会把所有
  // Dart HTTP 请求 mock 成 400（纯 dart 网络诊断因此必须裸跑）。

  test('slimHtml 耗时随页面大小的增长', () {
    final probe = File('../source_gen_probe/pages/sf_s.html');
    final small = probe.existsSync()
        ? probe.readAsStringSync()
        : '<html><body><ul><li><a href="/b/1">书名</a></li></ul></body></html>';
    // ignore: avoid_print
    print('[diag] base page: ${small.length} chars');
    for (final mult in [1, 5, 15, 40]) {
      final big = small * mult;
      final sw = Stopwatch()..start();
      final out = slimHtml(big);
      final ms = sw.elapsedMilliseconds;
      // ignore: avoid_print
      print('[diag] slimHtml ${big.length} chars → ${out.length} chars  ${ms}ms');
      expect(ms, lessThan(3000), reason: '${big.length} 字符不应超过 3s');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('shuyous.com 全流程页面：逐页抓取 / 瘦身 / 上下文预算', () async {
    // 用户实测站：搜索在 rrssk.com（跨域），详情/目录同页，正文 /book/x-y.html
    const pages = <(String, String)>[
      ('首页', 'https://www.shuyous.com/'),
      ('搜索', 'https://www.rrssk.com/?action=find&v=16&q=NSQkSKxA6C0pPLsKLLUYwzVtQKUbSwimpCz576SVIpTctl8TLXdCgX%2BTGkj5g39tgkyNK1CdwSMi3FjYs7hjVA%3D%3D&page=1'),
      ('详情', 'https://www.shuyous.com/book/4194655.html'),
      ('正文', 'https://www.shuyous.com/book/4194655-77.html'),
    ];
    var total = 0;
    for (final (label, url) in pages) {
      final sw = Stopwatch()..start();
      try {
        final slim = await fetchSlim(url);
        total += slim.length;
        // ignore: avoid_print
        print('[diag] $label ${sw.elapsedMilliseconds}ms → '
            '${slim.length} chars（约 ${slim.length ~/ 2} tokens）');
      } catch (e) {
        // ignore: avoid_print
        print('[diag] $label 失败（${sw.elapsedMilliseconds}ms）：$e');
      }
    }
    // ignore: avoid_print
    print('[diag] 上下文合计 ≈ ${total ~/ 2} tokens');
  }, timeout: const Timeout(Duration(minutes: 5)));

  test('真实大结果页：SourceHttpClient 抓取 / 瘦身 / 上下文预算', () async {
    // 之前裸 http.get 被 WAF 拒 400（curl 200），换书源同款客户端后应 200
    final sw = Stopwatch()..start();
    final slim = await fetchSlim(
        'https://book.sfacg.com/List/?tid=21&page=1'); // 分类列表页，条目多
    // ignore: avoid_print
    print('[diag] fetchSlim 总耗时 ${sw.elapsedMilliseconds}ms → ${slim.length} chars');
    // ignore: avoid_print
    print('[diag] 喂给模型的单页上下文: ${slim.length} chars ≈ ${slim.length ~/ 2} tokens');
    expect(slim.length, lessThanOrEqualTo(20000));
    expect(slim, contains('<'), reason: '应抓到真实页面结构');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
