// 离线解析分身池（lib/legado/parse_worker.dart）的回归。
//
// 这里验的是「搬出主 isolate」这件事本身能不能成立、以及搬出去之后
// 结论是否还和主线程一致 —— 三件事最容易坏：
//  1. spawn / 消息协议（闭包捕获了不可发送对象就整体哑火）；
//  2. 需要平台通道的源（隐藏 WebView）必须留在主线程，塞进分身只会拿壳页
//     把好源判成死源；
//  3. 分身里吸收的 Cookie 与搜索写入的跨阶段变量必须带回主线程，否则随后
//     的详情 `@get:{...}` 拿到空值，等于换了一套判定标准。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/legado/cookie_jar.dart';
import 'package:shuangyue/legado/models.dart';
import 'package:shuangyue/legado/online_book_service.dart';
import 'package:shuangyue/legado/online_repo.dart';
import 'package:shuangyue/legado/parse_worker.dart';
import 'package:shuangyue/legado/source_store.dart';
import 'package:shuangyue/platform/native_bridge.dart';

Map<String, dynamic> deadSource(int port) => {
      'bookSourceUrl': 'http://127.0.0.1:$port/a',
      'bookSourceName': 'dead-$port',
      'searchUrl': 'http://127.0.0.1:$port/search?q={{key}}',
      'ruleSearch': {
        'bookList': 'tag.a',
        'name': 'text',
        'bookUrl': 'href'
      },
    };

void main() {
  setUp(() => LegadoCookieJar.shared =
      LegadoCookieJar(dirsOverride: const AppDirs(files: '.', cache: '.'))
        ..readOnly = true);

  group('留在主线程的源', () {
    test('extra.webView 标记命中', () {
      expect(
          sourceNeedsMainParse(BookSource.fromJson({
            'bookSourceUrl': 'https://a.com',
            'bookSourceName': 'A',
            'webView': true,
          })),
          isTrue);
    });

    test('章地址尾缀 ,{"webView":true} 命中', () {
      expect(
          sourceNeedsMainParse(BookSource.fromJson({
            'bookSourceUrl': 'https://b.com',
            'bookSourceName': 'B',
            'searchUrl': 'https://b.com/s/{{key}},{"webView":true}',
          })),
          isTrue);
    });

    test('脚本里调 java.webView 命中', () {
      expect(
          sourceNeedsMainParse(BookSource.fromJson({
            'bookSourceUrl': 'https://c.com',
            'bookSourceName': 'C',
            'ruleContent': {
              'content': '@js:java.webView("https://c.com/r/1")',
            },
          })),
          isTrue);
    });

    test('普通静态源进分身', () {
      expect(
          sourceNeedsMainParse(BookSource.fromJson({
            'bookSourceUrl': 'https://d.com',
            'bookSourceName': 'D',
            'searchUrl': 'https://d.com/s?q={{key}}',
            'ruleSearch': {'bookList': 'class.result@tag.a'},
          })),
          isFalse);
    });
  });

  group('分身池', () {
    test('整条搜索链在后台 isolate 跑完并回结构化结论', () async {
      final tmp = Directory.systemTemp.createTempSync('sy_pool');
      ParseWorkerPool.I.disabled = false;
      try {
        final rs = await Future.wait([
          for (final p in [1, 2])
            ParseWorkerPool.I.submit({
              'kind': 'search',
              'source': deadSource(p),
              'key': '测试',
              'brief': true,
              'files': tmp.path,
              'cache': tmp.path,
              'timeoutSecs': 8,
            }),
        ]);
        expect(rs.every((r) => r != null), isTrue,
            reason: '两个任务都要有回执（null = 没走成分身）');
        for (final r in rs) {
          expect(r!['status'], 'err', reason: '连不上的站点不能判成可用');
          expect(r['count'], 0);
          expect(r['error'], isNotNull, reason: '失败必须带原因（阅读记录页展示）');
        }
      } finally {
        ParseWorkerPool.I.dispose();
        tmp.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));

    test('disabled 后一律回主线程（submit 直接给 null）', () async {
      ParseWorkerPool.I.disabled = true;
      expect(
          await ParseWorkerPool.I
              .submit({'kind': 'search', 'source': deadSource(3)}),
          isNull);
      ParseWorkerPool.I.disabled = false;
    });
  });

  group('端到端：上层调用真的落到分身', () {
    test('OnlineRepo.searchOne 走分身（不是悄悄退回主线程）', () async {
      final tmp = Directory.systemTemp.createTempSync('sy_e2e');
      debugSetWorkerDirs(AppDirs(files: tmp.path, cache: tmp.path));
      ParseWorkerPool.I.disabled = false;
      try {
        final repo = OnlineRepo(
          store: SourceStore(initial: [BookSource.fromJson(deadSource(1))]),
          perSourceTimeout: const Duration(seconds: 8),
        );
        final r = await repo.searchOne(
            BookSource.fromJson(deadSource(1)), '测试');
        expect(r.error, isNotNull);
        expect(ParseWorkerPool.I.liveWorkers, greaterThan(0),
            reason: '分身一个都没起 = 实际上还在主线程解析，根治没生效');
      } finally {
        debugSetWorkerDirs(null);
        ParseWorkerPool.I.dispose();
        tmp.deleteSync(recursive: true);
      }
    }, timeout: const Timeout(Duration(minutes: 2)));
  });

  group('分身结论的保真回传', () {
    test('站点下发的 Cookie 合回主线程仓库', () {
      // 用真实线上格式（LegadoCookie.toJson 的短键）回传，别用手写的长键
      applyOffthreadSideEffects({
        'cookies': [
          LegadoCookie(name: 'token', value: 'abc', domain: 'm.com').toJson(),
        ],
      }, 'https://m.com');
      expect(LegadoCookieJar.I.getFor('https://m.com/x'),
          contains('token=abc'));
    });

    test('搜索里 @put 的跨阶段变量带回主线程，详情 @get 才拿得到', () {
      applyOffthreadSideEffects({
        'itemVars': {
          'https://m.com/book/9': {'bid': '998'},
        },
      }, 'https://m.com');
      expect(OnlineBookService.itemVars('https://m.com', 'https://m.com/book/9'),
          {'bid': '998'});
    });

    test('回执里没有副作用时不动主线程状态', () {
      applyOffthreadSideEffects({'status': 'ok'}, 'https://n.com');
      expect(OnlineBookService.itemVars('https://n.com', 'x'), isEmpty);
    });
  });
}
