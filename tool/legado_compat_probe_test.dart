// 「阅读 3.0」书源批量兼容性探针（真实网络）。
//
// 对每个书源跑全链路：搜索（含双关键词兜底）→ 详情/目录 → 首章正文 → 发现页，
// 并在开始前做静态规则扫描（@js / java. / webView / POST 搜索 / 登录等），
// 输出 JSONL（每源一行），供离线脚本出兼容性报告。
//
// 运行：
//   flutter test tool/legado_compat_probe_test.dart -r expanded \
//     --dart-define=SRC=<sample_all.json> --dart-define=OUT=<results.jsonl>
// 可选参数：
//   N=并发数（默认 8）   T=单阶段超时秒（默认 15）
//   K1/K2=搜索关键词（默认 斗破苍穹 / 凡人修仙传）   LIMIT=只跑前 N 条
// ignore_for_file: avoid_print
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/sources/legado_source.dart';

/// JS 依赖特征（规则里出现即视为「需要 JS 引擎」）。
const _jsMarkers = ['@js:', '<js', 'java.'];

bool _hasJs(String? s) {
  if (s == null || s.isEmpty) return false;
  final l = s.toLowerCase();
  return _jsMarkers.any(l.contains);
}

/// 递归扫描规则字段：返回命中 JS 特征的字段路径。
List<String> _scanJs(dynamic v, String path, List<String> acc) {
  if (v is String) {
    if (_hasJs(v)) acc.add(path);
  } else if (v is Map) {
    v.forEach((k, x) => _scanJs(x, '$path.$k', acc));
  } else if (v is List) {
    for (var i = 0; i < v.length; i++) {
      _scanJs(v[i], '$path[$i]', acc);
    }
  }
  return acc;
}

String _brief(Object e) {
  var s = e.toString();
  if (s.startsWith('Exception: ')) s = s.substring(11);
  return s.length > 90 ? '${s.substring(0, 90)}…' : s;
}

