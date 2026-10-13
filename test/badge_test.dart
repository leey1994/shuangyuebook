// 成就徽章的回归测试：跨线只发一次、老档静默回填、宠物庆祝 API。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/data/stats_store.dart';
import 'package:novel_reader/pet/pet_store.dart';
import 'package:novel_reader/platform/native_bridge.dart';

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
    expect(fired, ['streak3']);
    expect(s.badges, contains('streak3'));

    s.addReadingSeconds(60); // 同一天再读：不重复发
    expect(fired, ['streak3']);

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

  test('celebrate：自定义气泡 + 奖励经验', () {
    final p = PetStore(readingSeconds: () => 0, prefs: () => null);
    expect(p.exp, 0);
    p.celebrate('七日不辍达成！', exp: 10);
    expect(p.bubble, '七日不辍达成！');
    expect(p.exp, 10);
  });
}
