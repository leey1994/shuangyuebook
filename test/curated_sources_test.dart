// 内置精选书源资产回归：存在、可解析、「阅读 3.0」格式字段齐全、地址唯一。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/source_fetcher.dart';

void main() {
  test('内置精选书源资产完整可用', () {
    final f = File('assets/sources/curated_sources.json');
    expect(f.existsSync(), isTrue, reason: '资产文件缺失');
    final list = parseSourceCollection(f.readAsStringSync());
    expect(list.length, greaterThanOrEqualTo(50));
    final urls = <String>{};
    for (final s in list) {
      expect(s.bookSourceName.trim(), isNotEmpty);
      expect(s.bookSourceUrl.trim(), isNotEmpty);
      expect(urls.add(s.bookSourceUrl), isTrue,
          reason: '书源地址重复：${s.bookSourceUrl}');
    }
  });
}
