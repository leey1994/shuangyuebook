// 低端机卡顿治理的回归测试（不依赖像素/帧率，只断言「不该发生的事」没发生）。
//
// 覆盖：
//   1. 导入书源登记表：改一条书源不该重建全部适配器（原来是每次全量重建 1000 个对象）；
//   2. allSources / sourceById 有缓存（原来每次访问都新建上千元素的列表）；
//   3. 阅读器时钟不再整页 setState（每秒只更新一个 ValueNotifier）。
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/screens/reader_screen.dart';
import 'package:shuangyue/sources/registry.dart';

BookSource _src(int i, {String name = ''}) => BookSource.fromJson({
      'bookSourceUrl': 'https://example.com/$i',
      'bookSourceName': name.isEmpty ? '书源 $i' : name,
      'enabled': true,
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('导入书源登记表', () {
    test('未变的书源复用适配器，改过的才重建', () {
      final a = _src(1);
      final b = _src(2);
      syncImportedSources([a, b]);
      final first = importedSources.toList();
      expect(first.length, 2);

      // 全部没变 → 适配器应当原样复用
      syncImportedSources([a, b]);
      final second = importedSources.toList();
      expect(identical(first[0], second[0]), isTrue,
          reason: '没变的书源不该重建适配器（1000 条时这是主要卡顿源）');
      expect(identical(first[1], second[1]), isTrue);

      // 改了一条 → 只有那一条重建
      final b2 = _src(2, name: '改名了');
      expect(identical(b, b2), isFalse);
      syncImportedSources([a, b2]);
      final third = importedSources.toList();
      expect(identical(first[0], third[0]), isTrue);
      expect(identical(first[1], third[1]), isFalse,
          reason: '内容变了必须重建');
    });

    test('allSources 有缓存（不再每次新建上千元素列表）', () {
      syncImportedSources([_src(1), _src(2)]);
      final l1 = allSources;
      final l2 = allSources;
      expect(identical(l1, l2), isTrue);
    });

    test('sourceById 走索引，结果正确', () {
      syncImportedSources([_src(1), _src(2)]);
      expect(sourceById('https://example.com/2')?.id, 'https://example.com/2');
      expect(sourceById('不存在的源'), isNull);
    });
  });

  group('阅读器时钟', () {
    test('页脚时间是独立的 ValueNotifier，不走整页 setState', () {
      // 用反射确认字段类型，避免测试和实现「同源同错」
      final f = ReaderScreen(
              book: const Book(
                sourceId: 's',
                id: 'b',
                title: 't',
                url: 'u',
              ),
              chapterIndex: 0)
          .createState();
      // 未挂载的 State 也能读字段（只是不要 build）
      final clock = (f as dynamic).debugClockText;
      expect(clock, isA<ValueListenable<String>>());
      expect(f, isA<State<ReaderScreen>>());    });
  });
}
