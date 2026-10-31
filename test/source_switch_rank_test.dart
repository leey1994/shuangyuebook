// 换源候选排序：可用 → 未检测 → 失败；同档耗时升序。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/source_health.dart';

SourceHealth h(String url, {required bool ok, int ms = 0}) => SourceHealth(
      url: url,
      name: url,
      ok: ok,
      ms: ms,
      checkedAt: DateTime(2026, 10, 31),
    );

void main() {
  test('可用在前，失败在后，未检测居中', () {
    final list = [
      h('bad', ok: false, ms: 50),
      null,
      h('slow', ok: true, ms: 900),
      h('fast', ok: true, ms: 200),
    ];
    list.sort(SourceHealthStore.compareForSwitch);
    expect(list.map((e) => e?.url).toList(), ['fast', 'slow', null, 'bad']);
  });

  test('同档按耗时升序', () {
    final list = [
      h('b', ok: true, ms: 400),
      h('a', ok: true, ms: 120),
    ];
    list.sort(SourceHealthStore.compareForSwitch);
    expect(list.first?.url, 'a');
  });
}
