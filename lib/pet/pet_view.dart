// 桌宠「小墨」的活动区。
//
// 落在顶部那条预留留白里（安卓在状态栏下方、桌面在标题栏里），所以体型按高度算
// 而不是按宽度，天然就是「很小的一只」。
//
// 三件事：
//   1) 会游走 —— 沿预留带随机换位置，走路时朝向会跟着翻；
//   2) 会自己玩 —— 没人理它也自己跳、翻、伸懒腰、打哈欠；
//   3) 说话在**旁边**而不是头顶 —— 头顶是屏幕边缘/标题栏，往下浮会盖住窗口按钮。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ui/system_metrics.dart';
import 'pet_lines.dart';
import 'pet_painter.dart';
import 'pet_store.dart';

/// 宠物活动带。
///
/// 宽度策略很关键：气泡必须**留在这个部件自己的范围内**，绝不能画到外面去。
/// 所以窄空间（桌面标题栏）下本部件会占掉一段固定宽度把气泡包住；
/// 宽空间（安卓整条窄带）下则铺满，气泡按宠物所在的一侧自动换边。
class PetBar extends StatefulWidget {
  const PetBar({super.key, this.height, this.wander = true});

  /// 活动带高度。默认取预留的状态栏高度；桌面端没有状态栏，给一个同量级的窄带。
  final double? height;

  /// 是否沿预留带随机游走。窄条里关掉，免得它晃到不该去的地方。
  final bool wander;

  /// 桌面端没人拦着状态栏高度，给条窄带，位置语义一致。
  static const double fallbackHeight = 26;

  /// 活动带该有多高。安卓取预留的状态栏高度，桌面回落到窄带。
  ///
  /// 阅读器把同一条留白补成正文的上边距（见 `_reservedTop`），两处必须走
  /// 同一个数 —— 否则桌面端宠物会压在正文上。
  static double defaultHeight() =>
      SystemMetrics.topInset > 0 ? SystemMetrics.topInset : fallbackHeight;

  @override
  State<PetBar> createState() => _PetBarState();
}

/// 自己玩的小动作。
enum _Play { still, hop, spin, stretch, peek, yawn, shake }

