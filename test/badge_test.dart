// 成就徽章的回归测试：跨线只发一次、老档静默回填、宠物庆祝 API。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/data/stats_store.dart';
import 'package:shuangyue/pet/pet_store.dart';
import 'package:shuangyue/platform/native_bridge.dart';

void main() {
  late Directory tmp;
  late AppDirs dirs;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('badge_test');
    dirs = AppDirs(files: tmp.path, cache: tmp.path);
  });

  tearDown(() {
    StatsStore.onBadgeEarned = null;
    tmp.deleteSync(recursive: true);
  });

  String dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  test('连续阅读跨过 3 天线：只庆祝一次，徽章入册且落盘可回读', () async {
    final fired = <String>[];
    StatsStore.onBadgeEarned = (b) => fired.add(b.id);

    final s = StatsStore(dirsOverride: dirs);
    await s.load();
    addTearDown(s.dispose);

    final now = DateTime.now();
    s.debugAddSecondsForDate(dateKey(now.subtract(const Duration(days: 2))), 60);
    s.debugAddSecondsForDate(dateKey(now.subtract(const Duration(days: 1))), 60);

    s.addReadingSeconds(60); // 今天也读了 → streak = 3
    expect(fired, ['first', 'streak3']); // 首次阅读徽章同时点亮
    expect(s.badges, contains('streak3'));

    s.addReadingSeconds(60); // 同一天再读：不重复发
    expect(fired, ['first', 'streak3']);

    // 落盘回读：徽章跟着存档走
    await s.debugFlush();
    final s2 = StatsStore(dirsOverride: dirs);
    await s2.load();
    addTearDown(s2.dispose);
    expect(s2.badges, contains('streak3'));
  });

  test('老存档升级：已达标的里程碑静默回填，不补开庆祝', () async {
    // 手工写一份「没有 badges 字段」的老档：3 天连读 + 10 小时
    final now = DateTime.now();
    final file = File('${dirs.files}/reading_stats.json');
    await file.writeAsString(jsonEncode({
      'version': 1,
      'totalSeconds': 36000,
      'finishedBooks': 0,
      'days': {
        for (var i = 0; i < 3; i++)
          dateKey(now.subtract(Duration(days: i))): 3600,
      },
    }));

    final fired = <String>[];
    StatsStore.onBadgeEarned = (b) => fired.add(b.id);

    final s = StatsStore(dirsOverride: dirs);
    await s.load();
    addTearDown(s.dispose);

    expect(fired, isEmpty, reason: '回填不庆祝');
    expect(s.badges, containsAll(['streak3', 'hours10']));

    // 之后的常规记时也不会把回填过的再发一遍
    s.addReadingSeconds(60);
    expect(fired, isEmpty);
  });

  test('读完一本书：books1 达成', () async {
    final fired = <String>[];
    StatsStore.onBadgeEarned = (b) => fired.add(b.id);

    final s = StatsStore(dirsOverride: dirs);
    await s.load();
    addTearDown(s.dispose);

    s.addFinishedBook();
    expect(fired, ['books1']);
    s.addFinishedBook();
    expect(fired, ['books1'], reason: 'books10 还远，不该再发');
  });

  test('新增徽章：首读 / 听书 / 换源 独立点亮，计数落盘可回读', () async {
    final fired = <String>[];
    StatsStore.onBadgeEarned = (b) => fired.add(b.id);

    final s = StatsStore(dirsOverride: dirs);
    await s.load();
    addTearDown(s.dispose);

    s.addReadingSeconds(60); // 首次阅读 → 首读达成
    expect(fired, ['first']);

    for (var i = 0; i < 20; i++) {
      s.addTtsSeconds(90); // 90s × 20 = 30 分钟 → 听书达人
    }
    expect(fired, ['first', 'tts']);

    for (var i = 0; i < 3; i++) {
      s.addSourceSwitch(); // 第 3 次 → 换源大师
    }
    expect(fired, ['first', 'tts', 'switch']);

    // 夜读只按「当前时刻是否在 23:00–05:00」累计，断言与钟点保持一致
    final isNight = DateTime.now().hour >= 23 || DateTime.now().hour < 5;
    expect(s.nightSeconds, isNight ? 60 : 0);

    await s.debugFlush();
    final s2 = StatsStore(dirsOverride: dirs);
    await s2.load();
    addTearDown(s2.dispose);
    expect(s2.ttsSeconds, 1800);
    expect(s2.switchCount, 3);
    expect(s2.badges, containsAll(['first', 'tts', 'switch']));
  });

  test('徽章墙口径：14 枚且前 5 枚为「我的」预览行', () {
    expect(kReadingBadges.length, 14);
    expect(kReadingBadges.take(5).map((b) => b.name).toList(),
        ['首读达成', '连续 7 天', '夜读诗人', '听书达人', '换源大师']);
  });

  test('celebrate：自定义气泡 + 奖励经验', () {
    final p = PetStore(readingSeconds: () => 0, prefs: () => null);
    expect(p.exp, 0);
    p.celebrate('七日不辍达成！', exp: 10);
    expect(p.bubble, '七日不辍达成！');
    expect(p.exp, 10);
  });
}
