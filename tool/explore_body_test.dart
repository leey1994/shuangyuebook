import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';

const _src = String.fromEnvironment('SRC');
const _name = String.fromEnvironment('NAME');

void main() {
  test('直接 eval 脚本体', () {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final m = items.cast<Map>().firstWhere(
        (e) => '${e['bookSourceName']}'.contains(_name),
        orElse: () => <String, dynamic>{});
    final s = BookSource.fromJson(Map<String, dynamic>.from(m));
    final raw = (s.exploreUrl ?? '').trim();
    final low = raw.toLowerCase();
    final body = low.startsWith('@js:')
        ? raw.substring(4)
        : (low.startsWith('<js>') && low.endsWith('</js>')
            ? raw.substring(4, raw.length - 5)
            : '');
    print('BODY len=${body.length}');
    final env = JsEnv(
      scopeKey: s.bookSourceUrl,
      sourceUrl: s.bookSourceUrl,
      sourceName: s.bookSourceName,
      sourceHeader: s.header,
      sourceJson: s.jsSourceFields,
      jsLib: s.jsLib,
    );
    final out = JsBridge.evalCode(body, env: env);
    final head = raw.length > 60 ? raw.substring(0, 60) : raw;
    print('RAW len=${raw.length} head=${head.replaceAll("\n", "<n>")}');
    print('OUT=${out == null ? "null" : out.substring(0, out.length > 300 ? 300 : out.length).replaceAll("\n", "<n>")}');
    print('LAST=${JsBridge.lastError}');
  });
}
