// 安卓 edge-to-edge 下的顶部布局。
//
// 背景：安卓如果不开 edge-to-edge，系统会自己占掉一整条状态栏；我们再放一条
// 桌宠窄带，顶部就变成**两条**叠加（≈56px），看上去像「被顶下去了」。
// 开了 edge-to-edge 之后，应用画到状态栏底下，那条窄带**就是**状态栏本身
// —— 也就是原来显示时间 / 信号强度的地方 —— 顶部总共只占一个 inset。
//
// 抽成独立部件是为了能在 widget test 里断言这块几何。顶部高度栽过两次，
// 而真机不一定在手边，能测就别靠推理。
import 'package:flutter/material.dart';

import '../pet/pet_view.dart';

/// 顶部窄带（桌宠活动区）+ 下方内容。
///
/// [band] 应等于系统状态栏高度，由启动时量到的 `SystemMetrics.topInset` 提供。
class PetTopBand extends StatelessWidget {
  const PetTopBand({
    super.key,
    required this.band,
    required this.background,
    required this.child,
  });

  final double band;
  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: background,
      child: Column(
        children: [
          // 桌宠就画在这条带子里：它同时是状态栏区域，所以系统图标和它并存，
          // 不会多占一整条。
          SizedBox(height: band, child: PetBar(height: band)),
          Expanded(child: child),
        ],
      ),
    );
  }
}
