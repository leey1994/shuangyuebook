// 详情页诊断：搜索→取首本→拉详情→逐字段打印（书源详情规则为何空）。
//
//   flutter test tool/dump_detail_test.dart -r expanded \
//     --dart-define=SRC=..\review\merged126.json --dart-define=NAMES=猫眼看书,搬山人
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/sources/legado_source.dart';

const _src = String.fromEnvironment('SRC');
const _names = String.fromEnvironment('NAMES');
const _key = String.fromEnvironment('KEY', defaultValue: '凡人修仙传');

void main() {
  test('dump detail', () async {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final want = _names
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    for (final rawSrc in items) {
      final m = rawSrc as Map;
      final name = (m['bookSourceName'] ?? '').toString();
      if (!want.any((w) => name.contains(w))) continue;
      final s = BookSource.fromJson(m.cast<String, dynamic>());
      final r = s.bookInfoRule;
      print('\n=== $name ===');
      for (final e in <String, String?>{
        'init': r?.init,
        'name': r?.name,
        'author': r?.author,
        'cover': r?.coverUrl,
        'intro': r?.intro,
        'kind': r?.kind,
        'lastChapter': r?.lastChapter,
        'tocUrl': r?.tocUrl,
      }.entries) {
        final v = e.value;
        if (v == null || v.trim().isEmpty) continue;
        final one = v.replaceAll('\n', ' ');
        print('  ${e.key}: ${one.length > 110 ? '${one.substring(0, 110)}…' : one}');
      }
      try {
        final books = await LegadoSource(s).search(_key);
        print('搜索结果 ${books.length}');
        if (books.isEmpty) continue;
        final b = books.firstWhere((x) => x.url.startsWith('http'),
            orElse: () => books.first);
        print('书目：${b.title} / ${b.author} / ${b.url}');
        JsBridge.lastError = null;
        final info = await OnlineBookService().fetchInfo(s, b.url);
        final nm = info.name ?? '';
        final au = info.author ?? '';
        final cv = info.coverUrl ?? '';
        final it = info.intro ?? '';
        print('→ name=${nm.isEmpty ? "空" : nm} '
            'author=${au.isEmpty ? "空" : au} '
            'cover=${cv.isEmpty ? "空" : "有"} '
            'intro=${it.isEmpty ? "空" : "${it.length}字"} '
            'chapters=${info.chapters.length}');
        print('jsErr=${JsBridge.lastError?.split('\n').first}');
      } catch (e) {
        print('失败：$e');
      }
    }
  }, timeout: const Timeout(Duration(minutes: 8)));
}
