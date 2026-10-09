import '../legado/models.dart';
import 'banshanren.dart';
import 'huangjinwu.dart';
import 'legado_source.dart';
import 'libahao.dart';
import 'minyuan.dart';
import 'quanben.dart';
import 'shenwen.dart';
import 'shuku52.dart';
import 'source.dart';
import 'suduguu.dart';
import 'sushujuan.dart';
import 'yewa.dart';
import 'zzbook.dart';

/// 内置固化书源（手写 Dart 适配器，永远启用，离线可读）。
///
/// 这些是爽阅的立身之本：不依赖任何外部 JSON，改版前也不会失效。
final List<NovelSource> builtinSources = <NovelSource>[
  YewaSource(),
  SuduGuuSource(),
  HuangJinWuSource(),
  Shuku52Source(),
  BanshanrenSource(),
  ShenwenSource(),
  ZzbookSource(),
  SushujuanSource(),
  LibahaoSource(),
  MinyuanSource(),
  QuanbenSource(),
];

/// 导入的「阅读 3.0」书源适配器（由 main.dart 在加载 SourceStore 后填充）。
final List<LegadoSource> _imported = <LegadoSource>[];

/// 用导入书源刷新登记表（启动时 / 书源管理页改动后调用）。
///
/// 会重建 [LegadoSource] 实例（内部持有 SourceStore 快照），因此幂等。
void syncImportedSources(List<BookSource> all, {bool Function(BookSource)? filter}) {
  _imported
    ..clear()
    ..addAll([
      for (final s in all)
        if ((filter?.call(s) ?? true)) LegadoSource(s),
    ]);
}

/// 当前生效的导入书源。
List<LegadoSource> get importedSources => List.unmodifiable(_imported);

/// 全部可用书源：固化书源 + 已启用的导入书源。
///
/// 固化书源排在前面 —— 搜索结果里可信度更高，也让「换源」默认先试稳的。
List<NovelSource> get allSources => <NovelSource>[
      ...builtinSources,
      ..._imported,
    ];

/// 按 id 找书源（id 对 Legado 源即 bookSourceUrl）。
NovelSource? sourceById(String id) {
  for (final s in allSources) {
    if (s.id == id) return s;
  }
  return null;
}

/// 书源展示名（找不到时回退 id，便于「书源已删除」这类提示）。
String sourceNameOf(String id) => sourceById(id)?.name ?? id;

/// 仅固化书源（书源管理页展示用：导入书源单独一块）。
List<NovelSource> get hardcodedSources => List.unmodifiable(builtinSources);
