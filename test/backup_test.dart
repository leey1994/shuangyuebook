// 备份 / 恢复：一个 JSON 装下书架、偏好、书源、变量与统计，恢复后要能读回来。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shuangyue/data/backup.dart';
import 'package:shuangyue/data/stats_store.dart';
import 'package:shuangyue/legado/source_vars.dart';
import 'package:shuangyue/platform/native_bridge.dart';
import 'package:shuangyue/store.dart';

void main() {
  test('导出 → 改数据 → 恢复，偏好 / 变量 / 统计回到备份时', () async {
    final dir = Directory.systemTemp.createTempSync('sy_backup_');
    addTearDown(() => dir.deleteSync(recursive: true));
    BackupService.debugDir = dir;
    final dirs = AppDirs(files: dir.path, cache: dir.path);

    SharedPreferences.setMockInitialValues({
      'searchHistory': ['旧词'],
      'fontSize': 22.0,
      'edgeNotice': true,
    });
    await AppStore.I.init();
    final sp = AppStore.I.sp!;

    final stats = StatsStore(dirsOverride: dirs)..debugAddSecondsForDate('2026-01-01', 60);
    StatsStore.shared = stats;
    SourceVars.I.set('https://a.test', 'k', 'v');

    final file = await BackupService.export();
    expect(await file.exists(), isTrue);
    expect((await BackupService.list()).length, 1);

    // 弄乱现场：偏好改了、搜索历史清了、变量删了
    await sp.setStringList('searchHistory', []);
    await sp.setDouble('fontSize', 12);
    SourceVars.I.set('https://a.test', 'k', null);

    final restored = StatsStore(dirsOverride: dirs);
    StatsStore.shared = restored;
    final r = await BackupService.restore(file);

    expect(r.error, isNull);
    expect(sp.getStringList('searchHistory'), ['旧词']);
    expect(sp.getDouble('fontSize'), 22.0);
    expect(SourceVars.I.get('https://a.test', 'k'), 'v');
    expect(restored.totalSeconds, 60);
    expect(restored.days['2026-01-01'], 60);
  });
}
