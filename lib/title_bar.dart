import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'pet/pet_view.dart';

/// 桌面端自绘标题栏：可拖动移动窗口、双击最大化、右侧最小化/最大化/关闭。
/// 固定 36 高、文字图标不参与全局缩放，保证观感稳定。
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar> with WindowListener {
  bool _max = false;

  /// 当前悬停的窗口按钮说明，显示在标题栏中间的空白处。
  String? _hover;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  void onWindowMaximize() {
    if (mounted) setState(() => _max = true);
  }

  @override
  void onWindowUnmaximize() {
    if (mounted) setState(() => _max = false);
  }

  Future<void> _toggleMax() async {
    if (_max) {
      await windowManager.unmaximize();
    } else {
      await windowManager.maximize();
    }
  }

  /// 标题栏刻意放在 MaterialApp 之外（否则推路由时会被新页面盖住），因此它没有
  /// Overlay 祖先。所以这里**不能用 [Tooltip]**：它内部要 `Overlay.of()`，拿不到
  /// 就抛 "No Overlay widget found"，异常会把这一小段子树连同三个窗口按钮一起
  /// 干掉 —— 表现就是「最小化 / 最大化看不见」。
  /// 改成自己用 [MouseRegion] 跟踪悬停，把说明画在标题栏中间的空白处。
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 必须用 Material 而不是 Container：下面的 InkWell（窗口按钮）要求有
    // Material 祖先，而标题栏在 MaterialApp 之外、本来就没有 —— 缺了会抛
    // "No Material widget found"，异常直接把这三个按钮连同子树一起干掉，
    // 表现就是「最小化 / 最大化看不见」。
    return Material(
      color: scheme.surface,
      child: SizedBox(
        height: 36,
        child: Row(
          children: [
            // 左：图标 + 标题，同样可拖动
            DragToMoveArea(
              child: GestureDetector(
                onDoubleTap: _toggleMax,
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.menu_book, size: 16, color: scheme.onSurface),
                      const SizedBox(width: 8),
                      Text(
                        '爽阅',
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(
                          fontSize: 13,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // 桌宠：桌面端的「顶部预留带」就是这条标题栏。
            //
            // 两处必须注意：
            //   1) 排在拖动区**外面** —— 放里面点击会被 DragToMoveArea 吃掉；
            //   2) 紧跟标题而不是紧挨按钮，气泡只会往右展开到中间的空白拖动区。
            // PetBar 自己占一段固定宽度把气泡包住，两侧都不会溢出到部件之外。
            const PetBar(height: 30),
            // 中：整片空白都是拖动区 + 双击最大化；顺带显示悬停说明
            Expanded(
              child: DragToMoveArea(
                child: GestureDetector(
                  onDoubleTap: _toggleMax,
                  behavior: HitTestBehavior.opaque,
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 14),
                      child: Text(
                        _hover ?? '',
                        textScaler: TextScaler.noScaling,
                        style: TextStyle(fontSize: 12, color: scheme.onSurface),
                      ),
                    ),
                  ),
                ),
              ),
            ),
            _btn(Icons.remove, '最小化', scheme, () => windowManager.minimize()),
            _btn(_max ? Icons.filter_none : Icons.crop_square, '最大化', scheme,
                _toggleMax),
            _btn(Icons.close, '关闭', scheme, () => windowManager.close(),
                close: true),
          ],
        ),
      ),
    );
  }

  Widget _btn(IconData icon, String tip, ColorScheme scheme, VoidCallback onTap,
      {bool close = false}) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = tip),
      onExit: (_) => setState(() => _hover = null),
      child: InkWell(
        onTap: onTap,
        hoverColor:
            close ? Colors.red : scheme.onSurface.withValues(alpha: 0.1),
        child: SizedBox(
          width: 44,
          height: 36,
          child: Icon(icon, size: 16, color: scheme.onSurface),
        ),
      ),
    );
  }
}
