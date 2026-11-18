// 权威榜单：owllook 起点榜 / 番茄榜 / Owllook 搜索榜。
//
// 为什么不再只吃书源自己的榜单：站内「热销 / 新书」榜是各聚合站按自己的
// 镜像顺序排的，排在前面常常是没人读的老书或推广位，而且同一个站一天里
// 几乎不变 —— 用户看到的就是「一堆不想看的书，还不会刷新」。
//
// 这里读 owllook（小说搜索引擎）汇总的权威榜单整页：
//   · 起点榜   ← https://www.owllook.top/md/qidian（起点月票/畅销/阅读指数等）
//   · 番茄榜   ← https://fanqienovel.com/rank/<gender>_<type>（番茄官方阅读/新书榜，
//                 男频女频各取前 10，书名/简介带 PUA 字体反爬，本地还原）
//   · Owllook榜 ← https://www.owllook.top/md/（站内搜索次数排行）
//
// 起点主站有 WAF（probe.js 挑战），owllook 的 /md/qidian 是服务端渲染的
// 表格，纯 HTTP 可稳定直连；番茄榜读官方榜单页的 __INITIAL_STATE__。
//
// 榜单只给出「书名」，能不能读不取决于榜单站 —— 由
// [resolveHotItems]（见 hot_resolver.dart）拿回用户自己的可用书源里匹配。
// 于是排行榜既「权威」，点进去又一定是自己能读的那一本。
//
// 解析函数与取网分离，纯函数可单测：
// 站点改版时只需要改解析，测试用 fixtures 固定结构，不打真实网络。
library;

import 'package:flutter/foundation.dart';

import '../dom.dart';
import '../models.dart';
import '../net.dart';
import '../sources/fanqie.dart';
import '../sources/fanqie_font.dart';

/// 榜单语义：热搜（大家都在搜）还是热读（大家都在看）。
enum HotBoardKind { search, read }

/// 一条权威榜单条目 —— 还没落到任何书源上。
@immutable
class HotItem {
  const HotItem({
    required this.rank,
    required this.title,
    required this.site,
    this.author,
    this.category,
    this.status,
    this.cover,
    this.hint,
    this.book,
  });

  /// 榜单内名次（1 起）。
  final int rank;

  /// 书名。17K 榜单会把长书名截断成「…」，匹配时会做前缀兼容。
  final String title;

  /// 作者（17K/晋江榜单提供）。
  final String? author;

  /// 分类（如「玄幻」「古代言情」）。
  final String? category;

  /// 连载状态（「连载」/「完结」）。
  final String? status;

  /// 封面地址（榜单站图可直连时才有）。
  final String? cover;

  /// 榜单来源站点（展示用，如「17K订阅榜」「晋江积分榜」）。
  final String site;

  /// 榜单口径数值（订阅金额名次说明等），原样展示。
  final String? hint;

  /// 榜单直接给出的可读书（番茄榜带 bookId，不用再拿书名回书源里匹配）。
  final Book? book;

  @override
  String toString() => 'HotItem($rank, $title, $site)';
}

/// 一个权威榜单的定义。
@immutable
class HotBoard {
  const HotBoard({
    required this.id,
    required this.label,
    required this.site,
    required this.kind,
    required this.url,
    required this.note,
  });

  /// 稳定 id（缓存键 / 设置持久化用，改名不要改它）。
  final String id;

  /// 榜单页签文字（热读榜 / 女频热读榜）。
  final String label;

  /// 数据来源站点名。
  final String site;

  final HotBoardKind kind;

  /// 原始榜单地址。
  final String url;

  /// 一句话说明口径，给「榜单口径」弹层用。
  final String note;

  /// 起点榜：owllook 汇总的起点官方榜单（月票榜 / 畅销榜 / 阅读指数榜…）。
  /// 起点主站有 WAF，owllook 的 /md/qidian 是服务端渲染整页，可稳定直连。
  static const HotBoard owllookQidian = HotBoard(
    id: 'owllook_qidian',
    label: '起点榜',
    site: 'owllook·起点榜',
    kind: HotBoardKind.read,
    url: 'https://www.owllook.top/md/qidian',
    note: 'owllook 汇总的起点官方榜单：月票榜 / 畅销榜 / 阅读指数榜等，'
        '按榜单优先序合并去重，每条标注来自哪个分榜。',
  );

