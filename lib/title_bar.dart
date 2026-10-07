import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

/// 桌面端自绘标题栏：可拖动移动窗口、双击最大化、右侧最小化/最大化/关闭。
/// 固定 36 高、文字图标不参与全局缩放，保证观感稳定。
class DesktopTitleBar extends StatefulWidget {
  const DesktopTitleBar({super.key});

  @override
  State<DesktopTitleBar> createState() => _DesktopTitleBarState();
}

class _DesktopTitleBarState extends State<DesktopTitleBar>
    with WindowListener {
  bool _max = false;

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

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      height: 36,
      color: scheme.surface,
      child: Row(
        children: [
          Expanded(
            child: DragToMoveArea(
              child: GestureDetector(
                onDoubleTap: _toggleMax,
                child: SizedBox(
                  height: 36,
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.menu_book,
                          size: 16, color: scheme.onSurface),
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
          ),
          _btn(Icons.remove, '最小化', scheme, () => windowManager.minimize()),
          _btn(_max ? Icons.filter_none : Icons.crop_square, '最大化',
              scheme, _toggleMax),
          _btn(Icons.close, '关闭', scheme, () => windowManager.close(),
              close: true),
        ],
      ),
    );
  }

  Widget _btn(IconData icon, String tip, ColorScheme scheme, VoidCallback onTap,
      {bool close = false}) {
    return Tooltip(
      message: tip,
      child: InkWell(
        onTap: onTap,
        hoverColor: close ? Colors.red : scheme.onSurface.withValues(alpha: 0.1),
        child: SizedBox(
          width: 44,
          height: 36,
          child: Icon(icon, size: 16, color: scheme.onSurface),
        ),
      ),
    );
  }
}
