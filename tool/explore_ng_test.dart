import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_repo.dart';

const _src = String.fromEnvironment('SRC');

void main() {
  test('explore NG 诊断', () {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    for (final m in items.cast<Map>()) {
      final s = BookSource.fromJson(Map<String, dynamic>.from(m));
      final raw = (s.exploreUrl ?? '').trim();
      if (raw.isEmpty) continue;
      if (OnlineRepo.parseExploreCategories(s).isNotEmpty) continue;
      final low = raw.toLowerCase();
      final isJs =
          low.startsWith('@js:') || (low.startsWith('<js>') && low.endsWith('</js>'));
      print('NG ${s.bookSourceName} | js=$isJs');
      if (!isJs) {
        try {
          jsonDecode(raw);
          print('   strict JSON ok（但解析后无分类）');
        } catch (e) {
          print('   strict: $e');
          final loose = OnlineRepo.debugLenientJson(raw);
          if (loose == null) {
            print('   lenient: null');
          } else {
            try {
              jsonDecode(loose);
              print('   lenient ok（但解析后无分类）len=${loose.length}');
            } catch (e2) {
              print('   lenient: $e2');
              final msg = '$e2';
              final m2 = RegExp(r'character (\d+)').firstMatch(msg);
              final at = int.tryParse(m2?.group(1) ?? '');
              if (at != null && at < loose.length) {
                final from = (at - 60).clamp(0, loose.length);
                final to = (at + 60).clamp(0, loose.length);
                print('   @${at}: ${loose.substring(from, to).replaceAll("\n", r'\n')}');
              }
            }
          }
        }
      } else {
        print('   lastError=${JsBridge.lastError}');
      }
    }
  });
}
