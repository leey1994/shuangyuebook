// 书内搜索弹层：在已缓存的章节正文里找一句话，点一下跳过去。
//
// 只搜缓存（离线可用、不打书源）—— 读过 / 下载过的章节自然可搜，
// 没缓存的章节给了提示，不假装能搜全书。
import 'package:flutter/material.dart';

import '../data/book_search.dart';
import '../models.dart';
import '../store.dart';

/// 打开书内搜索。[onJump]：(章下标, 段下标)。
void showBookSearch(
  BuildContext context,
  BookDetail detail,
  void Function(int chapterIndex, int paraIndex) onJump,
) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: _BookSearchSheet(detail: detail, onJump: onJump),
    ),
  );
}

class _BookSearchSheet extends StatefulWidget {
  const _BookSearchSheet({required this.detail, required this.onJump});

  final BookDetail detail;
  final void Function(int, int) onJump;

  @override
  State<_BookSearchSheet> createState() => _BookSearchSheetState();
}

class _BookSearchSheetState extends State<_BookSearchSheet> {
  final _ctrl = TextEditingController();
  int _seq = 0; // 输入竞态：旧查询的迟到结果直接丢弃
  List<BookHit> _hits = const [];
  Future<Map<String, List<String>>>? _texts; // 首次搜索时才读盘，弹层内复用

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _run(String raw) {
    final q = raw.trim();
    final seq = ++_seq;
    if (q.isEmpty) {
      setState(() => _hits = const []);
      return;
    }
    _texts ??= AppStore.I.cachedTexts(widget.detail.book.url);
    _texts!.then((texts) {
      if (!mounted || seq != _seq) return;
      setState(() {
        _hits = searchBookTexts(
          chapters: widget.detail.chapters,
          texts: texts,
          query: q,
        );
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final q = _ctrl.text.trim();
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: TextField(
            controller: _ctrl,
            autofocus: true,
            decoration: InputDecoration(
              hintText: '搜章节标题或正文（离线，限已缓存）',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _ctrl.text.isEmpty
                  ? null
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _ctrl.clear();
                        _run('');
                        setState(() {});
                      },
                    ),
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            onChanged: (v) {
              _run(v);
              setState(() {}); // 清除按钮的显隐
            },
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              q.isEmpty
                  ? '读过 / 下载过的章节都可搜'
                  : (_hits.isEmpty
                      ? '没有找到「$q」'
                      : '${_hits.length >= 100 ? '100+' : _hits.length} 处结果 · 点击跳转'),
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
        ),
        Expanded(
          child: ListView.separated(
            itemCount: _hits.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final h = _hits[i];
              return ListTile(
                dense: true,
                title: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(text: h.snippet.substring(0, h.matchStart)),
                      TextSpan(
                        text: h.snippet.substring(
                            h.matchStart, h.matchStart + h.matchLen),
                        style: TextStyle(
                          color: theme.colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      TextSpan(
                          text: h.snippet
                              .substring(h.matchStart + h.matchLen)),
                    ],
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Text(
                  '第 ${h.chapterIndex + 1} 章 · ${h.chapterTitle}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onJump(h.chapterIndex, h.paraIndex);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}
