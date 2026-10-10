// 全局系统度量：记录状态栏高度，供阅读器在隐藏状态栏后手动补回留白。
//
// 为什么不能在阅读器里现读：阅读器进入时会把系统状态栏隐藏掉，
// MediaQuery 的 padding/viewPadding 会立刻归零 —— 等到这里再量就只剩 0，
// 正文会突然顶到屏幕上沿。必须在状态栏还看得见的时候（首页）先量好。
//
// 这块留白本身是有用的：以后加桌宠，正好落在这一条预留带里，不用再改版式。
import 'package:flutter/widgets.dart';

class SystemMetrics {
  SystemMetrics._();

  /// 状态栏 / 刘海区域的高度（逻辑像素）。首页测量时写入。
  static double topInset = 0;

  /// 底部系统栏高度（手势条 / 导航键）。
  static double bottomInset = 0;
}

/// 在状态栏可见时测量一次并记下来（首页 initState 调用即可）。
void captureSystemInsets(BuildContext context) {
  final mq = MediaQuery.maybeOf(context);
  if (mq == null) return;
  final p = mq.padding;
  // 安卓开了 edge-to-edge，padding.top 恒为 0，高度只落在 viewPadding 上。
  // 两个都取，谁有值用谁 —— 否则窄带会退化成 26px 的兜底值，和真机对不上。
  final top = p.top > 0 ? p.top : mq.viewPadding.top;
  final bottom = p.bottom > 0 ? p.bottom : mq.viewPadding.bottom;
  // 取多次最大值：冷启动首帧 padding 可能还没稳定
  if (top > SystemMetrics.topInset) SystemMetrics.topInset = top;
  if (bottom > SystemMetrics.bottomInset) {
    SystemMetrics.bottomInset = bottom;
  }
}
