import 'package:flutter/material.dart';

import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../widgets.dart';
import 'reader_screen.dart';

/// 书籍详情：简介 + 目录（分页）+ 阅读/书架/离线下载/换源。
class BookDetailScreen extends StatefulWidget {
  final Book book;
  const BookDetailScreen({super.key, required this.book});

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  late NovelSource _src;
  BookDetail? _detail;
  Object? _error;
  bool _loadingMore = false;

  // 离线下载状态
  int _dlDone = 0;
  int _dlTotal = 0;
  bool _downloading = false;
  bool _cancelDl = false;

  @override
  void initState() {
    super.initState();
    _src = sourceById(widget.book.sourceId) ?? allSources.first;
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _detail = null;
    });
    try {
      final d = await _src.fetchDetail(widget.book);
      if (mounted) setState(() => _detail = d);
      AppStore.I.setChapterCount(widget.book.url, d.chapters.length);
    } catch (e) {
      // 离线兜底：用本地缓存的目录
      final cached = await AppStore.I.cachedDetail(widget.book);
      if (!mounted) return;
      if (cached != null) {
        setState(() => _detail = cached);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('网络不可用，已显示离线目录')));
      } else {
        setState(() => _error = e);
      }
    }
  }

  Future<void> _loadMoreChapters() async {
    final d = _detail;
    if (d == null || d.nextChaptersUrl == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final more =
          await _src.fetchDetail(widget.book, nextUrl: d.nextChaptersUrl);
      final seen = d.chapters.map((c) => c.url).toSet();
      final merged = [...d.chapters];
      for (final c in more.chapters) {
        if (seen.add(c.url)) merged.add(c);
      }
      setState(() {
        _detail = BookDetail(
          book: d.book,
          chapters: merged,
          nextChaptersUrl: more.nextChaptersUrl,
        );
      });
      AppStore.I.setChapterCount(widget.book.url, merged.length);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载目录失败：$e')));
      }
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _download() async {
    final d = _detail;
    if (d == null || _downloading) return;
    setState(() {
      _downloading = true;
      _cancelDl = false;
      _dlDone = 0;
      _dlTotal = d.chapters.length;
    });
    final ok = await AppStore.I.downloadBook(
      _src,
      d,
      onProgress: (done, total) {
        if (mounted) setState(() => _dlDone = done);
      },
      cancelled: () => _cancelDl,
    );
    if (!mounted) return;
    setState(() => _downloading = false);
    if (ok) PetStore.I.emit(PetAction.downloadBook);
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content:
            Text(ok ? '下载完成，共 $_dlTotal 章' : '已取消下载（完成 $_dlDone/$_dlTotal）')));
  }

  void _openReader(int chapterIndex) {
    final d = _detail;
    if (d == null) return;
    // 搜索/发现找书 → 真的点开了一本：桌宠按「帮上忙了」给一次成长值
    PetStore.I.emit(PetAction.searchOpen);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(book: d.book, chapterIndex: chapterIndex),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.book.title, maxLines: 1),
        actions: [
          if (d != null)
            IconButton(
              tooltip: '换源',
              icon: const Icon(Icons.swap_horiz),
              onPressed: () => showSourceSwitch(
                context,
                d.book,
                onSelected: (src, b) {
                  Navigator.of(context).pushReplacement(MaterialPageRoute(
                      builder: (_) => BookDetailScreen(book: b)));
                },
              ),
            ),
        ],
      ),
      body: d == null
          ? (_error == null
              ? const Center(child: CircularProgressIndicator())
              : Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child:
                            Text('加载失败：$_error', textAlign: TextAlign.center),
                      ),
                      OutlinedButton(onPressed: _load, child: const Text('重试')),
                    ],
                  ),
                ))
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.all(12),
                  sliver: SliverList.list(
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CoverImage(
                              url: d.book.cover, width: 100, height: 140),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.book.title,
                                    style: theme.textTheme.titleLarge),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: [
                                    if (d.book.author != null &&
                                        d.book.author!.isNotEmpty)
                                      Text('作者：${d.book.author}',
                                          style: theme.textTheme.bodyMedium),
                                    if (d.book.status != null &&
                                        d.book.status!.isNotEmpty)
                                      TagPill(d.book.status!),
                                  ],
                                ),
                                const SizedBox(height: 6),
                                Text('目录共 ${d.chapters.length} 章',
                                    style: theme.textTheme.bodySmall),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          FilledButton.icon(
                            icon: const Icon(Icons.menu_book),
                            label: Text(_startLabel()),
                            onPressed: () => _openReader(_startIndex()),
                          ),
                          ListenableBuilder(
                            listenable: AppStore.I,
                            builder: (context, _) {
                              final inShelf = AppStore.I.inShelf(d.book.url);
                              return OutlinedButton.icon(
                                icon: Icon(inShelf
                                    ? Icons.bookmark
                                    : Icons.bookmark_border),
                                label: Text(inShelf ? '移出书架' : '加入书架'),
                                onPressed: () {
                                  if (inShelf) {
                                    AppStore.I.removeFromShelf(d.book.url);
                                  } else {
                                    AppStore.I.addToShelf(d.book,
                                        chapterCount: d.chapters.length);
                                  }
                                },
                              );
                            },
                          ),
                          OutlinedButton.icon(
                            icon: const Icon(Icons.download),
                            label: Text(_downloading
                                ? '下载中 $_dlDone/$_dlTotal'
                                : '下载离线'),
                            onPressed: _downloading
                                ? () => setState(() => _cancelDl = true)
                                : _download,
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (d.book.intro != null && d.book.intro!.isNotEmpty) ...[
                        Text('简介', style: theme.textTheme.titleSmall),
                        const SizedBox(height: 4),
                        Text(d.book.intro!,
                            style: theme.textTheme.bodyMedium
                                ?.copyWith(height: 1.6)),
                        const SizedBox(height: 12),
                      ],
                      const Divider(),
                      Row(
                        children: [
                          Text('目录', style: theme.textTheme.titleSmall),
                          const Spacer(),
                          if (_loadingMore)
                            const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2)),
                        ],
                      ),
                      const SizedBox(height: 4),
                    ],
                  ),
                ),
                // 目录惰性构建：几千章也不一次性生成 widget（防卡顿/内存暴涨）
                SliverPadding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  sliver: SliverList.builder(
                    itemCount: d.chapters.length,
                    itemBuilder: (context, i) => Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (i > 0) const Divider(indent: 4, endIndent: 4),
                        InkWell(
                          onTap: () => _openReader(i),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                vertical: 11, horizontal: 4),
                            child: Text(
                              d.chapters[i].title,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 32),
                  sliver: SliverList.list(
                    children: [
                      if (d.nextChaptersUrl != null)
                        Center(
                          child: _loadingMore
                              ? const CircularProgressIndicator()
                              : OutlinedButton(
                                  onPressed: _loadMoreChapters,
                                  child: const Text('加载更多目录'),
                                ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  int _startIndex() {
    final e = AppStore.I.shelfEntry(_detail?.book.url ?? widget.book.url) ??
        AppStore.I.history.firstWhere(
            (x) => x.book.url == (_detail?.book.url ?? widget.book.url),
            orElse: () => ShelfEntry(book: widget.book));
    final n = _detail?.chapters.length ?? 0;
    if (n == 0) return 0;
    return e.chapterIndex.clamp(0, n - 1).toInt();
  }

  String _startLabel() {
    final e = AppStore.I.shelfEntry(_detail?.book.url ?? widget.book.url) ??
        AppStore.I.history.firstWhere(
            (x) => x.book.url == (_detail?.book.url ?? widget.book.url),
            orElse: () => ShelfEntry(book: widget.book));
    return e.chapterIndex > 0 || e.page > 0 || e.paragraph > 0
        ? '继续阅读'
        : '开始阅读';
  }
}
