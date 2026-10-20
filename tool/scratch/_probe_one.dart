// 单源全链诊断探针（P1 排障用，非回归套件）。
//
// 用法（git-bash）：
//   LIBQUICKJSC_TEST_PATH=... PROBE_SRC=塔读 PROBE_KEY=斗破苍穹 \
//     flutter test test/_probe_one.dart --no-pub
//
// 打印：搜索命中 → 详情/目录页 URL → 原始响应头部 → chapterList 规则直评
//       结果 → 服务层 fetchInfo 目录数。用于定位 toc=empty 族的失败环节。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/analyze_rule.dart';
import 'package:shuangyue/legado/analyze_url.dart';
import 'package:shuangyue/legado/http_client.dart';
import 'package:shuangyue/legado/js_engine.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/source_fetcher.dart';
import 'package:shuangyue/legado/source_store.dart';

void main() {
  test('probe one source', () async {
    final needle = Platform.environment['PROBE_SRC'] ?? '塔读';
    final key = Platform.environment['PROBE_KEY'] ?? '斗破苍穹';
    final text = File(
      'C:/Users/leey1/Desktop/A/A1/shuangyue/build/dist/重点测试书源.json',
    ).readAsStringSync();
    final all = parseSourceCollection(text);
    final src = all.firstWhere(
      (s) =>
          s.bookSourceName.contains(needle) ||
          s.bookSourceUrl.contains(needle),
      orElse: () => throw StateError('no source matches $needle'),
    );
    print('SRC=${src.bookSourceName} | ${src.bookSourceUrl}');

    final repo = OnlineRepo(store: SourceStore(initial: [src]));
    final res = await repo.searchOne(src, key);
    print('SEARCH ok=${res.ok} n=${res.books.length} err=${res.error}');
    for (final b in res.books.take(3)) {
      print('  BOOK name=${b.name} url=${b.bookUrl} tocUrl=${b.tocUrl}');
    }
    final withUrl =
        res.books.where((b) => (b.bookUrl ?? '').isNotEmpty).toList();
    if (withUrl.isEmpty) {
      print('NO_BOOK_URL');
      return;
    }
    final pick = withUrl.first;
    final pageUrl =
        (pick.tocUrl ?? '').isNotEmpty ? pick.tocUrl! : pick.bookUrl!;
    print('PICK name=${pick.name} page=$pageUrl');

    final client = SourceHttpClient();
    final resp =
        await client.get(pageUrl, headers: OnlineBookService.headerMap(src));
    final body = resp.body;
    final headLen = body.length < 500 ? body.length : 500;
    print('HTTP ${resp.statusCode} len=${body.length} final=${resp.finalUrl}');
    print('HEAD: ${body.substring(0, headLen).replaceAll(RegExp(r'\s+'), ' ')}');

    final eng = AnalyzeRule(body, baseUrl: pageUrl);
    final rt = src.tocRule;
    print('TOC.list=${rt?.chapterList}');
    final raw = eng.getStrings(rt?.chapterList ?? '');
    print('CH_LIST_COUNT=${raw.length}');
    for (final n in raw.take(3)) {
      print('  ITEM: ${n.length > 80 ? n.substring(0, 80) : n}');
    }
    print('TOC.name=${rt?.chapterName}');
    print('TOC.url=${rt?.chapterUrl}');

    // tocUrl 规则直评（定位服务层“详情页无目录→tocUrl 单独请求”环节）
    final tocUrlRule = src.bookInfoRule?.tocUrl;
    if (tocUrlRule != null && tocUrlRule.trim().isNotEmpty) {
      // 与服务层同口径：单一 JsSession 贯穿（java.put/@get、init 覆盖）。
      final session = JsSession();
      final env = OnlineBookService.jsEnvFor(src, session);
      final eng2 = AnalyzeRule(
        body,
        baseUrl: pageUrl,
        js: env,
        vars: {
          'book': <String, dynamic>{
            'bookUrl': pageUrl,
            'name': pick.name ?? '',
            'author': pick.author ?? '',
            'kind': pick.kind ?? '',
          },
        },
      );
      final initRule = src.bookInfoRule?.init?.trim();
      if (initRule != null && initRule.isNotEmpty) {
        final ir = eng2.getRawElement(initRule);
        if (ir != null) eng2.setContentObject(ir);
      }
      // 与服务层同口径：isUrl 首值语义 + 相对地址按详情页解析
      final tuRaw = eng2.getString(tocUrlRule, isUrl: true);
      final tu = (tuRaw == null || tuRaw.isEmpty) ? null : resolveUrl(tuRaw, pageUrl);
      print('TOCURL_EVAL=${tu?.replaceAll(RegExp(r'\s+'), ' ')}');
      if (tu != null && tu.isNotEmpty && tu != pageUrl) {
        try {
          final resp2 =
              await client.get(tu, headers: OnlineBookService.headerMap(src));
          print('TOC_PAGE HTTP ${resp2.statusCode} len=${resp2.body.length}');
          final eng3 = AnalyzeRule(resp2.body,
              baseUrl: tu,
              js: OnlineBookService.jsEnvFor(src, session));
          final names3 = eng3.getStrings(rt?.chapterList ?? '');
          print('TOC_PAGE_CH_COUNT=${names3.length}');
          print('XP_DIAG //li=${eng3.getStrings('//li').length} '
              '//li[span]=${eng3.getStrings('//li[span]').length} '
              '//a=${eng3.getStrings('//a').length}');
          for (final n in names3.take(2)) {
            print('  TOC_CH: ${n.length > 60 ? n.substring(0, 60) : n}');
          }
          // 服务层同口径复算（parseChapters 对每个条目做二级求值）
          final chapters2 =
              OnlineBookService.parseChapters(eng3, rt!, tu);
          print('MANUAL_PARSE=${chapters2.length}');
          for (final c in chapters2.take(2)) {
            print('  MP ${c.title} | ${c.url}');
          }
        } catch (e) {
          print('TOC_PAGE_ERR $e');
        }
      }
    }

    try {
      final info = await OnlineBookService()
          .fetchInfo(src, pick.bookUrl!)
          .timeout(const Duration(seconds: 40));
      print('SVC chapters=${info.chapters.length} name=${info.name}');
      for (final c in info.chapters.take(3)) {
        print('  CH ${c.title} | ${c.url}');
      }
      // 正文链：取第 1 章实测（含请求选项/WebView 派发）
      if (info.chapters.isNotEmpty) {
        try {
          final text = await OnlineBookService()
              .fetchChapterText(
                src,
                info.chapters.first.url,
                book: <String, dynamic>{
                  'name': pick.name ?? '',
                  'author': pick.author ?? '',
                  'bookUrl': pick.bookUrl ?? '',
                  'tocUrl': (pick.tocUrl ?? '').isNotEmpty
                      ? pick.tocUrl!
                      : pick.bookUrl!,
                  'durChapterTitle': info.chapters.first.title,
                },
              )
              .timeout(const Duration(seconds: 40));
          print('CONTENT len=${text.length}');
          print('CONTENT_HEAD ${text.substring(0, text.length.clamp(0, 120)).replaceAll('\n', ' ⏎ ')}');
        } catch (e) {
          print('CONTENT_ERR $e');
        }
      }
    } catch (e) {
      print('SVC_ERR $e');
    }
  }, timeout: const Timeout(Duration(minutes: 4)));
}