  /// 番茄榜：番茄小说官方榜单（男频 / 女频 × 阅读榜 / 新书榜，各前 10）。
  ///
  /// 榜单条目自带 bookId，点进去就是番茄详情页 —— 不用再拿书名回书源里搜，
  /// 也就绕开了番茄站内搜索的人机验证。书名 / 简介是 PUA 字体反爬，本地还原。
  static const HotBoard fanqieRank = HotBoard(
    id: 'fanqie_rank',
    label: '番茄榜',
    site: '番茄小说',
    kind: HotBoardKind.read,
    url: 'https://fanqienovel.com/rank/1_1',
    note: '番茄官方榜单：男频 / 女频 × 阅读榜 / 新书榜，各取前 10（共 40 本）。'
        '阅读榜按在读数据排（30 万字以上），新书榜是 30 万字以下的新书。'
        '条目自带 bookId，点开直接读。',
  );

  /// 番茄四个分榜：`/rank/<性别>_<榜单>`，1=男频 0=女频，1=阅读榜 2=新书榜。
  static const List<(String, String)> fanqieBoards = <(String, String)>[
    ('男频阅读榜', 'https://fanqienovel.com/rank/1_1'),
    ('男频新书榜', 'https://fanqienovel.com/rank/1_2'),
    ('女频阅读榜', 'https://fanqienovel.com/rank/0_1'),
    ('女频新书榜', 'https://fanqienovel.com/rank/0_2'),
  ];

  /// Owllook 榜：站内小说搜索次数排行（大家都在搜什么书）。
  static const HotBoard owllookHot = HotBoard(
    id: 'owllook_hot',
    label: 'Owllook榜',
    site: 'owllook·搜索榜',
    kind: HotBoardKind.search,
    url: 'https://www.owllook.top/md/',
    note: 'owllook 站内搜索次数榜：按小说被搜索的次数排序，带搜索次数。'
        '注意 /md（无斜杠）会 403 跳转，必须用带斜杠的地址。',
  );

  /// 页签顺序即优先级：起点榜、番茄榜、Owllook 搜索榜。
  static const List<HotBoard> all = <HotBoard>[
    owllookQidian,
    fanqieRank,
    owllookHot,
  ];

  static HotBoard byId(String id) => all.firstWhere(
        (b) => b.id == id,
        orElse: () => all.first,
      );
}

/// 一次抓取的结果（含抓取时间，供 UI 显示「刚刚更新」）。
@immutable
class HotBoardData {
  const HotBoardData({
    required this.board,
    required this.items,
    required this.fetchedAt,
    this.siteUpdated,
  });

  final HotBoard board;
  final List<HotItem> items;
  final DateTime fetchedAt;

  /// 榜单站点自己标注的更新时间原文（17K 会给，百度不给）。
  final String? siteUpdated;
}

/// 进程内榜单缓存：同一榜单 10 分钟内不重复拉网，下拉刷新可强制作废。
///
/// 不走 [FeedCache]：它的磁盘序列化只认 Book/RankTab 等模型，而这里要保住
/// 「已解析好的 HotItem」；榜单本身一天变不了几次，重新拉一次也就一个请求。
class HotBoardCache {
  HotBoardCache._();

  static final Map<String, HotBoardData> _m = {};

  static const Duration ttl = Duration(minutes: 10);

  /// 按「抓取时间」判龄而不是「放入时间」：缓存的就是榜单自己的新鲜度。
  static HotBoardData? get(String id) {
    final e = _m[id];
    if (e == null) return null;
    if (DateTime.now().difference(e.fetchedAt) > ttl) {
      _m.remove(id);
      return null;
    }
    return e;
  }

  static void put(HotBoardData data) {
    _m[data.board.id] = data;
  }

  static void clear([String? id]) {
    if (id == null) {
      _m.clear();
    } else {
      _m.remove(id);
    }
  }
}

/// 抓取一个权威榜单（带 10 分钟缓存）。
///
/// [force] 为 true 时忽略缓存重新拉网（下拉刷新 / 手动刷新）。
/// 失败抛出带人话的异常，由调用方展示「重试」而不是让整页空掉。
Future<HotBoardData> fetchHotBoard(HotBoard board, {bool force = false}) async {
  if (!force) {
    final hit = HotBoardCache.get(board.id);
    if (hit != null) return hit;
  }
  final data = await _fetch(board);
  HotBoardCache.put(data);
  return data;
}

