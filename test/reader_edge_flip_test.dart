// 「章末/章首继续拖 → 换章」的越界计数（滑动 / 覆盖模式）。
//
// 旧实现把两侧方向符号写反：章末攒的是 `d < 0`、章首攒的是 `d > 0`，
// 而 scrollDelta 朝下一页为正 —— 计数每帧都被清零，手势翻章从不触发。
// 方向语义见 lib/screens/reader_screen.dart 的 pagedEdgeAccum。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/screens/reader_screen.dart';

void main() {
  const threshold = 120.0; // 与 _kEdgeDragToChapter 同值

  double run(List<double?> deltas,
      {required double pixels, required double min, required double max}) {
    var acc = 0.0;
    for (final d in deltas) {
      acc = pagedEdgeAccum(
          acc: acc,
          pixels: pixels,
          minExtent: min,
          maxExtent: max,
          scrollDelta: d);
    }
    return acc;
  }

  group('章末往后拖', () {
    test('越界且继续正向拖 → 累计到阈值翻下一章', () {
      // 8 帧 × 20px 越界拖动
      final acc = run(List.filled(8, 20.0), pixels: 160.0, min: 0.0, max: 40.0);
      expect(acc, greaterThanOrEqualTo(threshold));
    });

    test('越界量不足阈值不翻（误触保护）', () {
      final acc = run([20.0], pixels: 60.0, min: 0.0, max: 40.0);
      expect(acc, lessThan(threshold / 3));
    });
  });

  group('章首往前拖', () {
    test('越界且负向拖 → 反向也累计（上一章）', () {
      final acc =
          run(List.filled(8, -20.0), pixels: -160.0, min: 0.0, max: 40.0);
      expect(acc, greaterThanOrEqualTo(threshold));
    });
  });

  group('不该攒出翻章的情况', () {
    test('页内正常滑动一律清零', () {
      expect(run([30.0, 30.0, 30.0], pixels: 20.0, min: 0.0, max: 40.0), 0.0);
      expect(run([-30.0], pixels: 20.0, min: 0.0, max: 40.0), 0.0);
    });

    test('越界后往回转立刻清零（回弹不算翻章）', () {
      expect(run([40.0, -20.0], pixels: 60.0, min: 0.0, max: 40.0), 0.0);
    });

    test('越界但 scrollDelta 为 null（回弹帧）不累计', () {
      expect(run([null], pixels: 60.0, min: 0.0, max: 40.0), 0.0);
    });

    test('旧写法：正向越界帧被清零 —— 这正是 bug 本身', () {
      double oldAcc(double acc, double pixels, double d) {
        if (pixels >= 40.0 && d < 0) {
          acc += -d;
        } else if (pixels <= 0.0 && d > 0) {
          acc += d;
        } else {
          acc = 0;
        }
        return acc;
      }

      var acc = 0.0;
      for (var i = 0; i < 8; i++) {
        acc = oldAcc(acc, 60.0, 20.0); // 章末正向拖 8 帧
      }
      expect(acc, 0.0, reason: '符号写反时永远攒不起来');
    });
  });
}
