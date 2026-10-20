// 书源列表的搜索 / 过滤：防抖 + 结果缓存。
//
// 1000+ 条书源时，「每敲一个字符就 setState + 全表 where + 排序」会连续
// 丢掉几帧；这里把三件事拆开：
//  1. 防抖（[kSourceSearchDebounce]）：连续输入只在停顿后算一次；
//  2. 结果缓存：只有「查询词 / 仅启用 / 书源列表实例」三者之一变了才重算，
//     其余 rebuild 直接复用上一次的 List；
//  3. 不排序：书源列表本身是稳定的入库顺序，用户在列表里认的就是这个顺序，
//     过滤只做筛选，结果保序，省掉每次按键的 O(k log k)。
import 'dart:async';

import 'package:shuangyue/legado/models.dart';

/// 搜索防抖时长：250–300ms 区间取中值，比连续按键慢一拍，仍早于卡顿体感。
const Duration kSourceSearchDebounce = Duration(milliseconds: 260);

/// 书源列表的搜索 / 过滤状态机（纯逻辑，不依赖 Widget，便于单测）。
class SourceListFilter {
  SourceListFilter({this.debounce = kSourceSearchDebounce});

  final Duration debounce;
  Timer? _timer;

  /// 输入框里的实时文本（可能还没生效）。
  String _input = '';

  /// 已生效（防抖后、已做小写与去空白）的查询词；空串表示不过滤。
  String _query = '';

  /// 是否只看已启用。
  bool _enabledOnly = false;

  // 结果缓存：键 = (视图实例, 查询词, 仅启用)
  List<BookSource>? _cache;
  List<BookSource>? _cacheView;
  String? _cacheQuery;
  bool? _cacheEnabledOnly;

  /// 仅供测试：实际执行过滤的次数（命中缓存时不该增加）。
  int debugComputeCount = 0;

  /// 输入框实时文本。
  String get input => _input;

  /// 已生效的查询词（小写）。
  String get query => _query;

  bool get enabledOnly => _enabledOnly;

  /// 是否处于过滤状态（有查询词或只看启用）。
  bool get isActive => _query.isNotEmpty || _enabledOnly;

  /// 输入变化：空串立即生效（清空搜索不必等），其余等防抖。
  ///
  /// [onApplied] 只在实际生效时回调一次（查询词没变就什么都不做，
  /// 连 Timer 都不建）。
  void onInput(String text, void Function() onApplied) {
    _input = text;
    final next = text.trim().toLowerCase();
    // 先撤掉待触发的计时器：用户「输入 → 立刻清空」时，
    // 不能等防抖到点又把旧词过滤一遍（表现是「明明清空了还在筛」）。
    _timer?.cancel();
    _timer = null;
    if (next.isEmpty) {
      // 本来就没有过滤条件 → 列表不用重建。
      if (_query.isEmpty) return;
      _query = '';
      onApplied();
      return;
    }
    if (next == _query) return;
    _timer = Timer(debounce, () {
      // 计时器期间可能又被清空 / 覆盖，以最新输入为准。
      final latest = _input.trim().toLowerCase();
      if (latest == _query) return;
      _query = latest;
      onApplied();
    });
  }

  /// 切换「仅看已启用」。
  void setEnabledOnly(bool value, void Function() onApplied) {
    if (_enabledOnly == value) return;
    _enabledOnly = value;
    onApplied();
  }

  /// 清空过滤条件（退出搜索时用）。
  void reset() {
    _timer?.cancel();
    _timer = null;
    _input = '';
    _query = '';
    _enabledOnly = false;
  }

  /// 对稳定视图 [view] 应用当前条件。
  ///
  /// [view] 必须是 `SourceStore.sourcesView` 这种「未变更时同一实例」的列表，
  /// 否则缓存永远命中不了。
  List<BookSource> apply(List<BookSource> view) {
    if (identical(view, _cacheView) &&
        _cacheQuery == _query &&
        _cacheEnabledOnly == _enabledOnly &&
        _cache != null) {
      return _cache!;
    }
    debugComputeCount++;
    _cacheView = view;
    _cacheQuery = _query;
    _cacheEnabledOnly = _enabledOnly;
    if (!isActive) {
      // 不过滤：直接把原视图当成结果，零拷贝。
      return _cache = view;
    }
    final out = <BookSource>[];
    for (final s in view) {
      if (_enabledOnly && !s.enabled) continue;
      if (_query.isNotEmpty && !_matches(s, _query)) continue;
      out.add(s);
    }
    return _cache = List<BookSource>.unmodifiable(out);
  }

  /// 名称 / 地址 / 分组 / 备注 任一命中即算匹配（大小写不敏感）。
  static bool _matches(BookSource s, String q) {
    if (s.bookSourceName.toLowerCase().contains(q)) return true;
    if (s.bookSourceUrl.toLowerCase().contains(q)) return true;
    final group = s.bookSourceGroup;
    if (group != null && group.toLowerCase().contains(q)) return true;
    final comment = s.bookSourceComment;
    if (comment != null && comment.toLowerCase().contains(q)) return true;
    return false;
  }

  /// 释放防抖计时器。
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }
}
