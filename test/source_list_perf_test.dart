// 1000+ 条书源时的性能回归测试。
//
// 覆盖三件事：
//   1. 列表视图是**稳定实例**（不每次访问都复制整表）——旧实现每帧白拷 1000 个引用；
//   2. url → 下标走索引（O(1)），不是每行扫一遍（O(n²)）；
//   3. 批量操作只发一次通知；大 JSON 的解析/落盘在后台 isolate，不卡 UI。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/source_store.dart';
import 'package:shuangyue/platform/native_bridge.dart' show AppDirs;

Map<String, dynamic> _srcJson(int i, {bool enabled = false}) => {
      'bookSourceUrl': 'https://example.com/$i',
      'bookSourceName': '书源 $i',
      'bookSourceGroup': i.isEven ? '偶数组' : '奇数组',
      'enabled': enabled,
      'enabledExplore': false,
    };

BookSource _src(int i, {bool enabled = false}) =>
    BookSource.fromJson(_srcJson(i, enabled: enabled));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('仓库视图缓存', () {
    test('未变更时 sourcesView / enabledSources / urls 是同一实例', () {
      final store = SourceStore();
      store.addAll([for (var i = 0; i < 50; i++) _src(i)]);
      final v1 = store.sourcesView;
      final v2 = store.sourcesView;
      expect(identical(v1, v2), isTrue, reason: '每次访问都复制整表 = 每帧白拷');
      expect(identical(store.enabledSources, store.enabledSources), isTrue);
      expect(identical(store.urls, store.urls), isTrue);

      store.setEnabled('https://example.com/3', true);
      expect(identical(store.sourcesView, v1), isFalse,
          reason: '内容变了必须重建');
      expect(store.enabledSources.length, 1);
    });

    test('老 getter 仍然可用且不可修改', () {
      final store = SourceStore();
      store.addAll([_src(1)]);
      expect(store.sources.length, 1);
      expect(store.enabled.length, 0);
      expect(store.enabledCount, 0);
      expect(() => store.sources.add(_src(2)), throwsUnsupportedError);
    });
  });

  group('url 索引（替掉 indexWhere）', () {
    test('indexOfUrl / byUrl / containsUrl 正确', () {
      final store = SourceStore();
      store.addAll([for (var i = 0; i < 1000; i++) _src(i)]);
      expect(store.indexOfUrl('https://example.com/500'), 500);
      expect(store.indexOfUrl('https://example.com/nope'), -1);
      expect(store.byUrl('https://example.com/7')?.bookSourceName, '书源 7');
      expect(store.byUrl('https://example.com/nope'), isNull);
      expect(store.containsUrl('https://example.com/999'), isTrue);
    });

    test('批量导入 1000 条只重建一次索引', () {
      final store = SourceStore();
      final before = store.debugIndexRebuildCount;
      store.addAll([for (var i = 0; i < 1000; i++) _src(i)]);
      // 首次构建 1 次 + 本次循环增量维护（不再扫表）
      expect(store.debugIndexRebuildCount - before, 1);
    });

    test('删除中间一条后索引不错位', () {
      final store = SourceStore();
      store.addAll([for (var i = 0; i < 100; i++) _src(i)]);
      store.remove('https://example.com/50');
      expect(store.indexOfUrl('https://example.com/51'), 50,
          reason: '下标要跟着前移，否则会取到错的源');
      expect(store.byUrl('https://example.com/51')?.bookSourceName, '书源 51');
      expect(store.byUrl('https://example.com/50'), isNull);
    });

    test('重复地址：更新而非重复添加', () {
      final store = SourceStore();
      final r1 = store.addAll([_src(1), _src(2)]);
      expect(r1.added, 2);
      expect(r1.updated, 0);
      final r2 = store.addAll([_src(1)]);
      expect(r2.added, 0);
      expect(r2.updated, 1);
      expect(store.sources.length, 2);
    });

    test('保留用户已改的启用状态', () {
      final store = SourceStore();
      store.addAll([_src(1)]);
      store.setEnabled('https://example.com/1', true);
      store.addAll([_src(1)]);
      expect(store.enabledCount, 1, reason: '重新导入不应把用户的开关冲掉');
    });
  });

  group('批量操作只通知一次', () {
    test('setEnabledAll / removeMany 各只发一次通知', () {
      final store = SourceStore();
      store.addAll([for (var i = 0; i < 200; i++) _src(i)]);
      var notified = 0;
      store.addListener(() => notified++);

      final changed = store.setEnabledAll(
          [for (var i = 0; i < 200; i++) 'https://example.com/$i'], true);
      expect(changed, 200);
      expect(notified, 1);
      expect(store.enabledCount, 200);

      notified = 0;
      final removed = store.removeMany(
          [for (var i = 0; i < 200; i++) 'https://example.com/$i']);
      expect(removed, 200);
      expect(notified, 1);
      expect(store.sources.length, 0);
    });
  });

  group('后台解析（导入 / 启动）', () {
    test('decodeSourcePayload：数组 / 单对象 / BOM / 坏数据 / 空', () {
      final one = decodeSourcePayload(jsonEncode(_srcJson(1)));
      expect((one['items'] as List).length, 1);

      final many = decodeSourcePayload(
          jsonEncode([_srcJson(1), _srcJson(2), _srcJson(3)]));
      expect((many['items'] as List).length, 3);
      expect(many['total'], 3);

      final bom = decodeSourcePayload('\uFEFF${jsonEncode(_srcJson(9))}');
      expect((bom['items'] as List).length, 1);

      final bad = decodeSourcePayload('not json');
      expect(bad['error'], isNotNull);

      final empty = decodeSourcePayload('   ');
      expect(empty['error'], isNotNull);

      // 缺 bookSourceUrl 的条目要剔掉
      final noUrl = decodeSourcePayload(jsonEncode([
        {'bookSourceName': '没有地址'},
        _srcJson(2)
      ]));
      expect((noUrl['items'] as List).length, 1);
    });

    test('decodeSourceSnapshotPayload：落盘结构（含 builtinSyncVersion）', () {
      final text = jsonEncode({
        'version': 1,
        'builtinSyncVersion': 3,
        'sources': [_srcJson(1), _srcJson(2)],
      });
      final parsed = decodeSourceSnapshotPayload(text);
      expect(parsed['builtinSyncVersion'], 3);
      expect((parsed['items'] as List).length, 2);
      expect(decodeSourceSnapshotPayload('坏文件')['items'], isEmpty);
    });

    test('importFromTextAsync：大 JSON 走后台 isolate 仍能正确导入', () async {
      final store = SourceStore();
      final text = jsonEncode([for (var i = 0; i < 1000; i++) _srcJson(i)]);
      final report = await store.importFromTextAsync(text);
      expect(report.hasAny, isTrue);
      expect(store.sources.length, 1000);
      expect(store.enabledCount, 0);
    });

    test('importFromText：同步路径结果一致', () {
      final store = SourceStore();
      final text = jsonEncode([for (var i = 0; i < 5; i++) _srcJson(i)]);
      final report = store.importFromText(text);
      expect(report.added, 5);
      expect(store.sources.length, 5);
    });
  });

  group('落盘与读回（1000 条往返）', () {
    test('写入后再 load，条数与内容一致', () async {
      final dir = await Directory.systemTemp.createTemp('sy_srcstore_');
      addTearDown(() async {
        if (await dir.exists()) await dir.delete(recursive: true);
      });
      final store = SourceStore(
          dirsOverride: AppDirs(files: dir.path, cache: dir.path));
      // 先 load 一次：落盘路径是在 load 里按 AppDirs 算出来的
      await store.load();
      store.addAll([for (var i = 0; i < 1000; i++) _src(i, enabled: i % 3 == 0)]);
      await store.flush();

      final store2 = SourceStore(
          dirsOverride: AppDirs(files: dir.path, cache: dir.path));
      await store2.load();
      expect(store2.sources.length, 1000);
      expect(store2.enabledCount, 1000 ~/ 3 + 1);
      expect(store2.indexOfUrl('https://example.com/999'), 999);
    });
  });
}
