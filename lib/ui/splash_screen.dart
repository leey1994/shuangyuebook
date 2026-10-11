import 'dart:async';

import 'package:flutter/material.dart';

/// 开屏页：冷启动时先把品牌亮出来，再进主界面。
///
/// 图是 `assets/brand/splash.png`，由 `assets/brand/generate_slogan.ps1`
/// 从 `slogan.txt` 的文案生成 —— 改文案只改 txt，不用重画图。
class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key, required this.next, this.minDuration});

  /// 开屏结束后要显示的界面。
  final Widget next;

  /// 最短停留时长。默认 900ms —— 够看清「爽阅 · 爽快阅读，想看就看」，
  /// 又不至于让每天开几十次的人觉得烦。
  final Duration? minDuration;

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    final d = widget.minDuration ?? const Duration(milliseconds: 900);
    // 零时长也走 Timer：initState 里直接调 Navigator.pushReplacement 属于
    // 在 build 期间改路由树。Timer.run 把回调推到本轮事件循环末尾。
    _timer = d <= Duration.zero ? Timer(Duration.zero, _go) : Timer(d, _go);
  }

  void _go() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      // 开屏是全屏替换：不保留返回栈，也不参与返回手势。
      PageRouteBuilder<void>(
        pageBuilder: (_, __, ___) => widget.next,
        transitionDuration: Duration.zero,
        reverseTransitionDuration: Duration.zero,
      ),
    );
  }

  @override
  void dispose() {
    // 页面若在到点前就被 pop（系统返回 / 热重启），回调会往已销毁的
    // context 上压路由，必须撤掉。
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF111827),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Image.asset(
            'assets/brand/splash.png',
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