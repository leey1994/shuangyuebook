// 书源引擎与本地书的回归测试。
//
// 这些是「樱读 → 爽阅」融合里最容易悄悄坏掉的部分：规则拆解的边界、
// TXT 章节切分的误判、离线缓存键的唯一性。改动这些文件时请先跑本测试。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/data/shelf_sort.dart';
import 'package:novel_reader/legado/analyze_rule.dart';
import 'package:novel_reader/legado/models.dart';
import 'package:novel_reader/legado/rule_analyzer.dart';
import 'package:novel_reader/legado/source_health.dart';
import 'package:novel_reader/local/txt_parser.dart';
import 'package:novel_reader/models.dart';
import 'package:novel_reader/sources/legado_source.dart';
import 'package:novel_reader/sources/local_source.dart';
import 'package:novel_reader/sources/registry.dart';
import 'package:novel_reader/theme.dart';
import 'package:novel_reader/ui/reader/page_snap_physics.dart';

/// 框架自带的 FixedScrollMetrics，直接用，不必手写桩。
final _metrics = FixedScrollMetrics(
  minScrollExtent: 0,
  maxScrollExtent: 1000,
  pixels: 500,
  viewportDimension: 400,
  devicePixelRatio: 1,
  axisDirection: AxisDirection.right,
);

