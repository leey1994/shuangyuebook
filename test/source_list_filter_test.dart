// 书源搜索/过滤状态机：防抖 + 结果缓存。
//
// 1000+ 条书源时，「每敲一个字符就全表 where + 排序」会连续丢帧。
// 这里保证：连续输入只算一次、结果没变就复用同一份列表。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/ui/source/source_list_filter.dart';

BookSource _src(int i, {bool enabled = false, String name = '', String url = ''}) =>
    BookSource.fromJson({
      'bookSourceUrl': url.isEmpty ? 'https://example.com/$i' : url,
      'bookSourceName': name.isEmpty ? '书源 $i' : name,
      'bookSourceGroup': i.isEven ? '偶数组' : '奇数组',
      'enabled': enabled,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('防抖', () {
    test('连续输入只在停顿后生效一次', () async {
      final f = SourceListFilter(debounce: const Duration(milliseconds: 50));
      var applied = 0;
      f.onInput('书', () => applied++);
      f.onInput('书源', () => applied++);
      f.onInput('书源 1', () => applied++);
      expect(applied, 0, reason: '还没到防抖时间，不该重建列表');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(applied, 1);
      expect(f.query, '书源 1');
      f.dispose();
    });

    test('清空立即生效（不用等防抖）', () async {
      final f = SourceListFilter(debounce: const Duration(milliseconds: 30));
      var applied = 0;
      f.onInput('abc', () => applied++);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(applied, 1);
      f.onInput('', () => applied++);
      expect(applied, 2, reason: '清空要立刻恢复全表，不等防抖');
      expect(f.query, '');
      f.dispose();
    });

    test('输入还没生效就清空 → 不必重建列表', () async {
      final f = SourceListFilter(debounce: const Duration(seconds: 5));
      var applied = 0;
      f.onInput('abc', () => applied++);
      f.onInput('', () => applied++);
      expect(applied, 0, reason: '列表本来就没被筛过，不用重建');
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(applied, 0, reason: '被撤掉的防抖不能再触发');
      f.dispose();
    });

    test('重复的查询词不重复触发', () async {
      final f = SourceListFilter(debounce: const Duration(milliseconds: 30));
      var applied = 0;
      f.onInput('x', () => applied++);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(applied, 1);
      f.onInput('x', () => applied++);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(applied, 1, reason: '查询词没变就不该再算一遍');
      f.dispose();
    });
  });

  group('结果缓存', () {
    test('条件与视图都没变时复用同一份结果', () {
      final f = SourceListFilter();
      final view = [for (var i = 0; i < 1000; i++) _src(i)];
      final r1 = f.apply(view);
      final r2 = f.apply(view);
      expect(identical(r1, r2), isTrue);
      expect(f.debugComputeCount, 1);
      f.dispose();
    });

    test('不过滤时零拷贝（结果就是原视图）', () {
      final f = SourceListFilter();
      final view = [for (var i = 0; i < 10; i++) _src(i)];
      expect(identical(f.apply(view), view), isTrue);
      f.dispose();
    });

    test('过滤命中名称 / 地址 / 分组，且大小写不敏感', () async {
      final f = SourceListFilter(debounce: const Duration(milliseconds: 20));
      final view = [
        _src(1, name: '笔趣阁'),
        _src(2, name: 'TXT小说', url: 'https://txt.example.com/x'),
        _src(3),
      ];
      expect(f.apply(view).length, 3, reason: '没有条件时是全表');
      f.onInput('笔趣', () {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(f.apply(view).length, 1);
      f.onInput('txt', () {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(f.apply(view).length, 1);
      f.onInput('偶数', () {});
      await Future<void>.delayed(const Duration(milliseconds: 60));
      expect(f.apply(view).length, 1);
      f.dispose();
    });

    test('「仅看已启用」叠加在查询词之上', () {
      final f = SourceListFilter();
      final view = [
        _src(1, name: '甲', enabled: true),
        _src(2, name: '甲乙'),
      ];
      f.setEnabledOnly(true, () {});
      final r = f.apply(view);
      expect(r.length, 1);
      expect(r.first.bookSourceName, '甲');
      f.dispose();
    });

    test('reset 清空条件后回到原视图', () {
      final f = SourceListFilter();
      final view = [for (var i = 0; i < 5; i++) _src(i)];
      f.onInput('书源 1', () {});
      f.setEnabledOnly(true, () {});
      f.apply(view);
      f.reset();
      expect(f.isActive, isFalse);
      expect(f.apply(view).length, 5);
      f.dispose();
    });
  });
}
