// 桌宠成长值与全局联动。
//
// 经验**不直接存**：阅读那部分由 [StatsStore.totalSeconds] 现算
// （每 30 秒阅读 = 1 点），其他动作的奖励单独记一个整数。
// 这样「换阈值」或「统计被清零」都不会让存档和显示打架。
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/stats_store.dart';
import 'pet_event.dart';
import 'pet_painter.dart';

/// 升阶阈值，下标即阶段。改这里就能整体调难度。
const List<int> kPetStageExp = [0, 150, 600, 1800];

/// 每 30 秒阅读折算的成长值。
const int kSecondsPerExp = 30;

PetStage stageForExp(int exp) {
  var s = PetStage.drop;
  for (var i = 0; i < kPetStageExp.length; i++) {
    if (exp >= kPetStageExp[i]) s = PetStage.values[i];
  }
  return s;
}

class PetStore extends ChangeNotifier {
  PetStore(
      {int Function()? readingSeconds, SharedPreferences? Function()? prefs})
      : _readingSeconds = readingSeconds ?? _defaultReadingSeconds,
        _prefs = prefs ?? _defaultPrefs;

  /// 共享偏好来源。main 启动时接到 [AppStore] 上 ——
  /// 用注入而不是直接 import，是为了不让 store ↔ pet_store 互相引用。
  static SharedPreferences? Function()? prefsProvider;

  static SharedPreferences? _defaultPrefs() => prefsProvider?.call();

  static int _defaultReadingSeconds() => StatsStore.I.totalSeconds;

  /// 进程内共享实例。
  static PetStore? shared;

  static PetStore get I => shared ??= PetStore()..load();

  final int Function() _readingSeconds;
  final SharedPreferences? Function() _prefs;

  int _bonusExp = 0; // 非阅读动作的奖励
  int _petCount = 0; // 被摸次数
  DateTime? _lastSeen; // 上次「打招呼」的时间
  DateTime? _lastPetAt; // 上次被摸（冷却用，不持久化）
  bool _enabled = true;
  PetMood _mood = PetMood.calm;
  DateTime? _moodUntil;
  PetStage? _lastStage;
  PetStage? _stageUpPending;

  String? _bubble;
  int _bubbleSeq = 0;
  final Map<PetAction, DateTime> _lastSaid = {};

  static const Duration _petCooldown = Duration(seconds: 20);

  /// 同一个动作的台词最小间隔。连续翻页不该把气泡刷成弹幕。
  static const Duration bubbleCooldown = Duration(seconds: 6);

  bool get enabled => _enabled;

  int get petCount => _petCount;

  int get exp => _readingSeconds() ~/ kSecondsPerExp + _bonusExp;

  PetStage get stage => stageForExp(exp);

  PetMood get mood => _mood;

  /// 当前要显示的台词；null 表示不说话。
  String? get bubble => _bubble;

  /// 气泡的变更序号。UI 拿它判断「是不是换了一句」，不能只看字符串。
  int get bubbleSeq => _bubbleSeq;

  void clearBubble() {
    if (_bubble == null) return;
    _bubble = null;
    _bubbleSeq++;
    notifyListeners();
  }

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
    final sp = _prefs();
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
    _prefs()?.setBool('petEnabled', v);
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
    _prefs()?.setInt('petLastSeen', now.millisecondsSinceEpoch);
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

  /// 全局联动的唯一入口：登记一次「用户做了什么」。
  ///
  /// 由 [reactionFor] 决定给多少经验、什么情绪、说不说话。
  void emit(PetAction a) {
    final r = reactionFor(a, stage);
    if (r.exp > 0) _bonusExp += r.exp;
    if (r.mood != null) setMood(r.mood!, const Duration(seconds: 3));
    if (r.lines.isNotEmpty) {
      final now = DateTime.now();
      final last = _lastSaid[a];
      // 连点同一个动作时限流：只涨经验，不重复刷气泡
      if (last == null || now.difference(last) >= bubbleCooldown) {
        _lastSaid[a] = now;
        _bubble = r.lines[_bubbleSeq % r.lines.length];
        _bubbleSeq++;
      }
    }
    if (a == PetAction.petTap) _petCount++;
    final sp = _prefs();
    if (r.exp > 0 || a == PetAction.petTap) {
      sp?.setInt('petBonusExp', _bonusExp);
      sp?.setInt('petCount', _petCount);
    }
    checkStage();
    notifyListeners();
  }

  /// 摸一下。有冷却防连点刷经验，返回是否真的生效。
  bool pet() {
    final now = DateTime.now();
    if (_lastPetAt != null && now.difference(_lastPetAt!) < _petCooldown) {
      return false;
    }
    _lastPetAt = now;
    emit(PetAction.petTap);
    return true;
  }

  void setMood(PetMood m, Duration d) {
    _mood = m;
    _moodUntil = DateTime.now().add(d);
    notifyListeners();
  }

  /// 情绪是否过期；由 widget 每帧调用，失效时顺手降回平静。
  bool tickMood() {
    if (_mood == PetMood.calm) return false;
    if (DateTime.now().isAfter(_moodUntil ?? DateTime(1970))) {
      _mood = PetMood.calm;
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 测试用：直接塞经验。刻意不碰 [_lastStage] —— 升阶播报的判定要留给
  /// [checkStage]，否则测试里永远跨不过门槛。
  @visibleForTesting
  void debugSetBonus(int v) => _bonusExp = v;
}
