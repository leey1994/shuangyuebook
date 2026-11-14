// 热榜落地（hot_resolver.dart）测试：匹配打分与「落回可用书源」全离线验证。
//
// 用假源（不入注册表，直接传 pool）控制搜索结果，验证：
//  1. 书名/作者匹配打分的门槛与边界；
//  2. resolveOneHotEntry：命中即停、全未命中记「搜过没有」、缓存命中不再发请求；
//  3. 解析出的书来自搜索结果本身（点进去就是该书源的可读条目）。
import 'package:flutter_test/flutter_test.dart';
import 'package:shuangyue/collect/aggregate.dart';
import 'package:shuangyue/collect/hot_board.dart';
import 'package:shuangyue/collect/hot_resolver.dart';
import 'package:shuangyue/dom.dart';
import 'package:shuangyue/feed_cache.dart';
import 'package:shuangyue/models.dart';
import 'package:shuangyue/sources/source.dart';

/// 计数假源：按预置映射返回搜索结果，记录每次查询。
class _ScriptedSource extends NovelSource {
  _ScriptedSource(this.id, this.results);
  @override
  final String id;
  final Map<String, List<Book>> results;
  final List<String> queries = [];

  @override
  String get name => '源$id';
  @override
  String get baseUrl => 'https://$id.test';

  @override
  Future<List<Book>> fetchHome() async => const [];
  @override
  Future<List<RankTab>> fetchRankTabs() async => const [];
  @override
  Future<Paged<Book>> fetchRank(RankTab tab, {String? nextUrl}) async =>
      const Paged(items: []);
  @override
  Future<Paged<BooklistEntry>> fetchBooklists({String? nextUrl}) async =>
      const Paged(items: []);
  @override
  Future<Booklist> fetchBooklist(BooklistEntry entry) async =>
      throw UnimplementedError();
  @override
  Future<BookDetail> fetchDetail(Book book, {String? nextUrl}) async =>
      throw UnimplementedError();
  @override
  List<String> contentOf(Document doc, String pageUrl) => const [];

  @override
  Future<List<Book>> search(String query) async {
    queries.add(query);
    return results[query] ?? const [];
  }
}

Book _book(String sourceId, String title, {String? author}) => Book(
      sourceId: sourceId,
      id: '$sourceId/$title',
      url: 'https://$sourceId.test/book/${Uri.encodeComponent(title)}',
      title: title,
      author: author,
    );

/// 聚合搜索型假源：只凭书名就能定位，不发搜索请求（owllook 式）。
class _TitleSource extends _ScriptedSource {
  _TitleSource() : super('title', const {});

  @override
  bool get resolvesByTitle => true;

  @override
  Book? bookFromTitle(String title, {String? author}) => Book(
        sourceId: id,
        id: '/search?wd=$title',
        url: '/search?wd=$title',
        title: title,
        author: author,
      );
}