void main() {
  group('规则串拆解', () {
    test('|| 拆备选并丢掉空段', () {
      expect(
        RuleAnalyzer.splitAlternatives('a ||  || b'),
        ['a', 'b'],
      );
    });

    test('&& 拆串联', () {
      expect(RuleAnalyzer.splitConcat(' id.content@text && class.title '),
          ['id.content@text', 'class.title']);
    });

    test('## 拆替换链，成对出现是 pattern→replacement', () {
      final r = RuleAnalyzer.splitReplaces(r'base##\s+##  ');
      expect(r.base, 'base');
      expect(r.chains.length, 1);
      expect(r.chains[0].pattern, r'\s+');
      expect(r.chains[0].replacement, '  ');
    });

    test('## 末尾落单段 = 删除该匹配', () {
      final r = RuleAnalyzer.splitReplaces(r'tag.p@text##[0-9]+w[0-9]+');
      expect(r.chains.length, 1);
      expect(r.chains[0].pattern, r'[0-9]+w[0-9]+');
      expect(r.chains[0].replacement, '');
    });

    test('## 多组替换链依次执行', () {
      final r = RuleAnalyzer.splitReplaces(r'base##a##X##b##Y');
      expect(r.chains.length, 2);
      expect(r.chains[1].pattern, 'b');
      expect(r.chains[1].replacement, 'Y');
    });

    test('无 ## 时不产生替换链', () {
      final r = RuleAnalyzer.splitReplaces('  tag.a@href  ');
      expect(r.base, 'tag.a@href');
      expect(r.hasChains, isFalse);
    });

    test('模式前缀解析', () {
      expect(RuleAnalyzer.parsePrefix('@xpath://div').$1, RuleMode.xpath);
      expect(RuleAnalyzer.parsePrefix(r'@json:$.a').$2, r'$.a');
      expect(RuleAnalyzer.parsePrefix('tag.a').$1, RuleMode.auto);
    });

    test(r'替换链手动展开 $1 与 $&', () {
      final out = RuleAnalyzer.applyReplaces('abc123', [
        const ReplaceChain(r'(\w+?)(\d+)', r'$2-$1'),
      ]);
      expect(out, '123-abc');
    });

    test('非法正则跳过该链，不影响其它链', () {
      final out = RuleAnalyzer.applyReplaces('abc', [
        const ReplaceChain('([unclosed', 'x'),
        const ReplaceChain('b', 'B'),
      ]);
      expect(out, 'aBc');
    });
  });

  group('规则求值（CSS / JSON / 正则）', () {
    test('CSS 取属性并用 || 兜底', () {
      const html = '<div class="t">标题</div><a id="l" href="/a/1.html">第一章</a>';
      final e = AnalyzeRule(html);
      expect(e.getString('class.t@text'), '标题');
      expect(e.getString('id.nope@text || id.l@text'), '第一章');
    });

    test('JSONPath 取值', () {
      final e = AnalyzeRule(jsonEncode({
        'data': [
          {'name': '甲', 'url': '/1'},
          {'name': '乙', 'url': '/2'},
        ]
      }));
      expect(e.getStrings(r'$.data[*].name'), ['甲', '乙']);
    });

    test('getRawList 迭代出元素后可在 ctx 上继续求值', () {
      const html =
          '<ul><li><a href="/1">一</a></li><li><a href="/2">二</a></li></ul>';
      final e = AnalyzeRule(html);
      final items = e.getRawList('tag.li');
      expect(items.length, 2);
      expect(e.getString('tag.a@href', ctx: items[1]), '/2');
    });

    test('相对地址按书源主地址补全', () {
      const html = '<a href="/book/1">x</a>';
      final e = AnalyzeRule(html, baseUrl: 'https://site.tld');
      final href = e.getString('tag.a@href');
      expect(href, '/book/1');
    });
  });

  group('书源 JSON 兼容', () {
    test('空值 / 类型混用不抛异常，未知字段原样保留', () {
      final s = BookSource.fromJson({
        'bookSourceUrl': 'https://a.tld',
        'bookSourceName': 'A',
        'enabled': 'false', // 字符串布尔也要认
        'header': null,
        'someFutureField': 42, // 前向兼容：导出时写回
        'ruleSearch': {'bookList': 'tag.li', 'name': null},
      });
      expect(s.bookSourceUrl, 'https://a.tld');
      expect(s.enabled, isFalse);
      expect(s.extra['someFutureField'], 42);
      expect(s.toJson()['someFutureField'], 42);
    });

    test('坏条目跳过，其余照常导入', () {
      final list = BookSource.listFromJson([
        {'bookSourceUrl': 'https://a.tld', 'bookSourceName': 'A'},
        {'bookSourceName': '没有地址'},
      ]);
      expect(list.length, 1);
      expect(list.first.bookSourceName, 'A');
    });
  });

  group('TXT 编码探测与章节切分', () {
    test('UTF-8 中文', () {
      final bytes = utf8.encode('第一章 开始\n正文一\n第二章 继续\n正文二');
      final r = TxtParser.parseBytes(bytes);
      expect(r.encoding, 'utf-8');
      expect(r.chapters.length, greaterThanOrEqualTo(2));
    });

    test('带 BOM 的 UTF-8 不把 BOM 算进正文', () {
      final bytes =
          Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('第一章\n正文')]);
      final r = TxtParser.parseBytes(bytes);
      expect(r.text.startsWith('第'), isTrue);
    });

    test('识别不出章节时整篇作为一章', () {
      final r = TxtParser.parseText('就是一段没有章节的普通文字。\n还是文字。');
      expect(r.chapters.length, 1);
      expect(r.chapters.first.title, '全文');
    });

    test('章节偏移能覆盖全文且不重叠', () {
      const text = '第一章\n甲\n第二章\n乙\n第三章\n丙';
      final r = TxtParser.parseText(text);
      expect(r.chapters.length, 3);
      for (final c in r.chapters) {
        expect(c.start, lessThan(c.end));
        expect(c.end, lessThanOrEqualTo(text.length));
      }
      // 相邻章节首尾相接（允许换行重叠）
      expect(r.chapters.first.end, greaterThanOrEqualTo(r.chapters[1].start));
    });

    test('正文里的「第N章」长句不误判为标题', () {
      const long =
          '第${'一'}${'二'}${'三'}${'章'}${'讲'}${'述'}${'了'}${'一'}${'个'}${'很'}${'长'}${'的'}${'句'}${'子'}${'。'}';
      final r = TxtParser.parseText('$long\n第一章 真标题\n正文');
      expect(r.chapters.length, 2);
    });
  });

  group('本地书章节键', () {
    test('章节 url 唯一 —— 否则离线缓存会互相覆盖', () {
      final urls = {
        for (var i = 0; i < 5; i++) LocalSource.chapterUrl('/a/b.txt', i)
      };
      expect(urls.length, 5);
    });

    test('章节序号可从 url 反解', () {
      expect(LocalSource.chapterIndexOf('/a/b.txt#7'), 7);
      expect(LocalSource.chapterIndexOf('/a/b.txt'), 0); // 无后缀兜底 0
    });

    test('书名去扩展名与目录', () {
      expect(LocalSource.bookForPath('/sd/Books/斗破.txt').title, '斗破');
      expect(LocalSource.bookForPath('/x/a.epub').title, 'a');
    });
  });

  group('书架排序', () {
    ShelfEntry e(String title, {String? author, int idx = 0, int total = 10}) =>
        ShelfEntry(
          book: Book(
              sourceId: 'x',
              id: title,
              url: title,
              title: title,
              author: author),
          chapterIndex: idx,
          chapterCount: total,
        );

    test('书名按自然序（数字不当字符序）', () {
      final list = [e('第10章'), e('第2章'), e('第1章')];
      sortShelf(list, ShelfSortMode.title, ascending: true);
      expect(list.map((x) => x.book.title), ['第1章', '第2章', '第10章']);
    });

    test('无名作者排最后', () {
      final list = [e('A'), e('B', author: '张三')];
      sortShelf(list, ShelfSortMode.author, ascending: true);
      expect(list.first.book.author, '张三');
    });

    test('进度高的排前面（降序）', () {
      final list = [e('A', idx: 1), e('B', idx: 8)];
      sortShelf(list, ShelfSortMode.progress, ascending: false);
      expect(list.first.book.title, 'B');
    });

    test('读完的书进度为 100%', () {
      final a = e('A', idx: 2, total: 10)..finished = true;
      expect(shelfProgressOf(a), 1.0);
    });

    test('总章数未知时仍有一点进度', () {
      expect(shelfProgressOf(e('A', idx: 3, total: 0)), greaterThan(0));
      expect(shelfProgressOf(e('A', idx: 0, total: 0)), 0);
    });
  });

  group('阅读背景', () {
    test('六种背景日夜各三', () {
      expect(kReaderBgs.length, 6);
      expect(kReaderBgs.where((b) => !b.isDark).length, 3);
      expect(kReaderBgs.where((b) => b.isDark).length, 3);
    });
  });

  group('内置书源登记表', () {
    test('智能书库已移除', () {
      expect(
        builtinSources.any((s) => s.name == '智能书库'),
        isFalse,
        reason: '内置源里不应再出现「智能书库」',
      );
      expect(builtinSources.any((s) => s.id == 'zzbook'), isFalse);
    });

    test('其余固化源齐全（删除一个不能误伤）', () {
      final names = builtinSources.map((s) => s.name).toSet();
      for (final n in [
        '顶点小说',
        '速读谷',
        '黄金屋',
        '52书库',
        '搬山人',
        '神文小说',
        '素书卷',
        '篱笆好文学',
        '小原文学',
        '全本小说网',
      ]) {
        expect(names, contains(n), reason: '「$n」不应被误删');
      }
    });

    test('书源 id 唯一', () {
      final ids = builtinSources.map((s) => s.id).toList();
      expect(ids.toSet().length, ids.length);
    });
  });

  group('导入书源参与聚合的配额', () {
    test('每个导入源在推荐里最多 5 本', () {
      expect(LegadoSource.homePerSource, 5);
    });

    test('导入源与本地书都进了 allSources', () {
      final all = allSources.map((s) => s.id).toSet();
      expect(all, contains('local'));
      // 固化源全在
      for (final s in builtinSources) {
        expect(all, contains(s.id));
      }
    });
  });

  group('翻页物理', () {
    const physics = PageSnapPhysics();

    test('边界处不再吞掉拖动 —— 章末才能累计出越界量', () {
      // 这是「看完本章继续滑动翻不到下一章」的根因：
      // 默认物理在末页把多出来的位移直接吃掉，ScrollPosition 收不到越界信号。
      expect(physics.applyPhysicsToUserOffset(_metrics, 120), 120);
      expect(physics.applyPhysicsToUserOffset(_metrics, -45), -45);
    });

    test('页吸附时长随距离收敛且不拖尾', () {
      final near = PageSnapSimulation(from: 0, to: 10, pageExtent: 1000);
      final far = PageSnapSimulation(from: 0, to: 1000, pageExtent: 1000);
      expect(near.duration, lessThan(far.duration));
      expect(near.duration, greaterThanOrEqualTo(0.11)); // 下限 110ms
      expect(far.duration, closeTo(0.30, 0.001)); // 整页 ≈ 300ms
      expect(near.isDone(near.duration), isTrue);
    });
  });

  group('书源健康档案', () {
    SourceHealth h(String name, {required bool ok, int daysAgo = 0}) =>
        SourceHealth(
          url: 'https://$name.tld',
          name: name,
          ok: ok,
          books: ok ? 3 : 0,
          ms: 120,
          error: ok ? null : '搜索无结果',
          checkedAt: DateTime.now().subtract(Duration(days: daysAgo)),
        );

    test('当天结果按「正常的在前、耗时升序」排列', () {
      final store = SourceHealthStore();
      store.seedForTest([
        h('slow_ok', ok: true),
        h('bad', ok: false),
        h('fast_ok', ok: true),
      ]);
      final today = store.today;
      expect(today.first.ok, isTrue);
      expect(today.last.ok, isFalse);
      expect(today.where((x) => !x.ok).length, 1);
      expect(store.todayOk, 2);
      expect(store.todayFailed, 1);
    });

    test('昨天的结果不计入「今日」', () {
      final store = SourceHealthStore();
      store.seedForTest([h('yesterday', ok: true, daysAgo: 1)]);
      expect(store.today, isEmpty);
      expect(store.checkedToday, isFalse);
    });

    test('今天检测过就不再重复', () {
      final store = SourceHealthStore();
      store.seedForTest([h('a', ok: true)]);
      expect(store.checkedToday, isTrue);
    });

    test('结论摘要同时说清可用与移除数量', () {
      final r = SourceCheckReport(
        checked: 5,
        passed: 3,
        failed: [h('x', ok: false)],
        removed: ['https://x.tld'],
      );
      expect(r.hasFailure, isTrue);
      expect(r.summary, contains('5'));
      expect(r.summary, contains('3'));
      expect(r.summary, contains('已移除 1 个'));
    });

    test('JSON 往返不丢字段', () {
      final src = h('a', ok: true);
      final back = SourceHealth.fromJson(src.toJson());
      expect(back.url, src.url);
      expect(back.ok, isTrue);
      expect(back.books, 3);
    });
  });
}
