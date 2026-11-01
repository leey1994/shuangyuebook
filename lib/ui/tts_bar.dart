// 听书悬浮条：正在朗读时挂在主界面底部，任何 tab 都能控制。
//
// 点击条身回到正在读的那本书；上一章 / 播放暂停 / 下一章 / 关闭就地可用。
// 退出阅读器后条仍在（后台播放的可见形态），点「关闭」才是真停。
import 'package:flutter/material.dart';

import '../data/tts_session.dart';
import '../screens/reader_screen.dart';
import '../theme.dart';

class TtsBar extends StatelessWidget {
  const TtsBar({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: TtsSession.I,
      builder: (context, _) {
        final s = TtsSession.I;
        final book = s.book;
        if (!s.active || book == null) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return Material(
          color: theme.cardColor,
          elevation: 8,
          child: SafeArea(
            top: false,
            child: ListTile(
              dense: true,
              leading: Icon(
                s.paused ? Icons.headset_off : Icons.headset,
                color: Brand.green,
              ),
              title: Text(
                book.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    fontSize: 13.5, fontWeight: FontWeight.w600),
              ),
              subtitle: Text(
                '第 ${s.chapterIndex + 1} 章 ${s.chapterTitle}'
                '${s.paused ? ' · 已暂停' : ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: Brand.fg3(context)),
              ),
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(
                builder: (_) => ReaderScreen(
                  book: book,
                  chapterIndex: s.chapterIndex,
                ),
              )),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.skip_previous, size: 22),
                    tooltip: '上一章',
                    onPressed: s.prevChapter,
                  ),
                  IconButton(
                    icon: Icon(
                        s.paused ? Icons.play_arrow : Icons.pause,
                        size: 24),
                    tooltip: s.paused ? '继续' : '暂停',
                    onPressed: s.togglePause,
                  ),
                  IconButton(
                    icon: const Icon(Icons.skip_next, size: 22),
                    tooltip: '下一章',
                    onPressed: s.nextChapter,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 20),
                    tooltip: '停止朗读',
                    onPressed: () => s.stop(),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
