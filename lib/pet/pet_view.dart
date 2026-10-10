// 桌宠「小墨」的活动区。
//
// 落在阅读器顶部那条预留留白里（状态栏高度），所以体型按高度算而不是按宽度，
// 天然就是「很小的一只」。气泡向下浮出去盖在正文上，靠父级 Stack 的
// Clip.none —— 摆桌宠的人需要它始终在场，不需要点开某个页面才见得到。
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../ui/system_metrics.dart';
import 'pet_lines.dart';
import 'pet_painter.dart';
import 'pet_store.dart';

/// 宠物活动带。放进 Stack 的最后一个子节点，气泡才不会被正文挡住。
class PetBar extends StatefulWidget {
  const PetBar({super.key, this.height});

  /// 活动带高度。默认取预留的状态栏高度；桌面端没有状态栏，给一个同量级的窄带。
  final double? height;

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

class _PetBarState extends State<PetBar> with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final _pet = PetStore.I;
  int _turn = 0; // 同场景内换台词的轮次

  String? _line;
  Timer? _hideLine;
  Timer? _restTimer;
  Timer? _idleTimer;
  Timer? _rebound;

  double _phase = 0;
  double _squash = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((elapsed) {
      _phase = elapsed.inMicroseconds / 1e6;
      _pet.tickMood();
      if (mounted) setState(() {});
    })
      ..start();
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
  }

  @override
  void dispose() {
    _ticker.dispose();
    _hideLine?.cancel();
    _restTimer?.cancel();
    _idleTimer?.cancel();
    _rebound?.cancel();
    super.dispose();
  }

  double get _h => widget.height ?? PetBar.defaultHeight();

  /// 开场白：久别优先于日常问候。
  void _greet() {
    final days = _pet.greet();
    if (days == null) return; // 本次进程已经打过招呼了
    _say(days >= 2 ? absenceScene(days) : greetingScene(DateTime.now()));
  }

  /// 冒一句话。自动消失，同一场景再次触发会换一句。
  void _say(PetScene scene) {
    if (!mounted) return;
    _hideLine?.cancel();
    setState(() => _line = petLine(scene, turn: _turn++));
    _hideLine = Timer(const Duration(milliseconds: 4200), () {
      if (mounted) setState(() => _line = null);
    });
    _armIdle();
  }

  void _armIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(const Duration(minutes: 4), () => _say(idleScene));
  }

  void _onTap() {
    _pet.pet();
    _bounce();
    _say(petScene(_pet.stage));
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

  @override
  Widget build(BuildContext context) {
    if (!_pet.enabled) return const SizedBox.shrink();
    final h = _h;
    final scheme = Theme.of(context).colorScheme;
    // 眨眼：每 3.9 秒一次，偶尔连眨两下
    final m = _phase % 3.9;
    final blink = m < 0.12 || (m > 0.30 && m < 0.42);

    return SizedBox(
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          if (_line != null)
            Positioned(
              right: 6 + h * 1.35,
              bottom: 0,
              child: _bubble(_line!, scheme),
            ),
          Positioned(
            right: 6,
            top: 0,
            // 触摸区比身位大：这么小的一只，不能只有几像素可点
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _onTap,
              child: SizedBox(
                width: h * 1.35 + 20,
                height: h + 14,
                child: CustomPaint(
                  painter: PetPainter(
                    stage: _pet.stage,
                    mood: _pet.mood,
                    phase: _phase,
                    squash: _squash,
                    blink: blink,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 半透明浮动气泡，底部挂一个小尖角指向宠物。
  Widget _bubble(String text, ColorScheme scheme) {
    final fill = scheme.surface.withValues(alpha: 0.80);
    return TweenAnimationBuilder<double>(
      key: ValueKey(text),
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutCubic,
      builder: (context, t, _) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, -6 * (1 - t)),
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                right: 10,
                top: -4,
                // 尖角：旋转 45° 的小方块，一半压在气泡边线下
                child: Transform.rotate(
                  angle: math.pi / 4,
                  child: Container(width: 8, height: 8, color: fill),
                ),
              ),
              Container(
                constraints: const BoxConstraints(maxWidth: 230),
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: fill,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                      color: scheme.outlineVariant.withValues(alpha: .6)),
                ),
                child: Text(
                  text,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.35,
                    color: scheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
