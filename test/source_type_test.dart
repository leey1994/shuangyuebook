// 非文本书源（bookSourceType 1 音频 / 2 图片）的边界行为：
//  - 导入 / 列表 / 详情都能看见，并带类型标签；
//  - 全链路测试不把它们算成「失败」，只判 skip；
//  - 阅读器打开时给明确提示（supportsTextReading=false）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/batch_tester.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/sources/legado_source.dart';

BookSource _src(int type) => BookSource.fromJson({
      'bookSourceUrl': 'https://example.com/$type',
      'bookSourceName': '测试源$type',
      'bookSourceType': type,
      'searchUrl': 'https://example.com/search?q={{key}}',
    });

void main() {
  test('类型标签对齐阅读 3.0 语义', () {
    expect(_src(0).typeLabel, '文本');
    expect(_src(1).typeLabel, '音频');
    expect(_src(2).typeLabel, '图片');
    expect(_src(7).typeLabel, '类型7');
    expect(_src(0).isTextSource, isTrue);
    expect(_src(1).isTextSource, isFalse);
  });

  test('非文本源不参与全链路测试，也不算失败', () async {
    final r = await BatchTester().testOne(_src(1));
    expect(r.search, 'skip');
    expect(r.isNonText, isTrue);
    expect(r.verdict, '非文本源');
    expect(r.failReason, contains('音频'));
    expect(r.fullOk, isFalse);
    // 诊断面板要能解释「为什么跳过」
    expect(r.log.join('\n'), contains('bookSourceType=1'));
  });

  test('缺 searchUrl 的源：诊断说清楚是「没有搜索入口」', () async {
    final s = BookSource.fromJson({
      'bookSourceUrl': 'https://example.com/nosearch',
      'bookSourceName': '无搜索源',
      'exploreUrl': 'https://example.com/rank',
    });
    final r = await BatchTester().testOne(s);
    expect(r.search, 'skip');
    expect(r.log.join('\n'), contains('searchUrl'));
  });

  test('阅读器能力：只有文本源支持打开', () {
    expect(LegadoSource(_src(0)).supportsTextReading, isTrue);
    expect(LegadoSource(_src(1)).supportsTextReading, isFalse);
    expect(LegadoSource(_src(2)).supportsTextReading, isFalse);
  });

  test('提示语能直接展示（不当成解析异常）', () {
    expect(const UnsupportedSourceTypeException(1).toString(), contains('音频'));
    expect(const UnsupportedSourceTypeException(2).toString(), contains('图片'));
    expect(const UnsupportedSourceTypeException(2).toString(), contains('换源'));
  });

  test('非文本源能正常导入仓库（不再被静默过滤）', () async {
    // 只验模型层：解析 + 序列化后类型不丢，供导入链路使用。
    final s = _src(2);
    final round = BookSource.fromJson(s.toJson());
    expect(round.bookSourceType, 2);
    expect(round.isTextSource, isFalse);
    expect(round.bookSourceName, '测试源2');
  });
}
