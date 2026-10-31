// 全局迷你播放条：离开阅读器后继续听书时的唯一控制面。
//
// 只在「控制器有会话 且 阅读器不在场」时出现（阅读器自己有完整听书面板）。
import 'package:flutter/material.dart';

import '../screens/reader_screen.dart';
import '../tts/tts_controller.dart';
import '../tts/tts_queue.dart';
import '../theme.dart';

class TtsMiniBar extends StatelessWidget {
  const TtsMiniBar({super.key, required this.navigatorKey});

  final GlobalKey<NavigatorState> navigatorKey;

  @override
  Widget build(BuildContext context) {
    final c = TtsController.I;
    if (!c.active || c.attached || c.inReader || c.book == null) {
      return const SizedBox.shrink();
    }
    return Builder(builder: (context) {
        final dark = Theme.of(context).brightness == Brightness.dark;
        final fg = dark ? Colors.white : const Color(0xFF20301F);
        final snippet = c.snippet.trim();
        return Align(
          alignment: Alignment.bottomCenter,
          child: Padding(
            padding: EdgeInsets.fromLTRB(
              10,
              0,
              10,
              MediaQuery.sizeOf(context).width < 720 ? 84 : 14,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Material(
                elevation: 10,
                borderRadius: BorderRadius.circular(16),
                color: dark ? const Color(0xFF1E241E) : const Color(0xFFF3F8F1),
                child: InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () {
                    final b = c.book;
                    if (b == null) return;
                    navigatorKey.currentState?.push(MaterialPageRoute(
                      builder: (_) => ReaderScreen(
                        book: b,
                        chapterIndex: c.chapterIndex,
                      ),
                    ));
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 8, 6, 8),
                    child: Row(
                      children: [
                        const Icon(Icons.graphic_eq, size: 18, color: Brand.green),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                c.chapterTitle.isEmpty
                                    ? c.bookTitle
                                    : '${c.bookTitle} · ${c.chapterTitle}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Brand.green,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              Text(
                                snippet.isEmpty ? '准备中…' : snippet,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(fontSize: 12, color: fg),
                              ),
                            ],
                          ),
                        ),
                        // 迷你条在 Overlay 之外，IconButton 的 tooltip 会抛
                        // 「No Overlay widget found」；用 icon 的语义标签代替。
                        _MiniIcon(
                          label: '上一句',
                          icon: Icons.skip_previous,
                          size: 20,
                          color: fg,
                          onTap: c.prev,
                        ),
                        _MiniIcon(
                          label: c.paused ? '继续' : '暂停',
                          icon: c.paused ? Icons.play_arrow : Icons.pause,
                          size: 22,
                          color: fg,
                          onTap: () => c.toggle(),
                        ),
                        _MiniIcon(
                          label: '下一句',
                          icon: Icons.skip_next,
                          size: 20,
                          color: fg,
                          onTap: c.next,
                        ),
                        _MiniIcon(
                          label: '关闭听书',
                          icon: Icons.close,
                          size: 18,
                          color: fg,
                          onTap: () => c.stop(),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
    });
  }
}

/// 固定宽高的小图标按钮（迷你条空间紧，且不能带 tooltip）。
class _MiniIcon extends StatelessWidget {
  const _MiniIcon({
    required this.label,
    required this.icon,
    required this.size,
    required this.color,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => IconButton(
        onPressed: onTap,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints.tightFor(width: 34, height: 34),
        icon: Icon(icon, size: size, color: color, semanticLabel: label),
      );
}

/// 状态文案（测试/调试用，避免重复三处三元）。
String ttsStateLabel(TtsState s) => switch (s) {
      TtsState.idle => '已停止',
      TtsState.playing => '正在朗读',
      TtsState.paused => '已暂停',
    };
