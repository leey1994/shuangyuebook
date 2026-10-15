// 本轮几处修正的回归测试。
//
// 1) 覆盖翻页只显示一半：翻页动画期间 PageView 的 page 处在中间值，
//    旧代码按 round() 判断「错位」后每帧都排一个 jumpToPage，把
//    animateToPage 反复打断，页面半天归不了位。
// 2) 桌宠成长太快的阈值。
// 3) 挖孔屏避让。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/data/shelf_sort.dart';
import 'package:shuangyue/pet/pet_store.dart';
import 'package:shuangyue/pet/pet_view.dart';

void main() {
  group('覆盖翻页的对齐判据', () {
    /// 与阅读器 build 里的判据保持一致：**静止**时才允许对齐。
    bool needsJump(
        {required double controllerPage,
        required int logicalPage,
        required bool scrolling}) {
      if (scrolling) return false;
      return (controllerPage - logicalPage).abs() >= 0.5;
    }

    test('翻页动画进行中一律不对齐', () {
      // 从第 3 页动画到第 4 页：整段都处于 scrolling 状态
      for (final p in [3.0, 3.1, 3.25, 3.5, 3.75, 3.9, 4.0]) {
        expect(needsJump(controllerPage: p, logicalPage: 4, scrolling: true),
            isFalse,
            reason: 'page=$p 动画进行中，跳过去会把 animateToPage 打断');
      }
    });

    test('静止时的真实错位仍然会对齐', () {
      expect(needsJump(controllerPage: 2.0, logicalPage: 4, scrolling: false),
          isTrue,
          reason: '模式切换 / 换章后要拉回来');
      expect(needsJump(controllerPage: 0.0, logicalPage: 5, scrolling: false),
          isTrue);
    });

    test('静止但已对齐（含浮点残差）不动', () {
      expect(needsJump(controllerPage: 4.0, logicalPage: 4, scrolling: false),
          isFalse);
      expect(needsJump(controllerPage: 4.02, logicalPage: 4, scrolling: false),
          isFalse);
    });

    test('旧写法在动画途中每帧都误判 —— 这正是 bug 的来源', () {
      bool oldNeedsJump(double controllerPage, int logicalPage) =>
          controllerPage.round() != logicalPage;
      expect(oldNeedsJump(3.4, 4), isTrue,
          reason: 'round(3.4)=3 != 4 → 旧代码每帧都跳，动画被反复打断');
    });
  });

  group('桌宠成长节奏', () {
    test('阈值对应长期养成，而不是几天毕业', () {
      expect(kPetStageExp, [0, 1500, 6000, 20000]);
      // 每 30 秒 1 点 → 每天读一小时 ≈ 120 点
      const perDay = 120;
      final days = kPetStageExp.map((e) => e ~/ perDay).toList();
      expect(days[1], greaterThanOrEqualTo(10), reason: '第一阶至少 10 天');
      expect(days[2], greaterThanOrEqualTo(40), reason: '第二阶至少一个多月');
      expect(days[3], greaterThanOrEqualTo(150), reason: '第三阶至少半年');
    });

    test('阶段严格递增', () {
      for (var i = 1; i < kPetStageExp.length; i++) {
        expect(kPetStageExp[i], greaterThan(kPetStageExp[i - 1]));
      }
    });

    test('零经验仍是墨滴，满经验是书灵', () {
      expect(stageForExp(0).index, 0);
      expect(stageForExp(kPetStageExp.last - 1).index, kPetStageExp.length - 2);
      expect(stageForExp(999999).index, kPetStageExp.length - 1);
    });
  });

  group('桌宠不会跑出活动区', () {
    // 桌面标题栏：活动区高度就等于窄带（26px）
    const barH = 26.0;

    test('活动区只有窄带高时，桌宠钉在顶部不乱跑', () {
      for (final y in [0.0, 0.5, 1.0]) {
        final top = petTopFor(areaH: barH, h: barH, pinned: false, posY: y);
        expect(top, 0.0,
            reason: 'posY=$y 时算出 $top —— 高度不够溜达，'
                '再往下会掉出标题栏（这是曾经的回归）');
      }
    });

    test('阅读器钉住时，整屏高度也只在顶部窄带里', () {
      for (final y in [0.0, 0.5, 1.0]) {
        expect(petTopFor(areaH: 800, h: barH, pinned: true, posY: y), 0.0);
      }
    });

    test('非阅读界面在整屏范围内上下溜达', () {
      final top = petTopFor(areaH: 800, h: barH, pinned: false, posY: 1.0);
      expect(top, greaterThan(600), reason: '底端要能走到屏幕下部');
      expect(petTopFor(areaH: 800, h: barH, pinned: false, posY: 0.0), 0.0);
    });

    test('任何条件下都不越界（这是唯一真正要守的不变量）', () {
      for (final areaH in [26.0, 40.0, 52.0, 100.0, 800.0]) {
        for (final pinned in [true, false]) {
          for (final y in [0.0, 0.13, 0.5, 0.87, 1.0]) {
            final top =
                petTopFor(areaH: areaH, h: barH, pinned: pinned, posY: y);
            expect(top, greaterThanOrEqualTo(0.0),
                reason: 'areaH=$areaH pinned=$pinned y=$y → top=$top 跑出上沿');
            expect(top + barH, lessThanOrEqualTo(areaH + 0.001),
                reason: 'areaH=$areaH pinned=$pinned y=$y → 跑出下沿');
          }
        }
      }
    });

    test('posY 越界时收敛到边界，不产生飞出去的坐标', () {
      expect(petTopFor(areaH: 800, h: barH, pinned: false, posY: -5), 0.0);
      expect(petTopFor(areaH: 800, h: barH, pinned: false, posY: 99),
          closeTo(800 - barH - 18, 0.001));
    });
  });

  group('挖孔屏避让', () {
    test('四种类型解析安全', () {
      expect(punchHoleFrom(null), PunchHole.none);
      expect(punchHoleFrom(''), PunchHole.none);
      expect(punchHoleFrom('乱填'), PunchHole.none);
      expect(punchHoleFrom('topCenter'), PunchHole.topCenter);
      expect(punchHoleFrom('topLeft'), PunchHole.topLeft);
      expect(punchHoleFrom('topRight'), PunchHole.topRight);
    });

    test('无挖孔时不需要避让', () {
      expect(PunchHole.none.anchorX.isNaN, isTrue);
    });

    test('三种挖孔的锚点分布合理', () {
      expect(PunchHole.topCenter.anchorX, closeTo(0.5, 0.001));
      expect(PunchHole.topLeft.anchorX, lessThan(0.3));
      expect(PunchHole.topRight.anchorX, greaterThan(0.7));
      for (final h in PunchHole.values.where((h) => h != PunchHole.none)) {
        expect(h.keepOut, greaterThan(0));
        expect(h.keepOut, lessThan(0.3), reason: '避让区不能宽到把可用空间吃光');
      }
    });

    /// 与 PetBar._step 里的避让逻辑一致：落点太靠近摄像头就推开。
    double avoid(double x, PunchHole hole) {
      if (hole == PunchHole.none) return x;
      final anchor = hole.anchorX;
      if ((x - anchor).abs() >= hole.keepOut) return x;
      final dir = x >= anchor ? 1.0 : -1.0;
      var nx = (anchor + dir * hole.keepOut * 1.25).clamp(0.0, 1.0);
      if ((nx - anchor).abs() < hole.keepOut) {
        nx = (anchor - dir * hole.keepOut * 1.25).clamp(0.0, 1.0);
      }
      return nx;
    }

    test('落在挖孔附近会被推开', () {
      for (final hole in PunchHole.values.where((h) => h != PunchHole.none)) {
        for (final x in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final nx = avoid(x, hole);
          expect((nx - hole.anchorX).abs(),
              greaterThanOrEqualTo(hole.keepOut - 1e-9),
              reason: '挖孔=${hole.name} 落点 $x 避让后 $nx 仍压在摄像头上');
          expect(nx, inInclusiveRange(0.0, 1.0));
        }
      }
    });

    test('本来就不挨着挖孔的落点保持不动', () {
      expect(avoid(0.05, PunchHole.topCenter), 0.05);
      expect(avoid(0.95, PunchHole.topCenter), 0.95);
    });

    test('无挖孔时原样返回', () {
      for (final x in [0.0, 0.3, 0.5, 1.0]) {
        expect(avoid(x, PunchHole.none), x);
      }
    });
  });
}