void main() {
  test('legado batch compat probe', () async {
    const srcPath = String.fromEnvironment('SRC');
    const outPath = String.fromEnvironment('OUT');
    const conc = int.fromEnvironment('N', defaultValue: 8);
    const tSec = int.fromEnvironment('T', defaultValue: 15);
    const limit = int.fromEnvironment('LIMIT', defaultValue: 0);
    const k1 = String.fromEnvironment('K1', defaultValue: '斗破苍穹');
    const k2 = String.fromEnvironment('K2', defaultValue: '凡人修仙传');
    expect(srcPath.isNotEmpty, isTrue, reason: '缺少 --dart-define=SRC');
    expect(outPath.isNotEmpty, isTrue, reason: '缺少 --dart-define=OUT');

    var all = (jsonDecode(await File(srcPath).readAsString()) as List)
        .cast<Map>();
    if (limit > 0 && all.length > limit) all = all.sublist(0, limit);

    final outFile = File(outPath);
    await outFile.writeAsString('');
    // 串行化写入，避免并发行互相穿插
    Future<void> wq = Future.value();
    void emit(Map<String, dynamic> rec) {
      final line = jsonEncode(rec);
      wq = wq.then(
        (_) => outFile.writeAsString('$line\n', mode: FileMode.append, flush: true),
      );
    }

    const timeout = Duration(seconds: tSec);
    var next = 0;
    var done = 0;
    final t0 = DateTime.now();

    Future<void> one(int i) async {
      final raw = all[i];
      final name = (raw['bookSourceName'] ?? '').toString();
      final url = (raw['bookSourceUrl'] ?? '').toString();
      final rec = <String, dynamic>{
        'i': i,
        'name': name,
        'url': url,
        'origin': raw['__origin'],
        'idx': raw['__idx'],
        'type': raw['bookSourceType'] is int ? raw['bookSourceType'] : 0,
        'enabled': raw['enabled'] != false,
        'stat': {
          'jsSearch': _scanJs(raw['searchUrl'], 'searchUrl', [])
            ..addAll(_scanJs(raw['ruleSearch'], 'ruleSearch', [])),
          'jsInfo': _scanJs(raw['ruleBookInfo'], 'ruleBookInfo', []),
          'jsToc': _scanJs(raw['ruleToc'], 'ruleToc', []),
          'jsContent': _scanJs(raw['ruleContent'], 'ruleContent', []),
          'jsExplore': _scanJs(raw['exploreUrl'], 'exploreUrl', [])
            ..addAll(_scanJs(raw['ruleExplore'], 'ruleExplore', [])),
          'webView': raw['webView'] == true,
          'gateway': (raw['gatewayPath']?.toString() ?? '').isNotEmpty,
          'searchPost': (raw['searchUrl']?.toString().toLowerCase() ?? '')
              .contains('"method":"post"'),
          'login': (raw['loginUrl']?.toString() ?? '').isNotEmpty,
          'header': (raw['header']?.toString() ?? '').isNotEmpty,
          'group': (raw['bookSourceGroup'] ?? '').toString(),
        },
      };

      final type = rec['type'] as int;
      if (type != 0) {
        rec['skipped'] = 'non_text_type_$type';
        emit(rec);
        return;
      }

      BookSource? bs;
      try {
        bs = BookSource.fromJson(raw);
      } catch (e) {
        rec['parse_error'] = _brief(e);
      }
      if (bs == null) {
        emit(rec);
        return;
      }

      final ls = LegadoSource(bs);
      final svc = OnlineBookService();

      // ---------- 搜索（空结果时换关键词兜底） ----------
      var bookUrl = '';
      var bookTitle = '';
      var bookAuthor = '';
      final sw = Stopwatch()..start();
      String? searchErr;
      var n = 0;
      var usedKw = k1;
      try {
        var books = await ls.search(k1).timeout(timeout);
        if (books.isEmpty) {
          usedKw = k2;
          books = await ls.search(k2).timeout(timeout);
        }
        n = books.length;
        if (books.isNotEmpty) {
          final b = books.firstWhere(
            (x) => x.url.startsWith('http'),
            orElse: () => books.first,
          );
          bookUrl = b.url;
          bookTitle = b.title;
          bookAuthor = b.author ?? '';
        }
      } catch (e) {
        searchErr = _brief(e);
      }
      rec['search'] = {
        'status': searchErr != null ? 'err' : (n > 0 ? 'ok' : 'empty'),
        'error': searchErr,
        'n': n,
        'ms': sw.elapsedMilliseconds,
        'kw': usedKw,
        'title': bookTitle,
        'author': bookAuthor,
      };

      // ---------- 详情 / 目录 ----------
      String? firstChapterUrl;
      var firstChapterTitle = '';
      var chapters = 0;
      if (bookUrl.isNotEmpty) {
        final sw2 = Stopwatch()..start();
        String? derr;
        try {
          final info = await svc.fetchInfo(bs, bookUrl).timeout(timeout);
          chapters = info.chapters.length;
          if (info.chapters.isNotEmpty) {
            firstChapterUrl = info.chapters.first.url;
            firstChapterTitle = info.chapters.first.title;
          }
        } catch (e) {
          derr = _brief(e);
        }
        rec['detail'] = {
          'status': derr != null ? 'err' : (chapters > 0 ? 'ok' : 'empty'),
          'error': derr,
          'chapters': chapters,
          'ms': sw2.elapsedMilliseconds,
        };
      } else if (searchErr == null) {
        rec['detail'] = {'status': 'no_url'};
      }

      // ---------- 首章正文 ----------
      if (firstChapterUrl != null) {
        final sw3 = Stopwatch()..start();
        String? cerr;
        var chars = 0;
        var gib = 0;
        try {
          final text = await svc
              .fetchChapterText(
                bs,
                firstChapterUrl,
                book: {
                  'name': bookTitle,
                  'author': bookAuthor,
                  'durChapterTitle': firstChapterTitle,
                },
              )
              .timeout(timeout);
          final flat = text.replaceAll(RegExp(r'\s+'), '');
          chars = flat.length;
          gib = RegExp(r'[銆绗鈥锛鐨鏄鐞鎾]').allMatches(flat).length;
        } catch (e) {
          cerr = _brief(e);
        }
        rec['content'] = {
          'status': cerr != null
              ? 'err'
              : (chars < 80 ? 'short' : (gib >= 3 ? 'gibberish' : 'ok')),
          'error': cerr,
          'chars': chars,
          'gib': gib,
          'ms': sw3.elapsedMilliseconds,
        };
      } else if (rec['detail'] != null) {
        rec['content'] = {'status': 'skip'};
      }

      // ---------- 发现页 ----------
      try {
        final tabs = await ls.fetchRankTabs().timeout(timeout);
        if (tabs.isNotEmpty) {
          final sw4 = Stopwatch()..start();
          String? eerr;
          var en = 0;
          try {
            final p = await ls.fetchRank(tabs.first).timeout(timeout);
            en = p.items.length;
          } catch (e) {
            eerr = _brief(e);
          }
          rec['explore'] = {
            'status': eerr != null ? 'err' : (en > 0 ? 'ok' : 'empty'),
            'error': eerr,
            'n': en,
            'tabs': tabs.length,
            'ms': sw4.elapsedMilliseconds,
          };
        } else if ((rec['stat']['jsExplore'] as List).isNotEmpty) {
          rec['explore'] = {'status': 'js_required'};
        } else {
          rec['explore'] = {'status': 'none'};
        }
      } catch (e) {
        rec['explore'] = {'status': 'err', 'error': _brief(e)};
      }

      emit(rec);
      print('[$i] $name → 搜索=${rec['search']['status']} '
          '详情=${rec['detail']?['status'] ?? '-'} '
          '正文=${rec['content']?['status'] ?? '-'}');
    }

    Future<void> worker() async {
      while (true) {
        final i = next++;
        if (i >= all.length) return;
        try {
          await one(i);
        } catch (e) {
          try {
            emit({'i': i, 'fatal': _brief(e)});
          } catch (_) {}
        }
        done++;
        if (done % 20 == 0 || done == all.length) {
          print('--- 进度 $done/${all.length} '
              '(${DateTime.now().difference(t0).inSeconds}s) ---');
        }
      }
    }

    await Future.wait([
      for (var i = 0; i < conc && i < all.length; i++) worker(),
    ]);
    await wq;

    // ---------- 汇总 ----------
    var sOk = 0, sEmpty = 0, sErr = 0, dOk = 0, cOk = 0, eOk = 0, nonText = 0;
    for (final l in (await outFile.readAsLines())) {
      if (l.trim().isEmpty) continue;
      final r = jsonDecode(l) as Map;
      if (r['skipped'] != null) nonText++;
      final s = ((r['search'] as Map?)?['status'] as String?) ?? '';
      if (s == 'ok') sOk++;
      if (s == 'empty') sEmpty++;
      if (s == 'err') sErr++;
      if (((r['detail'] as Map?)?['status']) == 'ok') dOk++;
      if (((r['content'] as Map?)?['status']) == 'ok') cOk++;
      if (((r['explore'] as Map?)?['status']) == 'ok') eOk++;
    }
    print('=== 汇总（共 ${all.length} 条，非文本 $nonText）: '
        '搜索 ok=$sOk empty=$sEmpty err=$sErr ｜ 目录 ok=$dOk ｜ '
        '正文 ok=$cOk ｜ 发现 ok=$eOk ===');
  }, timeout: const Timeout(Duration(minutes: 150)));
}
