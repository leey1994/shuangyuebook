// 正文诊断：跑完整链路（搜索→详情→首章）并把首章 HTML 存盘。
//
//   flutter test tool/dump_content_test.dart -r expanded \
//     --dart-define=SRC=..\review\merged126.json \
//     --dart-define=NAMES=多看阅读 --dart-define=KEY=斗破苍穹 \
//     --dart-define=OUT=..\review\dump
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/sources/legado_source.dart';

const _src = String.fromEnvironment('SRC');
const _names = String.fromEnvironment('NAMES');
const _key = String.fromEnvironment('KEY', defaultValue: '斗破苍穹');
const _out = String.fromEnvironment('OUT', defaultValue: 'build/dump');

void main() {
  test('dump chapter html', () async {
    final decoded = jsonDecode(File(_src).readAsStringSync());
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final want =
        _names.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
    Directory(_out).createSync(recursive: true);
    final svc = OnlineBookService();

    for (final rawSrc in items) {
      final m = rawSrc as Map;
      final name = (m['bookSourceName'] ?? '').toString();
      if (!want.any((w) => name.contains(w))) continue;
      final source = BookSource.fromJson(m.cast<String, dynamic>());
      print('\n=== $name ===');
      print('bookSourceUrl: ${source.bookSourceUrl}');
      print('chapterUrl: ${source.tocRule?.chapterUrl}');
      print('ruleContent.content: ${source.contentRule?.content}');
      try {
        final books = await LegadoSource(source).search(_key);
        print('搜索结果 ${books.length}');
        if (books.isEmpty) continue;
        final b = books.firstWhere((x) => x.url.startsWith('http'),
            orElse: () => books.first);
        print('书目：${b.title} / ${b.url}');
        final info = await svc.fetchInfo(source, b.url);
        print('目录 ${info.chapters.length} 章');
        if (info.chapters.isEmpty) continue;
        final ch = info.chapters.first;
        print('首章：${ch.title} / ${ch.url}');
        final html = await svc.fetchChapterHtml(source, ch.url, book: {
          'name': b.title,
          'author': b.author ?? '',
          'durChapterTitle': ch.title,
        });
        final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
        File('$_out/${safe}_ch.html').writeAsStringSync(html);
        print('HTML 长度 ${html.length}');
        final t = html.length > 300 ? html.substring(0, 300) : html;
        print('片段：$t');
        final text = await svc.fetchChapterText(source, ch.url, book: {
          'name': b.title,
          'author': b.author ?? '',
          'durChapterTitle': ch.title,
        });
        print('正文长度 ${text.replaceAll(RegExp(r'\s+'), '').length}');
      } catch (e, st) {
        print('失败：$e');
        print(st.toString().split('\n').take(6).join('\n'));
      }
    }
  });
}
