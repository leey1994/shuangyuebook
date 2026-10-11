// 阅读统计：本地 JSON 持久化（总时长 / 每日时长 / 读完书数 / 连续天数）。
//
// 注：樱读的 BookmarkStore 在此被有意舍弃 —— 爽阅的 AppStore 早已用更完整的
// Bookmark（带 page + paragraph 双锚点）承载书签，没必要再存一份平行数据。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 阅读统计：总时长 / 每日时长 / 读完书数。
class StatsStore extends ChangeNotifier {
  StatsStore({AppDirs? dirsOverride}) : _dirsOverride = dirsOverride;

  /// 进程内共享实例（阅读器计时 / 统计页共用）。
  static StatsStore? shared;

  /// 便捷单例入口：未 load 过也能用（首次调用自动 load，失败则降级为不持久化）。
  static StatsStore get I => shared ??= StatsStore()..load();

  /// 单次累计上限（秒）：防止"锁屏挂着"把时长刷爆。
  static const int maxChunkSeconds = 90;

  final AppDirs? _dirsOverride;
  int _totalSeconds = 0;
  int _finishedBooks = 0;
  final Map<String, int> _days = {};
  File? _file;
  Timer? _saveTimer;

  int get totalSeconds => _totalSeconds;
  int get finishedBooks => _finishedBooks;

  /// 每日阅读秒数（按日期字符串 'YYYY-MM-DD'）。
  Map<String, int> get days => Map.unmodifiable(_days);

  /// 累计有阅读记录的天数。
  int get readDays => _days.length;

  /// 连续阅读天数（截至今天 / 昨天）。
  int get streak {
    var s = 0;
    var day = _dateKey(DateTime.now());
    // 今天没读则从昨天起算（当天尚未开始不影响连续记录）
    if (!_days.containsKey(day)) {
      day = _dateKey(DateTime.now().subtract(const Duration(days: 1)));
    }
    while (_days.containsKey(day) && _days[day]! > 0) {
      s++;
      day = _dateKey(DateTime.parse(day).subtract(const Duration(days: 1)));
    }
    return s;
  }

  static String _dateKey(DateTime d) => '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  /// 最近 [n] 天的阅读秒数（含今天，从早到晚）。
  List<(String, int)> recentDays(int n) {
    final out = <(String, int)>[];
    final now = DateTime.now();
    for (var i = n - 1; i >= 0; i--) {
      final d = now.subtract(Duration(days: i));
      final key = _dateKey(d);
      out.add((key, _days[key] ?? 0));
    }
    return out;
  }

  Future<void> load() async {
    final dirs = _dirsOverride ?? await NativeBridge.appDirs();
    _file = File('${dirs.files}/reading_stats.json');
    try {
      if (await _file!.exists()) {
        final data = jsonDecode(await _file!.readAsString());
        if (data is Map) {
          _totalSeconds = (data['totalSeconds'] as num?)?.toInt() ?? 0;
          _finishedBooks = (data['finishedBooks'] as num?)?.toInt() ?? 0;
          final days = data['days'];
          if (days is Map) {
            days.forEach((k, v) {
              if (v is num) _days[k.toString()] = v.toInt();
            });
          }
        }
      }
    } catch (_) {
      // 读取失败时从零开始
    }
    notifyListeners();
  }

  /// 记录一段阅读时长（秒；0 或负数忽略，超过上限截断）。
  void addReadingSeconds(int seconds) {
    if (seconds <= 0) return;
    final s = seconds > maxChunkSeconds ? maxChunkSeconds : seconds;
    _totalSeconds += s;
    final key = _dateKey(DateTime.now());
    _days[key] = (_days[key] ?? 0) + s;
    _saveSoon();
    notifyListeners();
  }

  /// 仅供测试：向指定日期（YYYY-MM-DD）注入阅读时长。
  @visibleForTesting
  void debugAddSecondsForDate(String dateKey, int seconds) {
    if (seconds <= 0) return;
    _totalSeconds += seconds;
    _days[dateKey] = (_days[dateKey] ?? 0) + seconds;
  }

  void addFinishedBook() {
    _finishedBooks++;
    _saveSoon();
    notifyListeners();
  }

  void _saveSoon() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 500), () {
      unawaited(_save());
    });
  }

  /// 仅供测试：立即落盘（跳过防抖，消除时序脆弱）。
  @visibleForTesting
  Future<void> debugFlush() => _save();

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsString(
        jsonEncode({
          'version': 1,
          'totalSeconds': _totalSeconds,
          'finishedBooks': _finishedBooks,
          'days': _days,
        }),
      );
    } catch (_) {
      // 忽略保存失败
    }
  }

  @override
  void dispose() {
    _saveTimer?.cancel();
    super.dispose();
  }
}
