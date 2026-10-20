import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/source_store.dart';

const _src = String.fromEnvironment('SRC');

void main() {
  test('异步补全发现分类', () async {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final repo = OnlineRepo(store: SourceStore(initial: items.cast<Map>().map((m) => BookSource.fromJson(Map<String, dynamic>.from(m))).toList()));
    final targets = <BookSource>[];
    for (final m in items.cast<Map>()) {
      final s = BookSource.fromJson(Map<String, dynamic>.from(m));
      final raw = (s.exploreUrl ?? '').trim();
      if (raw.isEmpty) continue;
      if (OnlineRepo.parseExploreCategories(s).isNotEmpty) continue;
      if (!OnlineRepo.hasJsExplore(s)) continue;
      targets.add(s);
    }
    print('待补全 ${targets.length} 源');
    for (final s in targets) {
      final sw = Stopwatch()..start();
      final cats = await repo.exploreCategoriesAsync(s);
      print('${s.bookSourceName} → ${cats.length} 类 '
          '(${sw.elapsedMilliseconds}ms) ${cats.take(4).map((c) => c.title).join("/")}');
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
