// 阅读统计：本地 JSON 持久化（总时长 / 每日时长 / 读完书数 / 连续天数）。
//
// 注：樱读的 BookmarkStore 在此被有意舍弃 —— 爽阅的 AppStore 早已用更完整的
// Bookmark（带 page + paragraph 双锚点）承载书签，没必要再存一份平行数据。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/native_bridge.dart';

/// 一块成就徽章：[met] 判断当前统计是否达标。
class ReadingBadge {
  ReadingBadge(this.id, this.name, this.hint, this.met);

  final String id;
  final String name; // 徽章墙 / 气泡里用的短名
  final String hint; // 徽章墙上的达标说明
  final bool Function(StatsStore) met;
}

/// 里程碑清单：连续天数 / 累计时长 / 读完书数。列表顺序即徽章墙展示顺序。
final List<ReadingBadge> kReadingBadges = [
  ReadingBadge('streak3', '三日之约', '连续阅读 3 天', (s) => s.streak >= 3),
  ReadingBadge('streak7', '七日不辍', '连续阅读 7 天', (s) => s.streak >= 7),
  ReadingBadge('streak14', '两周同行', '连续阅读 14 天', (s) => s.streak >= 14),
  ReadingBadge('streak30', '满月守护', '连续阅读 30 天', (s) => s.streak >= 30),
  ReadingBadge(
      'hours10', '十万秒', '累计阅读 10 小时', (s) => s.totalSeconds >= 36000),
  ReadingBadge(
      'hours50', '五十小时', '累计阅读 50 小时', (s) => s.totalSeconds >= 180000),
  ReadingBadge(
      'hours100', '百小时', '累计阅读 100 小时', (s) => s.totalSeconds >= 360000),
  ReadingBadge('books1', '开卷有益', '读完第一本书', (s) => s.finishedBooks >= 1),
  ReadingBadge('books10', '十卷在手', '读完 10 本', (s) => s.finishedBooks >= 10),
  ReadingBadge('books50', '半百书虫', '读完 50 本', (s) => s.finishedBooks >= 50),
];

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
  final Set<String> _badges = {};
  File? _file;
  Timer? _saveTimer;

  /// 已点亮的徽章 id。
  Set<String> get badges => Set.unmodifiable(_badges);

  /// 新徽章达成时的通知（main 注入桌宠联动，避免 data → pet 反向依赖）。
  static void Function(ReadingBadge)? onBadgeEarned;

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
          final bd = data['badges'];
          if (bd is List) {
            _badges.addAll(bd.map((e) => e.toString()));
          }
        }
      }
    } catch (_) {
      // 读取失败时从零开始
    }
    // 老存档没有 badges 字段：把已达标的里程碑**静默**回填（不庆祝），
    // 之后真正跨线时才冒泡。
    _checkBadges(celebrate: false);
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
    _checkBadges();
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
    _checkBadges();
    notifyListeners();
  }

  /// 对照里程碑表，把新达标的徽章入册。[celebrate]=false 时只回填不庆祝。
  void _checkBadges({bool celebrate = true}) {
    final fresh = <ReadingBadge>[];
    for (final b in kReadingBadges) {
      if (!_badges.contains(b.id) && b.met(this)) {
        _badges.add(b.id);
        fresh.add(b);
      }
    }
    if (fresh.isEmpty) return;
    _saveSoon();
    notifyListeners();
    if (celebrate) {
      // 按表序逐个通知，最后一条是最高档 —— 气泡只留一句，让最高的胜出
      for (final b in fresh) {
        onBadgeEarned?.call(b);
      }
    }
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
          'badges': _badges.toList(),
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
