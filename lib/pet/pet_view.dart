// 桌宠「小墨」的活动区。
//
// 摆位规则：
//   - **阅读界面钉死在顶部那条窄带里**（状态栏那一行），不乱跑 ——
//     读正文时要专注，且窄带不能挡住任何按钮；
//   - **其它界面在整屏范围内自由溜达**，会躲着屏幕挖孔（前置摄像头）走，
//     凑到挖孔附近还会探头看一眼。
//
// 气泡永远贴在**旁边**而不是头顶：窄带只有 26~30px，往下浮会盖住窗口按钮。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../data/shelf_sort.dart';
import '../store.dart';
import '../ui/system_metrics.dart';
import 'pet_lines.dart';
import 'pet_painter.dart';
import 'pet_store.dart';

/// 是否钉在顶部窄带。阅读器进入时置 true，退出置回 false。
///
/// 做成全局开关而不是逐层传参：窄带包住所有路由，路由自己往里塞参数不现实。
final ValueNotifier<bool> petPinned = ValueNotifier<bool>(false);

/// 纵向落点：给定归一化进度 [posY]（0=顶 1=底），算出桌宠上沿的 y。
///
/// 抽成纯函数是因为这条不变量最容易被改坏 —— 桌面标题栏里活动区高度就等于
/// 窄带（26px），此时若仍按「整屏溜达」去算，top 会变成负数，桌宠直接飞出屏幕。
///
/// 返回的 top 恒在 `[0, areaH - h]` 内：越不出活动区。
double petTopFor({
  required double areaH,
  required double h,
  required bool pinned,
  required double posY,
}) {
  // 只有「活动区明显比窄带高」时才有地方溜达，否则一律贴着顶部窄带。
  if (pinned || areaH <= h * 2) return 0;
  // 两种模式必须分开算：钉住时若还拿 `areaH - h - 18` 当插值端点，
  // 在桌面标题栏那种「区域高 26、桌宠高 26」的场合端点是负数，桌宠直接飞出屏幕。
  final bottom = areaH - h - 18;
  return bottom * posY.clamp(0.0, 1.0);
}

/// 桌宠「小墨」的活动区。
///
/// 宽度策略很关键：气泡必须**留在这个部件自己的范围内**，绝不能画到外面去。
/// 所以窄空间（桌面标题栏的 Row）下本部件会占掉一段固定宽度把气泡包住；
/// 宽空间（安卓整屏）下则铺满，气泡按宠物所在的一侧自动换边。
class PetBar extends StatefulWidget {
  const PetBar({super.key, this.height});

  /// 窄带高度。默认取预留的状态栏高度；桌面端没有状态栏，给一个同量级的窄带。
  final double? height;

  /// 桌面端没人拦着状态栏高度，给条窄带，位置语义一致。
  static const double fallbackHeight = 26;

  /// 活动带该有多高。安卓取预留的状态栏高度，桌面回落到窄带。
  static double defaultHeight() =>
      SystemMetrics.topInset > 0 ? SystemMetrics.topInset : fallbackHeight;

  @override
  State<PetBar> createState() => _PetBarState();
}

/// 自己玩的小动作。
enum _Play { still, hop, spin, stretch, peek, yawn, shake, wave }