Future<HotBoardData> _fetch(HotBoard board) async {
  if (board.id == HotBoard.fanqieRank.id) return _fetchFanqieRank(board);
  final resp = await Net.get(board.url);
  if (resp.status != 200) {
    throw Exception('${board.site} 榜单暂时取不到（HTTP ${resp.status}）');
  }
  final parsed = _parse(board, resp.body);
  if (parsed.items.isEmpty) {
    throw Exception('${board.site} 榜单解析为空，站点可能改版了');
  }
  return HotBoardData(
    board: board,
    items: parsed.items,
    fetchedAt: DateTime.now(),
    siteUpdated: parsed.siteUpdated,
  );
}

/// 番茄榜：4 个分榜并发取页，按声明顺序合并（男频阅读 → 男频新书 → 女频…）。
///
/// 单个分榜抽风返回空就跳过，不全盘失败；4 个都空才报错。
Future<HotBoardData> _fetchFanqieRank(HotBoard board) async {
  final results = await Future.wait([
    for (final (_, url) in HotBoard.fanqieBoards)
      Net.get(url).then((r) => r.status == 200 ? r.body : '').catchError(
            (Object _) => '',
          ),
  ]);
  final items = <HotItem>[];
  for (var i = 0; i < results.length; i++) {
    if (results[i].isEmpty) continue;
    final label = HotBoard.fanqieBoards[i].$1;
    items.addAll(parseFanqieRank(results[i], site: board.site, board: label));
  }
  if (items.isEmpty) {
    throw Exception('${board.site} 榜单解析为空，站点可能改版了');
  }
  return HotBoardData(
    board: board,
    items: items,
    fetchedAt: DateTime.now(),
    siteUpdated: null,
  );
}

/// 解析番茄榜单页 `__INITIAL_STATE__.rank.book_list`（纯函数，可离线单测）。
///
/// 每个条目自带 bookId / 书名 / 作者 / 简介 / 封面 / 状态，直接落成 [Book]：
/// 点进去就是番茄详情页，不需要再用书名回书源里匹配。
List<HotItem> parseFanqieRank(
  String body, {
  required String site,
  required String board,
}) {
  final rank = FanqieSource.initialState(body)?['rank'];
  if (rank is! Map) return const [];
  final list = rank['book_list'];
  if (list is! List) return const [];
  final out = <HotItem>[];
  for (var i = 0; i < list.length; i++) {
    final e = list[i];
    if (e is! Map) continue;
    final id = (e['bookId']?.toString() ?? '').trim();
    final title = decodeFanqieText((e['bookName']?.toString() ?? '').trim());
    if (id.isEmpty || title.isEmpty) continue;
    final status = switch ((e['creationStatus']?.toString() ?? '').trim()) {
      '1' => '完结',
      '0' => '连载',
      _ => null,
    };
    final book = Book(
      sourceId: FanqieSource.sourceId,
      id: id,
      url: '$kFanqieBase/page/$id',
      title: title,
      author: _nz(decodeFanqieText(e['author']?.toString() ?? '')),
      cover: _nz(e['thumbUri']?.toString() ??
          e['thumbUrl']?.toString() ??
          ''),
      intro: _nz(decodeFanqieText(e['abstract']?.toString() ?? '')),
      status: status,
      latest: _nz(decodeFanqieText(e['lastChapterTitle']?.toString() ?? '')),
    );
    out.add(HotItem(
      rank: i + 1,
      title: title,
      site: site,
      author: book.author,
      category: board,
      status: status,
      cover: book.cover,
      book: book,
    ));
  }
  return out;
}

String? _nz(String s) => s.trim().isEmpty ? null : s.trim();

/// 解析结果（站点自带更新时间可选）。
typedef _ParsedBoard = ({List<HotItem> items, String? siteUpdated});

_ParsedBoard _parse(HotBoard board, String body) => switch (board.id) {
      'owllook_qidian' => parseOwllookBoard(body, site: board.site),
      'owllook_hot' =>
        parseOwllookBoard(body, site: board.site, withSearchCount: true),
      _ => (items: const <HotItem>[], siteUpdated: null),
    };

// ------------------------------------------------------------- owllook 榜单

