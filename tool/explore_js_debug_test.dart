import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';

const _src = String.fromEnvironment('SRC');
const _name = String.fromEnvironment('NAME');

void main() {
  test('debug explore js', () {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final m = items.cast<Map>().firstWhere(
        (e) => '${e['bookSourceName']}'.contains(_name),
        orElse: () => <String, dynamic>{});
    final s = BookSource.fromJson(Map<String, dynamic>.from(m));
    final raw = (s.exploreUrl ?? '').trim();
    print('RAW head: ${raw.substring(0, raw.length > 200 ? 200 : raw.length)}');
    final low = raw.toLowerCase();
    final body = low.startsWith('@js:')
        ? raw.substring(4)
        : (low.startsWith('<js>') && low.endsWith('</js>')
            ? raw.substring(4, raw.length - 5)
            : '');
    if (body.isEmpty) {
      print('NOT JS');
      return;
    }
    final env = JsEnv(
      scopeKey: s.bookSourceUrl,
      sourceUrl: s.bookSourceUrl,
      sourceName: s.bookSourceName,
      sourceHeader: s.header,
      sourceJson: s.jsSourceFields,
      jsLib: s.jsLib,
    );
    try {
      final wrapped = 'JSON.stringify((function(){ $body\n })'
          ".call((typeof source === 'object' && source) ? source : globalThis))";
      final out = JsBridge.evalCode(wrapped, env: env);
      print('OUT type=${out.runtimeType} len=${out == null ? -1 : out.length}');
      print('OUT head=${out == null ? "null" : out.substring(0, out.length > 300 ? 300 : out.length)}');
    } catch (e) {
      print('THROWN: $e');
      print('lastError=${JsBridge.lastError}');
    }
  });
}