class _PetBarState extends State<PetBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _rnd = math.Random();
  final _store = AppStore.I;
  final _pet = PetStore.I;
  int _turn = 0;

  String? _line;
  Timer? _hideLine;
  Timer? _restTimer;
  Timer? _idleTimer;
  Timer? _rebound;
  Timer? _wanderTimer;
  Timer? _playTimer;
  Timer? _stageTimer;

  double _phase = 0;
  double _squash = 0;

  // 位置：0..1 归一化。_to 是目标，_walkT 是这一段的进度。
  double _fromX = 1, _toX = 1, _fromY = 1, _toY = 1, _walkT = 1;
  // 溜达明显放慢：原来 1.05s 走完全程，看着像被弹出去
  static const double _walkDur = 2.6;

  _Play _play = _Play.still;
  double _playT = 0;
  static const _kPlays = [
    _Play.hop,
    _Play.stretch,
    _Play.spin,
    _Play.peek,
    _Play.yawn,
    _Play.shake,
  ];

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      final t = elapsed.inMicroseconds / 1e6;
      final dt = t - _phase;
      _phase = t;
      _advanceWalk(dt);
      if (_play != _Play.still) _playT += dt;
      _pet.tickMood();
      if (mounted) setState(() {});
    })
      ..start();
    _pet.addListener(_onPet);
    petPinned.addListener(_onPinnedChanged);
    _stageTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _pet.checkStage();
      final up = _pet.takeStageUp();
      if (up != null) _say(stageUpScene(up));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
    _restTimer = Timer(const Duration(minutes: 45), () => _say(restScene));
    _armIdle();
    _armWander();
    _armPlay();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pet.removeListener(_onPet);
    petPinned.removeListener(_onPinnedChanged);
    _hideLine?.cancel();
    _restTimer?.cancel();
    _idleTimer?.cancel();
    _rebound?.cancel();
    _wanderTimer?.cancel();
    _playTimer?.cancel();
    _stageTimer?.cancel();
    super.dispose();
  }

  /// 阅读器进出：钉住 / 放开。
  void _onPinnedChanged() {
    if (!mounted) return;
    // 钉住时把 y 收到底部那条带子里；放开后重新选一个落点
    if (petPinned.value) {
      _step(x: _rnd.nextDouble(), y: 1);
    } else {
      _step(x: _rnd.nextDouble(), y: 0.25 + _rnd.nextDouble() * 0.55);
    }
  }

  void _onPet() {
    if (!mounted) return;
    final line = _pet.bubble;
    if (line == null || line == _line) return;
    _show(line);
  }

  double get _h => widget.height ?? PetBar.defaultHeight();

  // ---------- 溜达 ----------

  void _armWander() {
    _wanderTimer?.cancel();
    // 5~11 秒挪一次，节奏不规律才像活的
    _wanderTimer = Timer(
      Duration(milliseconds: 5000 + _rnd.nextInt(6000)),
      () {
        _wander();
        _armWander();
      },
    );
  }

  void _wander() {
    if (!mounted) return;
    final pinned = petPinned.value;
    // 钉住时只沿窄带走；放开后整屏范围内溜达
    final x = _rnd.nextDouble();
    final y = pinned ? 1.0 : 0.22 + _rnd.nextDouble() * 0.58;
    _step(x: x, y: y);
  }

  /// 避开挖孔：落点落在摄像头附近就往旁边让，让完再挑一个落点。
  void _step({required double x, required double y}) {
    final hole = _store.punchHole;
    var nx = x;
    if (hole != PunchHole.none) {
      final anchor = hole.anchorX;
      if ((nx - anchor).abs() < hole.keepOut) {
        // 往远离挖孔的一侧推；越界就翻到另一侧
        final dir = nx >= anchor ? 1.0 : -1.0;
        nx = (anchor + dir * hole.keepOut * 1.25).clamp(0.0, 1.0);
        if ((nx - anchor).abs() < hole.keepOut) {
          nx = (anchor - dir * hole.keepOut * 1.25).clamp(0.0, 1.0);
        }
      }
    }
    // 太近就不动，免得原地抖
    if ((nx - _toX).abs() < 0.14 && (y - _toY).abs() < 0.12) return;
    setState(() {
      _fromX = _walkT >= 1 ? _toX : _fromX + (_toX - _fromX) * _walkT;
      _fromY = _walkT >= 1 ? _toY : _fromY + (_toY - _fromY) * _walkT;
      _toX = nx;
      _toY = y;
      _walkT = 0;
    });
    // 凑到挖孔附近时探头看一眼 —— 结合挖孔屏的小趣味
    if (hole != PunchHole.none &&
        (nx - hole.anchorX).abs() < hole.keepOut * 1.6) {
      _play = _Play.peek;
      _playT = 0;
    }
  }

  void _advanceWalk(double dt) {
    if (_walkT >= 1) return;
    _walkT = (_walkT + dt / _walkDur).clamp(0.0, 1.0);
  }

  /// 当前实际位置（插值，用来算朝向与气泡开哪一侧）。
  double get _posX => _fromX + (_toX - _fromX) * _walkT;
  double get _posY => _fromY + (_toY - _fromY) * _walkT;

  /// 走的方向：+1 向右。朝右时把整只翻过来，尾巴才在身后。
  int get _facing => (_toX - _fromX) >= 0 ? 1 : -1;

  // ---------- 自己玩 ----------

  void _armPlay() {
    _playTimer?.cancel();
    _playTimer = Timer(
      Duration(milliseconds: 6000 + _rnd.nextInt(9000)),
      () {
        if (!mounted || !_pet.enabled) return;
        _play = _kPlays[_rnd.nextInt(_kPlays.length)];
        _playT = 0;
        setState(() {});
        _playTimer = Timer(
          Duration(milliseconds: 1300 + _rnd.nextInt(1100)),
          () {
            if (!mounted) return;
            setState(() => _play = _Play.still);
          },
        );
        _armPlay();
      },
    );
  }

  // ---------- 台词 ----------

  void _greet() {
    final days = _pet.greet();
    if (days == null) return;
    _say(days >= 2 ? absenceScene(days) : greetingScene(DateTime.now()));
  }

  void _say(PetScene scene) => _show(petLine(scene, turn: _turn++));

  void _show(String text) {
    if (!mounted) return;
    _hideLine?.cancel();
    setState(() => _line = text);
    _hideLine = Timer(const Duration(milliseconds: 4200), () {
      if (!mounted) return;
      setState(() => _line = null);
      _pet.clearBubble();
    });
    _armIdle();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 4), () => _say(idleScene));
  }

  void _onTap() {
    if (!_pet.pet()) return;
    _bounce();
    _play = _Play.still;
  }

  /// 压扁—回弹一下就停：一段带阻尼的正弦。
  void _bounce() {
    _rebound?.cancel();
    var t = 0.0;
    _squash = 0.45;
    _rebound = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      t += 0.016;
      _squash = 0.45 * math.cos(t * 12) * (1 - t / 0.5);
      if (t >= 0.5) {
        timer.cancel();
        _squash = 0;
      }
      if (mounted) setState(() {});
    });
  }

  /// 当前小动作带来的位移 / 旋转 / 压扁，以及覆盖用的情绪。
  ({Offset shift, double rotate, double squash, PetMood? mood}) _pose(
      double h) {
    final t = _playT.clamp(0.0, 1.0);
    switch (_play) {
      case _Play.hop:
        final lift = math.sin(t * math.pi * 2).abs();
        return (
          shift: Offset(0, -lift * h * 0.85),
          rotate: 0,
          squash: -lift * 0.30,
          mood: null,
        );
      case _Play.spin:
        return (
          shift: Offset.zero,
          rotate: t * math.pi * 2,
          squash: 0,
          mood: null
        );
      case _Play.stretch:
        final s = math.sin(t * math.pi);
        return (
          shift: Offset(0, -s * h * 0.12),
          rotate: 0,
          squash: s * 0.5,
          mood: null,
        );
      case _Play.peek:
        final s = math.sin(t * math.pi);
        return (
          shift: Offset(0, -s * h * 0.30),
          rotate: 0,
          squash: -s * 0.42,
          mood: PetMood.sleep,
        );
      case _Play.yawn:
        final s = math.sin(t * math.pi);
        return (
          shift: Offset(0, -s * h * 0.10),
          rotate: s * 0.06,
          squash: s * 0.22,
          mood: PetMood.sleep,
        );
      case _Play.shake:
        final s = math.sin(t * math.pi * 4);
        return (
          shift: Offset(s * h * 0.10, 0),
          rotate: s * 0.16,
          squash: 0,
          mood: PetMood.cheer
        );
      case _Play.wave:
        final s = math.sin(t * math.pi);
        return (
          shift: Offset(0, -s * h * 0.18),
          rotate: s * 0.10,
          squash: 0,
          mood: PetMood.cheer
        );
      case _Play.still:
        return (shift: Offset.zero, rotate: 0, squash: 0, mood: null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_pet.enabled) return const SizedBox.shrink();
    final h = _h;
    final scheme = Theme.of(context).colorScheme;
    final m = _phase % 3.9;
    final blink = m < 0.12 || (m > 0.30 && m < 0.42);
    final pose = _pose(h);

    return ValueListenableBuilder<bool>(
      valueListenable: petPinned,
      builder: (context, pinned, _) {
        return LayoutBuilder(
          builder: (context, box) {
            final pw = h * 1.35 + 20;
            final bounded = box.maxWidth.isFinite;
            final areaW = bounded ? box.maxWidth : pw + 260;
            final areaH = box.maxHeight.isFinite ? box.maxHeight : h;
            final petLeft = 6 + (areaW - 12 - pw) * _posX;
            final petTop = petTopFor(
              areaH: areaH,
              h: h,
              pinned: pinned,
              posY: _posY,
            );
            final openRight = _posX < 0.45;
            final room = openRight
                ? areaW - 14 - (petLeft + pw + 10)
                : (petLeft - 10) - 14;
            final maxBubble = room.clamp(80.0, 236.0).toDouble();
            // 气泡贴着宠物走，但不能顶出活动区（否则被外层 Stack 裁掉）
            final bubbleTop = (petTop + h * 0.45 - 14)
                .clamp(2.0, math.max(2.0, areaH - 36))
                .toDouble();

            return SizedBox(
              height: bounded ? areaH : h,
              width: areaW,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  if (_line != null)
                    Positioned(
                      left: openRight ? petLeft + pw + 10 : null,
                      right: openRight ? null : areaW - petLeft + 10,
                      // 贴着窄带上沿往下长：往上是屏幕边缘 / 窗口标题栏
                      top: bubbleTop,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(maxWidth: maxBubble),
                        child: _bubble(_line!, scheme),
                      ),
                    ),
                  Positioned(
                    // 用普通 Positioned：位置由 _walkT 每帧插值给出，
                    // 再套一层 AnimatedPositioned 等于双重缓动，会永远追不上。
                    left: petLeft,
                    top: petTop,
                    child: SizedBox(
                      width: pw,
                      height: h,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // 触摸区向下多探 18px：窄带只有 26px 高，直接拿它当热区太难点
                          Positioned(
                            left: 0,
                            right: 0,
                            top: 0,
                            height: h + 18,
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _onTap,
                              child: Transform.translate(
                                offset: pose.shift,
                                child: Transform.rotate(
                                  angle: pose.rotate,
                                  child: Transform.scale(
                                    scaleX: _facing * (1 + pose.squash * 0.16),
                                    child: CustomPaint(
                                      size: Size(pw, h),
                                      painter: PetPainter(
                                        stage: _pet.stage,
                                        mood: pose.mood ?? _pet.mood,
                                        phase: _phase,
                                        squash: _squash + pose.squash,
                                        blink: blink,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// 半透明浮动气泡：贴在宠物那一侧，与它齐平，不压在头顶。
  Widget _bubble(String text, ColorScheme scheme) {
    final fill = scheme.surface.withValues(alpha: 0.86);
    return TweenAnimationBuilder<double>(
      key: ValueKey(text),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => Opacity(
        opacity: t,
        child: Transform.scale(
          alignment: Alignment.centerLeft,
          scale: 0.92 + 0.08 * t,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(
              color: fill,
              borderRadius: BorderRadius.circular(11),
              border: Border.all(
                  color: scheme.outlineVariant.withValues(alpha: .7)),
            ),
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.2,
                color: scheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