/// 解析 owllook 的 `/md/*` 榜单页。
///
/// 页面由若干 `<table class="mdui-table">` 组成，每张表是一个分榜：
/// `<thead>` 第二个 `<th>` 是分榜名（`/md/` 是「小说名 / 搜索次数」），
/// `<tbody>` 每行 `td[0]` 名次、`td[1]` 的 `<a href="/search?wd=…">` 是书名，
/// `/md/` 还多一列 `td[2]` 搜索次数。
///
/// 多张分榜按页面顺序合并、按书名去重（同一本书常同时上月票榜和畅销榜），
/// rank 重新连续编号；分榜名放 [HotItem.category]，搜索次数放 [HotItem.hint]。
/// 纯函数，可离线单测 —— 站点改版时只改这里。
({List<HotItem> items, String? siteUpdated}) parseOwllookBoard(
  String body, {
  required String site,
  bool withSearchCount = false,
}) {
  final doc = parseHtml(body);
  final items = <HotItem>[];
  final seen = <String>{};
  var rank = 0;
  for (final table in doc.querySelectorAll('table.mdui-table')) {
    final ths = table.querySelectorAll('thead th');
    final boardName = ths.length > 1 ? textOf(ths[1]) : '';
    final isSearchBoard = boardName.contains('小说名');
    for (final tr in table.querySelectorAll('tbody tr')) {
      final tds = tr.querySelectorAll('td');
      if (tds.length < 2) continue;
      final a = tds[1].querySelector('a');
      final title = _stripEllipsis(textOf(a));
      if (title.isEmpty || !seen.add(title)) continue;
      rank++;
      String? hint;
      if (withSearchCount && tds.length > 2) {
        final n = textOf(tds[2]).replaceAll(RegExp(r'[^0-9]'), '');
        if (n.isNotEmpty) hint = n;
      }
      items.add(HotItem(
        rank: rank,
        title: title,
        site: site,
        category: (isSearchBoard || boardName.isEmpty) ? null : boardName,
        hint: hint,
      ));
    }
  }
  return (items: items, siteUpdated: null);
}

// ------------------------------------------------------------- 17K 订阅榜（备用解析器）

/// 解析 17K 官方订阅榜 Top100 整页（`/top/refactor/top100/01_subscribe/…`）。
///
/// 页面是服务端渲染的表格：`div#TOPBOX_TAB` 之后的第一个 `<table>`，
/// 每行 `<tr>`：名次 / [分类] / 书名（`title` 属性） / 最新章 / 更新时间 /
/// 作者（`title` 属性）/ 状态。第一行是表头要跳过。
({List<HotItem> items, String? siteUpdated}) parse17kSubscribeTop100(
    String body) {
  final i = body.indexOf('TOPBOX_TAB');
  if (i < 0) return (items: const <HotItem>[], siteUpdated: null);
  final seg = body.substring(i);
  final j0 = seg.indexOf('<table');
  final j1 = seg.indexOf('</table>');
  if (j0 < 0 || j1 < 0) return (items: const <HotItem>[], siteUpdated: null);
  final doc = parseHtml(seg.substring(j0, j1));

  final items = <HotItem>[];
  for (final tr in doc.querySelectorAll('tr')) {
    final tds = tr.querySelectorAll('td');
    if (tds.length < 5) continue; // 表头是 <th>，没有 td
    final rank = int.tryParse(textOf(tds[0])) ?? 0;
    if (rank <= 0) continue;
    final catLink = tds[1].querySelector('a');
    final cat = catLink == null
        ? null
        : _stripEllipsis(
            textOf(catLink).replaceAll(RegExp(r'^\[|\]$'), '').trim());
    final titleA = tds[2].querySelector('a');
    final title = titleA == null ? '' : _stripEllipsis(textOf(titleA));
    if (title.isEmpty) continue;
    final authorA = tds.length > 5 ? tds[5].querySelector('a') : null;
    items.add(HotItem(
      rank: rank,
      title: title,
      site: '17K订阅榜',
      author: authorA == null ? null : textOf(authorA),
      category: (cat == null || cat.isEmpty) ? null : cat,
      status: textOf(tds.length > 6 ? tds[6] : null),
    ));
  }
  return (items: items, siteUpdated: null);
}

// ---------------------------------------------------------------- 晋江积分榜

