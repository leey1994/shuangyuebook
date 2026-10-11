import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';

/// 开屏：铺满**整个窗口**亮出品牌，再换成真正的应用。
///
/// 为什么放在 MaterialApp 外面而不是用一条路由：
/// MaterialApp 的 `builder` 会往上再套一层（桌面端的自绘标题栏、安卓的
/// 状态栏带）。放进路由里，开屏只盖住 Navigator，标题栏照样画在上面 ——
/// 窗口顶部会露出一条「爽阅 + 桌宠」，开屏就漏了。挂在最外层才真的盖严。
///
/// 所以这里不用 Navigator，用一个布尔开关直接换 child。
class SplashGate extends StatefulWidget {
  const SplashGate({
    super.key,
    required this.child,
    this.minDuration = const Duration(milliseconds: 900),
  });

  /// 开屏结束后显示的应用。
  final Widget child;

  /// 最短停留时长。默认 900ms —— 够看清「爽阅 · 爽快阅读，想看就看」，
  /// 又不至于让每天开几十次的人觉得烦。
  final Duration minDuration;

  @override
  State<SplashGate> createState() => _SplashGateState();

  /// 桌面端固定横版：窗口可以被拖成竖条，那时竖版图会被压成一条。
  /// 移动端按屏幕方向切，横屏时竖版图上下留两大片空白。
  static String assetFor({required bool landscape, required bool desktop}) {
    if (desktop) return 'assets/brand/splash-landscape.png';
    return landscape
        ? 'assets/brand/splash-landscape.png'
        : 'assets/brand/splash-portrait.png';
  }
}

class _SplashGateState extends State<SplashGate> {
  Timer? _timer;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    final d = widget.minDuration;
    // 零时长也走 Timer：initState 里同步换 child 会让首帧什么都不画。
    _timer = Timer(d <= Duration.zero ? Duration.zero : d, () {
      if (mounted) setState(() => _done = true);
    });
  }

  @override
  void dispose() {
    // 页面若在到点前被换掉，回调会往已销毁的 State 上 setState。
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (_done) return child;
    final mq = MediaQuery.maybeOf(context);
    final landscape = (mq?.size.width ?? 0) > (mq?.size.height ?? 0);
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return ColoredBox(
      color: const Color(0xFF111827),
      // 不用 Stack：它要 Directionality 解 alignment，而本部件挂在
      // MaterialApp **外面**，上面没有 Directionality，会直接抛断言。
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Image.asset(
            SplashGate.assetFor(landscape: landscape, desktop: desktop),
            fit: BoxFit.contain,
            excludeFromSemantics: true,
            // 图没加载出来时不要留一块刺眼的空框
            errorBuilder: (_, __, ___) => const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}
