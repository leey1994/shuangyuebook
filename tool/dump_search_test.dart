// 搜索页诊断：抓 HTML 存盘 + 报规则命中明细（离线复盘用，不参与回归）。
//
// 用法：
//   flutter test tool/dump_search_test.dart -r expanded \
//     --dart-define=SRC=..\review\merged126.json \
//     --dart-define=NAMES=魔丸小说,顶点小说 --dart-define=KEY=斗破苍穹 \
//     --dart-define=OUT=..\review\dump
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/source_store.dart';

const _src = String.fromEnvironment('SRC');
const _names = String.fromEnvironment('NAMES');
const _key = String.fromEnvironment('KEY', defaultValue: '斗破苍穹');
const _out = String.fromEnvironment('OUT', defaultValue: 'build/dump');

void main() {
  test('dump search pages', () async {
    final raw = File(_src).readAsStringSync();
    final decoded = jsonDecode(raw);
    final items = decoded is List
        ? decoded
        : (decoded as Map)['sources'] as List? ?? decoded['data'] as List;
    final want =
        _names.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty);
    Directory(_out).createSync(recursive: true);
    final repo = OnlineRepo(store: SourceStoreStub());
    final client = SourceHttpClient();

    for (final rawSrc in items) {
      final m = rawSrc as Map;
      final name = (m['bookSourceName'] ?? '').toString();
      if (!want.any((w) => name.contains(w))) continue;
      final source = BookSource.fromJson(m.cast<String, dynamic>());
      final session = JsSession();
      final env = OnlineRepo.jsEnvFor(source, session);

      print('\n=== $name ===');
      print('searchUrl: ${source.searchUrl}');
      var body = '';
      var finalUrl = '';
      try {
        var req = buildRequest(source.searchUrl ?? '', source.bookSourceUrl, {
          'key': _key,
          'page': 1,
        }, js: env);
        for (var round = 0; round < 3; round++) {
          try {
            final method =
                (req.options['method']?.toString() ?? 'GET').toUpperCase();
            final headers = <String, String>{
              ...OnlineBookService.headerMap(source),
              ...?(req.options['headers'] as Map?)?.map(
                (k, v) => MapEntry(k.toString(), v.toString()),
              ),
            };
            final resp = method == 'POST'
                ? await client.post(req.url,
                    headers: headers,
                    body: req.options['body']?.toString() ?? '',
                    charset: req.options['charset']?.toString(),
                    timeout: const Duration(seconds: 20))
                : await client.get(req.url,
                    headers: headers,
                    charset: req.options['charset']?.toString(),
                    timeout: const Duration(seconds: 20));
            body = resp.body;
            finalUrl = resp.finalUrl;
            print('HTTP ${resp.statusCode} len=${body.length} url=$finalUrl');
            break;
          } on JsSuspendException catch (e) {
            print('  挂起 ${e.kind} → ${e.target}');
            final r = e.method == 'GET'
                ? await client.get(e.target,
                    timeout: const Duration(seconds: 20))
                : await client.post(e.target,
                    body: e.body ?? '', timeout: const Duration(seconds: 20));
            final k = JsBridge.ajaxKey(e.method, e.target, e.body);
            session.ajaxCache[k] = r.body;
            session.ajaxMeta[k] = {
              'code': r.statusCode,
              'url': r.finalUrl,
              'headers': const <String, String>{},
            };
            req = buildRequest(source.searchUrl ?? '', source.bookSourceUrl, {
              'key': _key,
              'page': 1,
            }, js: env);
          }
        }
      } catch (e) {
        print('请求失败：$e');
      }

      final safe = name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
      if (body.isNotEmpty) {
        File('$_out/$safe.html').writeAsStringSync(body);
      }

      final parsed = repo.parseSearchPageDetailed(source, body,
          js: env, pageUrl: finalUrl.isEmpty ? null : finalUrl);
      print('rows=${parsed.rows} noUrl=${parsed.noUrl} '
          'books=${parsed.books.length}'
          '${parsed.books.isEmpty ? '' : ' 首条=${parsed.books.first.name}'}');
      final bl = source.searchRule?.bookList?.trim() ?? '';
      print('bookList: $bl');
      if (body.isNotEmpty && bl.isNotEmpty) {
        final engine = AnalyzeRule(body,
            baseUrl: finalUrl.isEmpty ? source.bookSourceUrl : finalUrl,
            js: env);
        try {
          final raw = engine.getRawList(bl);
          print('getRawList 长度=${raw.length} 首元素类型='
              '${raw.isEmpty ? '-' : raw.first.runtimeType}');
        } catch (e) {
          print('getRawList 抛错：$e');
        }
        final rows = engine.getElements(bl);
        print('bookList 命中行数：${rows.length}');
        if (rows.isEmpty) {
          print('页面标题：${RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(body)?.group(1)?.trim()}');
          print('页面片段：${body.length > 240 ? body.substring(0, 240) : body}');
        }
      }
    }
    client.close();
  });
}

/// 诊断脚本只需要一个占位 store（不读本地书源库）。
class SourceStoreStub implements SourceStore {
  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