/// 解析晋江官方总分榜（`topten.php?orderstr=7`，半年积分）。
///
/// 条目特征：`onebook.php?novelid=<id>` 链接（class=tooltip 的文字是书名），
/// 前面最近的 `td align="center">N</td>` 是名次，同区块内
/// `oneauthor.php?authorid=…">作者</a>`。分类行是「原创-言情-…」管线文本。
({List<HotItem> items, String? siteUpdated}) parseJjwxcScoreBoard(String body) {
  // 名次 → 条目 → 书名 的配对扫描（晋江没有把三者放进同一个易解析容器）
  final re = RegExp(
    r'<td[^>]*align="center"[^>]*>\s*(\d{1,3})\s*</td>'
    r'[\s\S]{0,3000}?onebook\.php\?novelid=(\d+)"'
    r'[\s\S]{0,1200}?class="tooltip">\s*([^<]{1,50})\s*</a>',
  );
  final authorRe =
      RegExp(r'oneauthor\.php\?authorid=\d+">\s*([^<]{1,30})\s*</a>');
  final kindRe = RegExp(
      r'(原创[--][\u4e00-\u9fa5]{2}[--][\u4e00-\u9fa5]{2,8}[--][\u4e00-\u9fa5]{2,8})');

  final items = <HotItem>[];
  final seen = <String>{};
  for (final m in re.allMatches(body)) {
    final title = _stripEllipsis(m.group(3)!.trim());
    if (title.isEmpty) continue;
    if (!seen.add(m.group(2)!)) continue; // 同一本书只取第一个名次
    // 晋江行结构：名次 td → 作者 td → 书名 td → 分类 td。
    // 作者在匹配区间内（名次与书名之间）取最近的一个；分类在书名之后。
    final am = authorRe.allMatches(m.group(0)!).isEmpty
        ? null
        : authorRe.allMatches(m.group(0)!).last;
    final tail = body.substring(m.end, (m.end + 2600).clamp(0, body.length));
    final km = kindRe.firstMatch(tail);
    items.add(HotItem(
      rank: int.tryParse(m.group(1)!) ?? items.length + 1,
      title: title,
      site: '晋江积分榜',
      author: am?.group(1)!.trim(),
      category: km?.group(1),
    ));
  }
  return (items: items, siteUpdated: null);
}

// ---------------------------------------------------------------- 17K 畅销榜

/// 解析 17K 小说 `/top/` 页的畅销榜（「热读榜」页签抓不到 Top100 整页时的兜底）。
///
/// 页面是服务端渲染的：每个榜单一个 `div.TABBOX`，标题在 `h2.tit`，
/// 条目在紧跟的 `ul.BOX > li`（`span.num` 是名次，第一个 `/book/<id>.html`
/// 链接的文字是书名）。同一个 TABBOX 里「全站 / 男生 / 女生」三个标签的
/// 列表会重复出现，只取第一个 `ul.BOX`。
///
/// 畅读榜缺失时依次退回「推荐票榜」「作品点击榜」—— 都属于「大家在读」
/// 的站内榜，好过整榜空着。
({List<HotItem> items, String? siteUpdated}) parse17kSalesBoard(String body) {
  final doc = parseHtml(body);
  Element? section;
  for (final keyword in const ['畅销榜', '推荐票榜', '作品点击榜']) {
    for (final box in doc.querySelectorAll('div.TABBOX')) {
      final head = textOf(box.querySelector('h2.tit'));
      if (head.contains(keyword)) {
        section = box;
        break;
      }
    }
    if (section != null) break;
  }
  final ul = section?.querySelector('ul.BOX') ?? doc.querySelector('ul.BOX');
  if (ul == null) return (items: const <HotItem>[], siteUpdated: null);

  final items = <HotItem>[];
  for (final li in ul.querySelectorAll('li')) {
    final numText = textOf(li.querySelector('span.num'));
    final rank = int.tryParse(numText.replaceAll(RegExp(r'[^0-9]'), '')) ??
        items.length + 1;
    String? title;
    for (final a in li.querySelectorAll('a')) {
      final href = a.attributes['href'] ?? '';
      if (!href.contains('/book/')) continue;
      final t = textOf(a);
      // 封面链接（class=book）里塞的是简介，不是书名：取第一个短文本
      if (t.isEmpty || t.length > 40) continue;
      title = _stripEllipsis(t);
      break;
    }
    if (title == null || title.isEmpty) continue;
    final img = li.querySelector('img');
    items.add(HotItem(
      rank: rank,
      title: title,
      site: '17K小说',
      cover: img?.attributes['src'],
    ));
  }

  // 「更多 更新时间：2026-11-14 14:20」——榜单站点自己的更新时间，原样带上
  String? updated;
  final m =
      RegExp(r'更新时间\s*[:：]\s*([0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2})')
          .firstMatch(ul.text);
  if (m != null) updated = m.group(1);

  return (items: items, siteUpdated: updated);
}

/// 去掉榜单为了排版加在长书名末尾的省略号（匹配时要还原成前缀）。
String _stripEllipsis(String s) =>
    s.replaceFirst(RegExp(r'\s*(\.{2,}|…+)\s*$'), '').trim();