class _PetBarState extends State<PetBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _pet = PetStore.I;
  final _rnd = math.Random();
  int _turn = 0; // 同场景内换台词的轮次

  String? _line;
  Timer? _hideLine;
  Timer? _restTimer;
  Timer? _idleTimer;
  Timer? _rebound;
  Timer? _wanderTimer;
  Timer? _playTimer;

  double _phase = 0;
  double _squash = 0;

  // 游走：_to 是目标位置（0 最左 .. 1 最右），_walkT 是这一段的进度
  double _from = 1, _to = 1, _walkT = 1;
  static const double _walkDur = 1.05;

  // 玩耍：_play + _playT（秒）
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
    // 阶位主要由阅读时长推动，而这个值是现算的 —— 每秒比对一次即可
    Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _pet.checkStage();
      final up = _pet.takeStageUp();
      if (up != null) _say(stageUpScene(up));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _greet());
    // 久坐提醒 / 摸鱼提醒
    _restTimer = Timer(const Duration(minutes: 45), () => _say(restScene));
    _armIdle();
    _armWander();
    _armPlay();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _pet.removeListener(_onPet);
    _hideLine?.cancel();
    _restTimer?.cancel();
    _idleTimer?.cancel();
    _rebound?.cancel();
    _wanderTimer?.cancel();
    _playTimer?.cancel();
    super.dispose();
  }

  /// 全局动作总线推来了一句新台词。
  void _onPet() {
    if (!mounted) return;
    final line = _pet.bubble;
    if (line == null || line == _line) return;
    _show(line);
  }

  double get _h => widget.height ?? PetBar.defaultHeight();

  // ---------- 游走 ----------

  void _armWander() {
    _wanderTimer?.cancel();
    if (!widget.wander) return;
    // 2.5~6 秒挪一次，节奏不规律才像活的
    _wanderTimer = Timer(
      Duration(milliseconds: 2500 + _rnd.nextInt(3500)),
      () {
        _step();
        _armWander();
      },
    );
  }

  void _step() {
    final next = _rnd.nextDouble();
    // 别贴着原地抖，也别走出界
    if ((next - _to).abs() < 0.15) return;
    setState(() {
      _from = _walkT >= 1 ? _to : _from + (_to - _from) * _walkT;
      _to = next;
      _walkT = 0;
    });
  }

  void _advanceWalk(double dt) {
    if (_walkT >= 1) return;
    _walkT = (_walkT + dt / _walkDur).clamp(0.0, 1.0);
  }

  /// 当前实际位置（游走过程中线性插值，用来做朝向判断）。
  double get _pos => _from + (_to - _from) * _walkT;

  /// 走的方向：+1 向右。朝右时把整只翻过来，尾巴才在身后。
  int get _facing => (_to - _from) >= 0 ? 1 : -1;

  // ---------- 自己玩 ----------

  void _armPlay() {
    _playTimer?.cancel();
    // 5~13 秒来一次，跟游走错开，免得看起来像卡带
    _playTimer = Timer(
      Duration(milliseconds: 5000 + _rnd.nextInt(8000)),
      () {
        if (mounted && !_pet.enabled) return;
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

  /// 开场白：久别优先于日常问候。
  void _greet() {
    final days = _pet.greet();
    if (days == null) return; // 本次进程已经打过招呼了
    _say(days >= 2 ? absenceScene(days) : greetingScene(DateTime.now()));
  }

  /// 冒一句话。自动消失，同一场景再次触发会换一句。
  void _say(PetScene scene) => _show(petLine(scene, turn: _turn++));

  /// 把一句话挂到气泡上，并在超时后收回。
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
    // 走全局事件总线，和其它动作同一套文案表（按形态变），不另开一份
    if (!_pet.pet()) return; // 冷却中：不弹跳也不说话
    _bounce();
    _play = _Play.still; // 被摸的时候别自己玩了，专注回应
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

  // ---------- 玩耍的外形 ----------

  /// 当前小动作带来的位移 / 旋转 / 压扁，以及覆盖用的情绪。
  ({Offset shift, double rotate, double squash, PetMood? mood}) _pose(
      double h) {
    final t = _playT.clamp(0.0, 1.0);
    switch (_play) {
      case _Play.hop:
        // 连跳两下：sin 取绝对值 = 两个连续的抛物线
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
          mood: null,
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
          mood: PetMood.cheer,
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
    // 眨眼：每 3.9 秒一次，偶尔连眨两下
    final m = _phase % 3.9;
    final blink = m < 0.12 || (m > 0.30 && m < 0.42);
    final pose = _pose(h);

    return LayoutBuilder(
      builder: (context, box) {
        final pw = h * 1.35 + 20; // 宠物站位宽（含两侧触摸余量）
        // 宽度不受约束时（桌面标题栏的 Row）自己占一段，把气泡包住 ——
        // 气泡绝不允许画到这个部件外面去，否则会盖住窗口按钮。
        final barW = box.maxWidth.isFinite ? box.maxWidth : pw + 260;
        // AnimatedAlign 把站位左边缘在 [6, barW-6-pw] 之间插值
        final petLeft = 6 + (barW - 12 - pw) * _pos;
        final petRight = petLeft + pw;
        // 在右边就往左说话，在左边就往右说话：永远不顶到边界外的东西
        final openRight = _pos < 0.45;
        final room =
            openRight ? barW - 14 - (petRight + 10) : (petLeft - 10) - 14;
        final maxBubble = room.clamp(80.0, 236.0).toDouble();

        return SizedBox(
          height: h,
          width: barW,
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              if (_line != null)
                Positioned(
                  left: openRight ? petRight + 10 : null,
                  right: openRight ? null : barW - petLeft + 10,
                  // 贴着预留带上沿往下长：预留带只有 26~30px，气泡一行就装不下，
                  // 锚在上沿往下展开才不会顶出屏幕/被窗口上沿裁掉。
                  top: 2,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(maxWidth: maxBubble),
                    child: _bubble(_line!, scheme),
                  ),
                ),
              AnimatedAlign(
                // 游走：位置按缓动插值，不是瞬移
                alignment: Alignment(-1 + 2 * _to, 1),
                duration: const Duration(milliseconds: 1050),
                curve: Curves.easeInOut,
                child: SizedBox(
                  width: pw,
                  height: h,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // 触摸区向下多探 18px：预留带只有 26px 高，直接拿它当热区太难点
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
                                // 走的时候翻面：尾巴才在身后
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
  }

  /// 半透明浮动气泡：贴着宠物那一侧，与它齐平，不压在头顶。
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
              // 只显示一行：预留带只有 26~30px 高，两行气泡会撑到内容区里，
              // 而且看着像一块方牌，不像在说话。超长就截断，别换行。
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
