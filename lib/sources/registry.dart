import '../legado/models.dart';
import 'douyinxs.dart';
import 'gdbzkz.dart';
import 'huangjinwu.dart';
import 'legado_source.dart';
import 'libahao.dart';
import 'local_source.dart';
import 'minyuan.dart';
import 'quanben.dart';
import 'sanyt.dart';
import 'shenwen.dart';
import 'shuku52.dart';
import 'source.dart';
import 'sudugu_cc.dart';
import 'suduguu.dart';
import 'sushujuan.dart';
import 'yewa.dart';

/// 内置固化书源（手写 Dart 适配器，永远启用，离线可读）。
///
/// 这些是爽阅的立身之本：不依赖任何外部 JSON，改版前也不会失效。
final List<NovelSource> builtinSources = <NovelSource>[
  YewaSource(),
  SuduGuuSource(),
  HuangJinWuSource(),
  Shuku52Source(),
  ShenwenSource(),
  SushujuanSource(),
  LibahaoSource(),
  MinyuanSource(),
  QuanbenSource(),
  GdbzkzSource(),
  DouyinxsSource(),
  SuduguCcSource(),
  SanytSource(),
];

/// 本地书源（TXT / EPUB）。放在固化源之后、导入源之前 ——
/// 它不参与搜索，只是让本地书能走同一条阅读 / 缓存 / 书签通路。
final LocalSource localSource = LocalSource();

/// 导入的「阅读 3.0」书源适配器（由 main.dart 在加载 SourceStore 后填充）。
final List<LegadoSource> _imported = <LegadoSource>[];

/// url → 已建好的适配器（复用，避免每次都重建 1000 个对象）。
final Map<String, LegadoSource> _byUrl = <String, LegadoSource>{};

/// [allSources] 的缓存（登记表变动时才重建）。
List<NovelSource>? _allCache;

/// id → 源的索引（按 id 反查原本是 O(n) 线性扫描）。
Map<String, NovelSource>? _byIdCache;

/// 用导入书源刷新登记表（启动时 / 书源管理页改动后调用）。
///
/// 会重建 [LegadoSource] 实例（内部持有 SourceStore 快照），因此幂等。
///
/// 1000+ 条书源时，**每次**重建上千个适配器是明显的卡顿来源（切一个开关
/// 就重建 1000 个对象）。这里按 url 复用：只有 BookSource 实例本身变了的
/// 才重建，其余沿用旧适配器 —— 改一条开关的成本从 O(全表) 降到 O(1)。
void syncImportedSources(List<BookSource> all,
    {bool Function(BookSource)? filter}) {
  final next = <LegadoSource>[];
  for (final s in all) {
    if (!(filter?.call(s) ?? true)) continue;
    final cached = _byUrl[s.bookSourceUrl];
    if (cached != null && identical(cached.source, s)) {
      next.add(cached);
    } else {
      final made = LegadoSource(s);
      _byUrl[s.bookSourceUrl] = made;
      next.add(made);
    }
  }
  // 被移除/停用的 url 要从复用表里清掉，否则地址再被启用时会拿到旧适配器。
  if (_byUrl.length > next.length) {
    final alive = {for (final s in next) s.id};
    _byUrl.removeWhere((url, _) => !alive.contains(url));
  }
  _imported
    ..clear()
    ..addAll(next);
  _allCache = null;
  _byIdCache = null;
}

/// 当前生效的导入书源。
List<LegadoSource> get importedSources => List.unmodifiable(_imported);

/// 全部可用书源：固化书源 + 本地书 + 已启用的导入书源。
///
/// 固化书源排在前面 —— 搜索结果里可信度更高，也让「换源」默认先试稳的。
/// 本地书源不参与搜索（[LocalSource.search] 恒空），排在哪都不影响结果。
///
/// 结果做了缓存：原来每次访问都新建一个上千元素的列表，而按 id 找源、
/// 渲染推荐位、切章节都会调它 —— 单是这些就够在低端机上卡出帧。
List<NovelSource> get allSources => _allCache ??= <NovelSource>[
      ...builtinSources,
      ..._imported,
      localSource,
    ];

/// 按 id 找书源（id 对 Legado 源即 bookSourceUrl）。
NovelSource? sourceById(String id) {
  final map = _byIdCache ??= <String, NovelSource>{
    for (final s in allSources) s.id: s,
  };
  return map[id];
}

/// 书源展示名（找不到时回退 id，便于「书源已删除」这类提示）。
String sourceNameOf(String id) => sourceById(id)?.name ?? id;

/// 仅固化书源（书源管理页展示用：导入书源单独一块）。
List<NovelSource> get hardcodedSources => List.unmodifiable(builtinSources);
