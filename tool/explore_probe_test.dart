import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

const _src = String.fromEnvironment('SRC');

void main() {
  test('JS exploreUrl 分类求值', () {
    final raw = File(_src).readAsStringSync();
    final decoded = jsonDecode(raw);
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final names = String.fromEnvironment('NAMES').split(',');
    for (final n in names) {
      final hit = items
          .cast<Map>()
          .where((e) => '${e['bookSourceName']}'.contains(n.trim()))
          .toList();
      for (final m in hit) {
        final s = BookSource.fromJson(Map<String, dynamic>.from(m));
        final cats = OnlineRepo.parseExploreCategories(s);
        print('=== ${s.bookSourceName} → ${cats.length} 类');
        for (final c in cats.take(6)) {
          print('   - ${c.title} | ${c.url}');
        }
      }
    }
  });
}
