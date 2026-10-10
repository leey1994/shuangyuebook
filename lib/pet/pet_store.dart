// 桌宠成长值。
//
// 经验**不直接存**：阅读那部分由 [StatsStore.totalSeconds] 现算
// （每 30 秒阅读 = 1 点），只有搜索 / 抚摸这类小奖励单独记一个整数。
// 这样「换阈值」或「统计被清零」都不会让存档和显示打架。
import 'package:flutter/foundation.dart';

import '../data/stats_store.dart';
import '../store.dart';
import 'pet_painter.dart';

/// 升阶阈值，下标即阶段。改这里就能整体调难度。
const List<int> kPetStageExp = [0, 150, 600, 1800];

PetStage stageForExp(int exp) {
  var s = PetStage.drop;
  for (var i = 0; i < kPetStageExp.length; i++) {
    if (exp >= kPetStageExp[i]) s = PetStage.values[i];
  }
  return s;
}

/// 每 30 秒阅读折算的成长值。
const int kSecondsPerExp = 30;

class PetStore extends ChangeNotifier {
  PetStore({int Function()? readingSeconds})
      : _readingSeconds = readingSeconds ?? _defaultReadingSeconds;

  static int _defaultReadingSeconds() => StatsStore.I.totalSeconds;

  /// 进程内共享实例。
  static PetStore? shared;

  static PetStore get I => shared ??= PetStore()..load();

  final int Function() _readingSeconds;

  int _bonusExp = 0; // 搜索 / 抚摸等非阅读奖励
  int _petCount = 0; // 被摸次数（台词会用到）
  DateTime? _lastSeen; // 上次「打招呼」的时间
  DateTime? _lastPetAt; // 上次被摸（冷却用，不持久化）
  bool _enabled = true;
  PetMood _mood = PetMood.calm;
  PetStage? _stageUpPending;

  static const Duration _petCooldown = Duration(seconds: 20);

  bool get enabled => _enabled;

  int get petCount => _petCount;

  int get exp => _readingSeconds() ~/ kSecondsPerExp + _bonusExp;

  PetStage get stage => stageForExp(exp);

  PetMood get mood => _mood;

  /// 有待播报的升阶（取走后清空）。
  PetStage? takeStageUp() {
    final s = _stageUpPending;
    _stageUpPending = null;
    return s;
  }

  /// 距下一阶还差多少；已满级返回 0。
  int get toNextStage {
    final next = stage.index + 1;
    if (next >= kPetStageExp.length) return 0;
    return kPetStageExp[next] - exp;
  }

  /// 当前阶内的进度 0..1（满级恒为 1）。
  double get stageProgress {
    final i = stage.index;
    if (i >= kPetStageExp.length - 1) return 1;
    final lo = kPetStageExp[i];
    final hi = kPetStageExp[i + 1];
    return ((exp - lo) / (hi - lo)).clamp(0.0, 1.0);
  }

  void load() {
    final sp = AppStore.I.sp;
    if (sp == null) return;
    _bonusExp = sp.getInt('petBonusExp') ?? 0;
    _petCount = sp.getInt('petCount') ?? 0;
    _enabled = sp.getBool('petEnabled') ?? true;
    final ms = sp.getInt('petLastSeen');
    _lastSeen = ms == null ? null : DateTime.fromMillisecondsSinceEpoch(ms);
    // 首次加载按当前存档对齐，避免把历史进度当成「刚刚升阶」弹一次
    _lastStage = stage;
  }

  void setEnabled(bool v) {
    _enabled = v;
    AppStore.I.sp?.setBool('petEnabled', v);
    notifyListeners();
  }

  /// 打招呼：返回「距上次打开过了几天」，同时记下本次时间。
  int markSeen() {
    final now = DateTime.now();
    final days = _lastSeen == null
        ? 0
        : DateTime(now.year, now.month, now.day)
            .difference(
                DateTime(_lastSeen!.year, _lastSeen!.month, _lastSeen!.day))
            .inDays;
    _lastSeen = now;
    AppStore.I.sp?.setInt('petLastSeen', now.millisecondsSinceEpoch);
    return days < 0 ? 0 : days;
  }

  bool _greeted = false;

  /// [markSeen] 的会话版：同一进程只认第一次，路由来回切不会反复重置久别天数。
  /// 已经打过招呼返回 null。
  int? greet() {
    if (_greeted) return null;
    _greeted = true;
    return markSeen();
  }

  /// 比对当前阶位，跨过门槛就记一次待播报的升阶。
  void checkStage() {
    final s = stage;
    final prev = _lastStage;
    if (prev == null) {
      _lastStage = s;
      return;
    }
    if (s == prev) return;
    _lastStage = s;
    _stageUpPending = s;
    notifyListeners();
  }

  /// 摸一下。有冷却防止连点刷经验，返回是否真的生效。
  bool pet() {
    final now = DateTime.now();
    if (_lastPetAt != null && now.difference(_lastPetAt!) < _petCooldown) {
      return false;
    }
    _lastPetAt = now;
    _petCount++;
    _bonusExp += 1;
    setMood(PetMood.cheer, const Duration(seconds: 2));
    _commit();
    return true;
  }

  /// 从搜索结果里点开一本书：给得比摸一下多，因为它真的帮你找到了东西。
  void searchOpened() {
    _bonusExp += 15;
    setMood(PetMood.cheer, const Duration(seconds: 3));
    _commit();
  }

  void setMood(PetMood m, Duration d) {
    _mood = m;
    _moodUntil = DateTime.now().add(d);
    notifyListeners();
  }

  DateTime? _moodUntil;

  /// 情绪是否过期；由 widget 每帧调用，失效时顺手降回平静。
  bool tickMood() {
    if (_mood == PetMood.calm) return false;
    if (_moodUntil == null || DateTime.now().isAfter(_moodUntil!)) {
      _mood = PetMood.calm;
      notifyListeners();
      return true;
    }
    return false;
  }

  void _commit() {
    AppStore.I.sp?.setInt('petBonusExp', _bonusExp);
    AppStore.I.sp?.setInt('petCount', _petCount);
    checkStage();
  }

  PetStage? _lastStage;

  /// 测试用：直接塞经验。刻意不碰 [_lastStage] —— 升阶播报的判定要留给
  /// [checkStage]，否则测试里永远跨不过门槛。
  @visibleForTesting
  void debugSetBonus(int v) => _bonusExp = v;
}