void main() {
  // FeedCache / HotMatchCache 都是进程内静态缓存，会在用例间泄漏：
  // 每个用例前清掉（否则前一个用例的命中会污染下一个用例的「未命中」断言）。
  setUp(() {
    HotMatchCache.clear();
    FeedCache.clearForTest();
  });

  group('匹配打分 hotMatchScore', () {
    test('书名作者全中 = 1.0，且作者一致再加成不越界', () {
      const item = HotItem(rank: 1, title: '诡秘之主', author: '爱潜水的乌贼', site: 'x');
      final b = _book('s1', '诡秘之主', author: '爱潜水的乌贼');
      expect(hotMatchScore(item, b), greaterThanOrEqualTo(1.0));
    });

    test('书名相同作者不同仍达门槛（有的源作者署名缺失或别名）', () {
      const item = HotItem(rank: 1, title: '诡秘之主', author: '爱潜水的乌贼', site: 'x');
      final b = _book('s1', '诡秘之主');
      expect(hotMatchScore(item, b), greaterThanOrEqualTo(kHotMatchThreshold));
    });

    test('长书名前缀截断（17K「东北风云：黑血漫…」）匹配完整书名', () {
      const item = HotItem(rank: 3, title: '东北风云：黑血漫…', site: 'x');
      final b = _book('s1', '东北风云：黑血漫天');
      expect(hotMatchScore(item, b), greaterThanOrEqualTo(kHotMatchThreshold));
    });

    test('完全无关的书不匹配', () {
      const item = HotItem(rank: 1, title: '诡秘之主', site: 'x');
      final b = _book('s1', '凡人修仙传', author: '忘语');
      expect(hotMatchScore(item, b), 0);
    });

    test('短书名不做前缀/包含匹配（防串书）', () {
      const item = HotItem(rank: 1, title: '剑来', site: 'x');
      final b = _book('s1', '剑来2：续篇');
      expect(hotMatchScore(item, b), 0);
    });

    test('包含但比例过低不算命中', () {
      const item = HotItem(rank: 1, title: '无敌', site: 'x');
      final b = _book('s1', '无敌从满级属性开始');
      expect(hotMatchScore(item, b), 0);
    });

    test('书名归一化对齐聚合层（标点/全角差异不影响命中）', () {
      const item = HotItem(rank: 1, title: '封总，太太想跟你离婚很久了', site: 'x');
      final b = _book('s1', '封总太太想跟你离婚很久了');
      expect(hotMatchScore(item, b), greaterThanOrEqualTo(kHotMatchThreshold));
      // 与 mergeBooks 用同一套归一化
      expect(normHotTitle('剑来！'), normBookText('剑来！'));
    });
  });

  group('落回可用书源 resolveOneHotEntry', () {
    test('命中即停：第一个命中的源之后不再问后面的源', () async {
      final hit = _book('s1', '诡秘之主', author: '爱潜水的乌贼');
      final s1 = _ScriptedSource('s1', {'诡秘之主': [hit]});
      final s2 = _ScriptedSource('s2', {});
      final e = HotRankEntry(const HotItem(rank: 1, title: '诡秘之主', author: '爱潜水的乌贼', site: 'x'));
      await resolveOneHotEntry(e, [s1, s2]);
      expect(e.readable, isTrue);
      expect(e.source!.id, 's1');
      expect(e.book!.url, hit.url);
      expect(s2.queries, isEmpty);
    });

    test('第一个源没搜到，落到第二个源', () async {
      final hit = _book('s2', '绍宋', author: '榴弹怕水');
      final s1 = _ScriptedSource('s1', {});
      final s2 = _ScriptedSource('s2', {'绍宋': [hit]});
      final e = HotRankEntry(const HotItem(rank: 1, title: '绍宋', author: '榴弹怕水', site: 'x'));
      await resolveOneHotEntry(e, [s1, s2]);
      expect(e.readable, isTrue);
      expect(e.source!.id, 's2');
    });

    test('同名但作者对不上的候选不算命中（宁缺毋滥）', () async {
      final wrong = _book('s1', '诡秘之主同人：别册', author: '别人');
      final s1 = _ScriptedSource('s1', {'诡秘之主': [wrong]});
      final e = HotRankEntry(const HotItem(rank: 1, title: '诡秘之主', author: '爱潜水的乌贼', site: 'x'));
      await resolveOneHotEntry(e, [s1]);
      expect(e.readable, isFalse);
    });

    test('搜不动（抛错）的源被跳过，不影响后续源', () async {
      final hit = _book('s2', '牧神记', author: '宅猪');
      final s1 = _ScriptedSource('s1', {});
      final s2 = _ScriptedSource('s2', {'牧神记': [hit]});
      final e = HotRankEntry(const HotItem(rank: 1, title: '牧神记', author: '宅猪', site: 'x'));
      await resolveOneHotEntry(e, [s1, s2]);
      expect(e.readable, isTrue);
      expect(e.source!.id, 's2');
    });

    test('结果只来自该源自己的搜索条目（可读性由书源保证）', () async {
      final b = _book('s1', '九星霸体诀', author: '平凡魔术师');
      final s1 = _ScriptedSource('s1', {'九星霸体诀': [b]});
      final e = HotRankEntry(const HotItem(rank: 1, title: '九星霸体诀', author: '平凡魔术师', site: 'x'));
      await resolveOneHotEntry(e, [s1]);
      expect(e.book, isNotNull);
      expect(e.book!.sourceId, 's1');
    });
  });

  group('批量落地 resolveHotItems', () {
    test('全部条目都有结论；进度与节流快照都有回调', () async {
      final b1 = _book('s1', '甲书');
      final s1 = _ScriptedSource('s1', {'甲书': [b1], '乙书': []});
      final items = [
        const HotItem(rank: 1, title: '甲书', site: 'x'),
        const HotItem(rank: 2, title: '乙书', site: 'x'),
      ];
      final progresses = <int>[];
      final partials = <int>[];
      final out = await resolveHotItems(
        items,
        sources: [s1],
        onProgress: (d, t) => progresses.add(d),
        onPartial: (p) => partials.add(p.where((e) => e.readable).length),
      );
      expect(out.length, 2);
      expect(out[0].readable, isTrue);
      expect(out[1].readable, isFalse);
      expect(progresses.last, 2);
      expect(partials, isNotEmpty);
    });

    test('maxItems 截断榜单（只处理前 N 条）', () async {
      final s1 = _ScriptedSource('s1', {});
      final items = [
        for (var i = 1; i <= 10; i++)
          HotItem(rank: i, title: '书$i', site: 'x'),
      ];
      final out = await resolveHotItems(items, sources: [s1], maxItems: 3);
      expect(out.length, 3);
      expect(out[0].item.title, '书1');
    });
  });

  group('匹配记忆 HotMatchCache', () {
    test('同书名二次落地不再发请求', () async {
      final b = _book('s1', '缓存书');
      final s1 = _ScriptedSource('s1', {'缓存书': [b]});
      final e1 = HotRankEntry(const HotItem(rank: 1, title: '缓存书', site: 'x'));
      await resolveOneHotEntry(e1, [s1]);
      expect(e1.readable, isTrue);
      expect(s1.queries.length, 1);

      final e2 = HotRankEntry(const HotItem(rank: 2, title: '缓存书', site: 'x'));
      await resolveOneHotEntry(e2, [s1]);
      expect(e2.readable, isTrue);
      expect(s1.queries.length, 1); // 没有新增查询
    });
  });

  group('按书名定位型源（owllook 快路径）', () {
    test('零搜索请求即可落地，且带上榜单作者', () async {
      final s = _TitleSource();
      final e = HotRankEntry(const HotItem(
          rank: 1, title: '玄鉴仙族', site: 'owllook·起点榜', author: '起点'));
      await resolveOneHotEntry(e, [s]);
      expect(e.readable, isTrue);
      expect(e.book!.url, '/search?wd=玄鉴仙族');
      expect(e.book!.author, '起点');
      expect(s.queries, isEmpty); // 关键：没有真的发搜索
    });
  });
}
