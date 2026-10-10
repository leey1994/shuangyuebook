// 桌宠「小墨」的回归测试。
//
// 关注两件事：
// 1) 成长值怎么算 —— 阅读时长现算、奖励另存，改了别弄出双重计数；
// 2) 各形态画出来是不是同一只 —— 靠不变量校验（每个阶段都画过、朱印都在）。
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/pet/pet_lines.dart';
import 'package:novel_reader/pet/pet_painter.dart';
import 'package:novel_reader/pet/pet_store.dart';

void main() {
  group('成长值', () {
    test('阅读经验由阅读秒数现算，不另存一份', () {
      var secs = 0;
      final p = PetStore(readingSeconds: () => secs);
      expect(p.exp, 0);
      secs = 30 * 7;
      expect(p.exp, 7); // 每 30 秒 1 点
      secs = 29;
      expect(p.exp, 0, reason: '不满 30 秒不给点，避免最后几秒被抹掉');
    });

    test('阶段阈值单调，边界取值正确', () {
      expect(stageForExp(0), PetStage.drop);
      expect(stageForExp(kPetStageExp[1] - 1), PetStage.drop);
      expect(stageForExp(kPetStageExp[1]), PetStage.paper);
      expect(stageForExp(kPetStageExp[2]), PetStage.fox);
      expect(stageForExp(kPetStageExp[3]), PetStage.spirit);
      expect(stageForExp(999999), PetStage.spirit);
    });

    test('阶内进度在 0..1 之间，满级恒为 1', () {
      final p = PetStore(readingSeconds: () => 0)..debugSetBonus(0);
      expect(p.stageProgress, 0.0);
      expect(p.toNextStage, kPetStageExp[1]);
      p.debugSetBonus(kPetStageExp[1] - 1);
      expect(p.stageProgress, greaterThan(0.9));
      p.debugSetBonus(999999);
      expect(p.stageProgress, 1.0);
      expect(p.toNextStage, 0, reason: '满级不该再报「还差多少」');
    });

    test('摸一下连点有冷却，只长一次', () {
      final p = PetStore(readingSeconds: () => 0);
      expect(p.pet(), isTrue);
      expect(p.exp, 1);
      expect(p.pet(), isFalse, reason: '冷却期内不该再给经验');
      expect(p.exp, 1);
      expect(p.petCount, 1);
    });

    test('搜索开书比摸一下给得多', () {
      final p = PetStore(readingSeconds: () => 0);
      p.searchOpened();
      expect(p.exp, 15);
    });

    test('升阶只播报一次，取走即清空', () {
      final p = PetStore(readingSeconds: () => 0);
      p.debugSetBonus(kPetStageExp[1] - 1);
      p.checkStage();
      expect(p.takeStageUp(), isNull, reason: '还没到门槛');
      p.debugSetBonus(kPetStageExp[1]);
      p.checkStage();
      expect(p.takeStageUp(), PetStage.paper);
      expect(p.takeStageUp(), isNull);
    });

    test('打招呼同一进程只认一次，否则路由来回切会把久别天数清零', () {
      final p = PetStore(readingSeconds: () => 0);
      expect(p.greet(), isNotNull);
      expect(p.greet(), isNull);
      expect(p.greet(), isNull);
    });
  });

  group('形态一致性', () {
    // 每个阶段、每种情绪都画一遍：不能抛异常，且不变量画布必须留下痕迹
    Future<ByteData> paint(PetStage stage, PetMood mood) async {
      final rec = ui.PictureRecorder();
      final canvas = Canvas(rec);
      PetPainter(stage: stage, mood: mood, phase: 1.3)
          .paint(canvas, const Size(40, 26));
      final pic = rec.endRecording();
      final img = await pic.toImage(40, 26);
      final data = (await img.toByteData(format: ui.ImageByteFormat.rawRgba))!;
      img.dispose();
      pic.dispose();
      return data;
    }

    test('所有阶段 / 情绪都能画出来', () async {
      for (final s in PetStage.values) {
        for (final m in PetMood.values) {
          await expectLater(paint(s, m), completes);
        }
      }
    });

    test('四个阶段都带着同一枚朱红印 —— 认得出是同一只', () async {
      for (final s in PetStage.values) {
        final px = await paint(s, PetMood.calm);
        var red = 0;
        for (var i = 0; i < px.lengthInBytes; i += 4) {
          final r = px.getUint8(i),
              g = px.getUint8(i + 1),
              b = px.getUint8(i + 2);
          // 朱红 #D8454A 附近：红明显高于绿和蓝
          if (r > 150 && g < 120 && b < 120 && r - g > 60) red++;
        }
        expect(red, greaterThan(0), reason: '${s.label} 的朱红印丢了');
      }
    });
  });

  group('台词', () {
    test('每个时段都有话说', () {
      for (var h = 0; h < 24; h++) {
        final s = greetingScene(DateTime(2026, 1, 1, h));
        expect(s.lines, isNotEmpty);
        expect(petLine(s, day: 3), isNotEmpty);
      }
    });

    test('深夜（23 点 / 凌晨 3 点）走劝睡语气，白天不是', () {
      expect(greetingScene(DateTime(2026, 1, 1, 23)).id, 'night');
      expect(greetingScene(DateTime(2026, 1, 1, 3)).id, 'night');
      expect(greetingScene(DateTime(2026, 1, 1, 10)).id, isNot('night'));
    });

    test('越久没来，台词档位越高', () {
      expect(absenceScene(1).id, 'away0');
      expect(absenceScene(3).id, 'away2');
      expect(absenceScene(9).id, 'away7');
      expect(absenceScene(60).id, 'away30');
    });

    test('同一场景换一轮会换句子，不至于一直重复', () {
      final s = greetingScene(DateTime(2026, 1, 1, 9));
      final seen = <String>{
        for (var t = 0; t < s.lines.length; t++) petLine(s, day: 3, turn: t)
      };
      expect(seen.length, s.lines.length, reason: '轮换应能覆盖到全部候选');
    });
  });
}
