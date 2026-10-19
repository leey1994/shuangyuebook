import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/paginate.dart';

void main() {
  const style = TextStyle(fontSize: 16, height: 1.5);
  final paras = List.generate(300, (i) => '第$i段${'测试文字内容中等' * 6}');

  ParaPaginator make() => ParaPaginator(
        paras: paras,
        width: 300,
        height: 500,
        style: style,
        paraSpacing: 8,
      );

  test('P1-7 分批 pump 与一次排完结果完全一致', () {
    final all = paginateParas(
      paras: paras,
      width: 300,
      height: 500,
      style: style,
      paraSpacing: 8,
    );
    final p = make();
    var rounds = 0;
    while (!p.done) {
      p.pump(Duration.zero); // 每次至多推进一步
      rounds++;
      if (rounds > 100000) fail('pump 未收敛');
    }
    expect(p.pages.length, all.length);
    expect(p.pages.expand((e) => e).toList(), all.expand((e) => e).toList());
    expect(rounds, greaterThan(1)); // 确实分了很多批
  });

  test('P1-7 首屏预算内即产出可渲染的页，且列表原地增长', () {
    final p = make();
    p.pump(const Duration(milliseconds: 8));
    expect(p.pages, isNotEmpty); // 首帧就有内容，不等整章排完
    expect(p.done, isFalse);
    final n = p.pages.length;
    p.pump(const Duration(milliseconds: 8));
    expect(p.pages.length, greaterThanOrEqualTo(n));
  });

  test('P1-7 尺寸非法 / 空段落：与原实现同为单页兜底', () {
    expect(
      paginateParas(paras: paras, width: 0, height: 0, style: style, paraSpacing: 8),
      [paras],
    );
    expect(
      paginateParas(paras: [], width: 300, height: 500, style: style, paraSpacing: 8),
      [<String>[]],
    );
    final p = ParaPaginator(
      paras: paras,
      width: 0,
      height: 500,
      style: style,
      paraSpacing: 8,
    );
    expect(p.done, isTrue);
    expect(p.pages, [paras]);
  });

  test('P1-7 超长单段按二分切分，分批与一次排完一致', () {
    final long = List.generate(3, (i) => '第$i段${'很长的正文内容' * 400}');
    final all = paginateParas(
      paras: long,
      width: 300,
      height: 500,
      style: style,
      paraSpacing: 8,
    );
    expect(all.length, greaterThan(3)); // 单段被切成多页
    final p = ParaPaginator(
      paras: long,
      width: 300,
      height: 500,
      style: style,
      paraSpacing: 8,
    );
    while (!p.done) {
      p.pump(Duration.zero);
    }
    expect(p.pages, all);
    // 不丢字：拼回原文
    expect(p.pages.expand((e) => e).join(), long.join());
  });
}
