// 书籍详情（效果图 05）：来源面板一眼看清「当前源 / 可用源数 / 换源对齐」，
// 一键听书直达阅读器自动开播；底部固定栏：目录 / 缓存 / 加书架并开始阅读。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../collect/aggregate.dart';
import '../data/stats_store.dart';
import '../feed_cache.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../theme.dart';
import '../ui/brand.dart';
import '../widgets.dart';
import 'reader_screen.dart';

/// 来源计数的让路时长：目录 + 预取正文都发出去之后，再开始全源扇出搜索。
/// 那些搜索的解析都在主 isolate（池并发 6），早一步起跑会把正文挤慢。
const Duration kSourceCountDefer = Duration(seconds: 8);

class BookDetailScreen extends StatefulWidget {
  const BookDetailScreen({super.key, required this.book});

  final Book book;

  @override
  State<BookDetailScreen> createState() => _BookDetailScreenState();
}

class _BookDetailScreenState extends State<BookDetailScreen> {
  late NovelSource _src;

  /// 当前展示的书：自动换源成功后指向新来源的条目
  /// （[widget.book] 只是打开时传入的那一个）。
  late Book _book;
  BookDetail? _detail;
  Object? _error;

  /// 加载失败后自动换源的进行中提示。
  String? _autoMsg;
  bool _loadingMore = false;

  // 离线下载状态
  int _dlDone = 0;
  int _dlTotal = 0;
  bool _downloading = false;
  bool _cancelDl = false;

  // 来源面板
  int? _availSources; // 多源共同收录数（后台检索，命中即上屏）
  bool _tocAsc = true; // 目录正序 / 倒序

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _src = sourceById(_book.sourceId) ?? allSources.first;
    _load();
    // 来源计数（全源扇出搜索）不再和目录 / 正文抢同一段时间：
    // 它的解析都发生在主 isolate，池并发 6，一进来就跑就会把正文挤慢。
    // 目录落地后再延后一轮（见 _load 成功分支）。
  }

  Future<void> _load() async {
    setState(() {
      _error = null;
      _detail = null;
      _autoMsg = null;
    });
    try {
      final d = await _src.fetchDetail(_book);
      if (mounted) setState(() => _detail = d);
      AppStore.I.setChapterCount(_book.url, d.chapters.length);
      _afterDetailLanded(); // 预取正文 + 让路后再统计来源
    } catch (e) {
      // 离线兜底：用本地缓存的目录
      final cached = await AppStore.I.cachedDetail(_book);
      if (!mounted) return;
      if (cached != null) {
        setState(() => _detail = cached);
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('网络不可用，已显示离线目录')));
      } else {
        // 别的源收录过同名书就自动切过去，一个都打不开才落回错误页
        await _autoSwitch(e);
      }
    }
  }

  /// 目录落地上屏后，把用户要读的那一章正文在后台拉下来。
  ///
  /// 之前正文要等点开阅读器才发请求：网络 + 解析都叠在「点开之后」，
  /// 用户看目录的这几秒全浪费了。这里趁目录刚出就预取；chapterText 的
  /// 在途去重保证读者此刻点开 = 直接搭同一班车，点晚了 = 内存缓存命中。
  void _warmContent() {
    final d = _detail;
    if (d == null || d.chapters.isEmpty) return;
    unawaited(_warmOne(_startIndex()));
  }

  Future<void> _warmOne(int idx) async {
    final d = _detail;
    if (d == null || idx < 0 || idx >= d.chapters.length) return;
    try {
      await AppStore.I.chapterText(_src, d, d.chapters[idx], background: true);
    } catch (_) {
      // 预取失败不打扰：真正点开阅读器时会带正常的错误呈现
    }
  }

  /// 目录落地上屏后的两件事：立刻预取正文，并把全源扇出的来源计数推后。
  void _afterDetailLanded() {
    _warmContent();
    unawaited(Future.delayed(kSourceCountDefer, () async {
      if (mounted) await _countSources();
    }));
  }

  /// 当前来源打不开（404 / 解析失败）时，自动换到其它能打开的源。
  ///
  /// 用全部可用源按书名搜一遍 —— 和 [_countSources] 共用 FeedCache
  /// 缓存键，多数情况直接命中，几乎不重复拉网；并发搜完按
  /// collectSources 的顺序挨个试（固化源在前，默认先试稳的），
  /// 第一个能拉到目录的就切过去并提示用户。
  Future<void> _autoSwitch(Object error) async {
    final title = _book.title;
    final key = bookKeyOf(_book);
    final current = _src.id;
    setState(() => _autoMsg = '当前来源打不开，正在试其它来源…');
    final found = <(NovelSource, Book)>[];
    // 分池并发（上限 6）：全源一次扇出会在结果集中到达时卡住主 isolate
    final jobs = <Future<void> Function()>[];
    for (final s in collectSources()) {
      if (s.id == current) continue;
      jobs.add(() async {
        try {
          final r = await FeedCache.reach(
            FeedCache.key(['search', s.id, title]),
            () => s.search(title),
            skipEmpty: true,
          );
          for (final b in r) {
            if (bookKeyOf(b) == key) {
              found.add((s, b));
              break;
            }
          }
        } catch (_) {
          // 这个源搜不动就跳过，不影响其它候选
        }
      });
    }
    await runPooled(jobs);
    if (!mounted) return;
    // 并发返回顺序不定：按 collectSources 的登记顺序重排后再试
    final order = <String, int>{};
    final all = collectSources();
    for (var i = 0; i < all.length; i++) {
      order[all[i].id] = i;
    }
    found.sort((a, b) =>
        (order[a.$1.id] ?? 1 << 20).compareTo(order[b.$1.id] ?? 1 << 20));
    for (final (s, b) in found.take(6)) {
      try {
        final d = await s.fetchDetail(b);
        if (!mounted) return;
        setState(() {
          _src = s;
          _book = b;
          _detail = d;
          _autoMsg = null;
        });
        AppStore.I.setChapterCount(b.url, d.chapters.length);
        _afterDetailLanded(); // 换源成功同样预取正文，来源计数让路后再跑
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('原来源打不开，已自动切换到「${s.name}」')));
        return;
      } catch (_) {
        // 换下一个候选
      }
    }
    if (!mounted) return;
    setState(() {
      _autoMsg = null;
      _error = error; // 全都不行：还原错误页（重试 / 手动换源仍在）
    });
  }

  /// 后台数一数有多少书源同时收录了这本书（同名合并口径）。
  Future<void> _countSources() async {
    final key = bookKeyOf(_book);
    final title = _book.title;
    var count = 1; // 当前来源
    final jobs = <Future<void> Function()>[];
    for (final s in collectSources()) {
      if (s.id == _src.id) continue;
      jobs.add(() async {
        try {
          final r = await FeedCache.reach(
            FeedCache.key(['search', s.id, title]),
            () => s.search(title),
            skipEmpty: true,
          );
          if (!mounted) return;
          for (final b in r) {
            if (bookKeyOf(b) == key) {
              count++;
              setState(() => _availSources = count);
              break;
            }
          }
        } catch (_) {
          // 单个源失败不影响计数
        }
      });
    }
    await runPooled(jobs);
    if (mounted) setState(() => _availSources = count);
  }

  Future<void> _loadMoreChapters() async {
    final d = _detail;
    if (d == null || d.nextChaptersUrl == null || _loadingMore) return;
    setState(() => _loadingMore = true);
    try {
      final more =
          await _src.fetchDetail(_book, nextUrl: d.nextChaptersUrl);
      if (!mounted) return; // 拉取期间退出详情页：迟到结果丢弃
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
      AppStore.I.setChapterCount(_book.url, merged.length);
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

  void _openReader(int chapterIndex, {bool tts = false}) {
    final d = _detail;
    if (d == null) return;
    // 搜索/发现找书 → 真的点开了一本：桌宠按「帮上忙了」给一次成长值
    PetStore.I.emit(PetAction.searchOpen);
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => ReaderScreen(
        book: d.book,
        chapterIndex: chapterIndex,
        ttsAutostart: tts,
      ),
    ));
  }

  void _addAndRead() {
    final d = _detail;
    if (d == null) return;
    AppStore.I.addToShelf(d.book, chapterCount: d.chapters.length);
    _openReader(_startIndex());
  }

  void _share() {
    final b = _detail?.book ?? _book;
    final line = [
      '《${b.title}》',
      if (b.author?.isNotEmpty ?? false) b.author!,
      b.url,
    ].join(' · ');
    Clipboard.setData(ClipboardData(text: line));
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('书籍信息已复制')));
  }

  void _openMoreSheet() {
    final b = _detail?.book ?? _book;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.swap_horiz),
              title: const Text('换源'),
              subtitle: const Text('按章节自动对齐阅读进度'),
              onTap: () {
                Navigator.of(ctx).pop();
                _switchSource();
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('缓存到本地'),
              subtitle: const Text('全书章节离线可读'),
              onTap: () {
                Navigator.of(ctx).pop();
                if (!_downloading) _download();
              },
            ),
            ListenableBuilder(
              listenable: AppStore.I,
              builder: (c, _) {
                final inShelf = AppStore.I.inShelf(b.url);
                return ListTile(
                  leading: Icon(
                      inShelf ? Icons.bookmark_remove_outlined : Icons.bookmark_add_outlined),
                  title: Text(inShelf ? '移出书架' : '加入书架'),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    if (inShelf) {
                      AppStore.I.removeFromShelf(b.url);
                    } else {
                      AppStore.I.addToShelf(b, chapterCount: 0);
                    }
                  },
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制书籍链接'),
              onTap: () {
                Navigator.of(ctx).pop();
                Clipboard.setData(ClipboardData(text: b.url));
                ScaffoldMessenger.of(context)
                    .showSnackBar(const SnackBar(content: Text('链接已复制')));
              },
            ),
          ],
        ),
      ),
    );
  }

  void _switchSource() {
    // 详情没拉到也能换源（错误页用）：退回打开时的 book
    final d = _detail?.book ?? _book;
    showSourceSwitch(
      context,
      d,
      onSelected: (src, b) {
        StatsStore.I.addSourceSwitch(); // 换源大师徽章计数
        Navigator.of(context).pushReplacement(
            MaterialPageRoute(builder: (_) => BookDetailScreen(book: b)));
      },
    );
  }

  /// 全目录浮层（正序 / 倒序切换 + 跳章）。
  void _openToc() {
    final d = _detail;
    if (d == null) return;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.sizeOf(ctx).height * 0.78,
        child: StatefulBuilder(
          builder: (ctx, setSheet) {
            final n = d.chapters.length;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Row(
                    children: [
                      Text('目录',
                          style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                              fontSize: 16, fontWeight: FontWeight.w800)),
                      const SizedBox(width: 8),
                      Text('共 $n 章',
                          style: TextStyle(
                              fontSize: 11.5, color: Brand.fg3(ctx))),
                      const Spacer(),
                      PillChip(
                        _tocAsc ? '正序' : '倒序',
                        height: 28,
                        selected: false,
                        icon: Icon(
                            _tocAsc
                                ? Icons.arrow_downward
                                : Icons.arrow_upward,
                            size: 13),
                        onTap: () {
                          setSheet(() => _tocAsc = !_tocAsc);
                          setState(() {});
                        },
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: Builder(builder: (c) {
                    // EPUB 多级目录：卷行加粗，子级按层级缩进
                    final depths =
                        d.chapters.map((e) => e.depth ?? 0).toList();
                    final layered = depths.any((v) => v > 0);
                    return ListView.builder(
                    itemCount: n,
                    itemBuilder: (c, i) {
                      final idx = _tocAsc ? i : n - 1 - i;
                      final depth = layered ? depths[idx] : 0;
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.only(
                            left: 20.0 + depth * 18.0, right: 20.0),
                        title: Text(d.chapters[idx].title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: depth == 0 && layered
                                  ? FontWeight.w700
                                  : null,
                            )),
                        onTap: () {
                          Navigator.of(ctx).pop();
                          _openReader(idx);
                        },
                      );
                    },
                    );
                  }),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _detail;
    final theme = Theme.of(context);
    final body = d == null
        ? (_error == null
            ? Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    if (_autoMsg != null) ...[
                      const SizedBox(height: 14),
                      Text(
                        _autoMsg!,
                        style: TextStyle(
                            fontSize: 12.5, color: Brand.fg3(context)),
                      ),
                    ],
                  ],
                ),
              )
            : Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child:
                          Text('加载失败：$_error', textAlign: TextAlign.center),
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        OutlinedButton(
                            onPressed: _load, child: const Text('重试')),
                        const SizedBox(width: 10),
                        // 当前源打不开时最常见的出路：换个源试试
                        OutlinedButton(
                            onPressed: _switchSource,
                            child: const Text('换源')),
                      ],
                    ),
                  ],
                ),
              ))
        : _content(theme, d);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            _topBar(theme),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: body,
                ),
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: d == null ? null : _bottomBar(theme, d),
    );
  }

  Widget _topBar(ThemeData theme) {
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(4, 5, 8, 0),
        child: Row(
          children: [
            IconButton(
              icon: Icon(Icons.arrow_back, size: 21, color: theme.hintColor),
              tooltip: '返回',
              onPressed: () => Navigator.of(context).maybePop(),
            ),
            const Spacer(),
            IconButton(
              icon: Icon(Icons.ios_share, size: 19, color: theme.hintColor),
              tooltip: '分享',
              onPressed: _share,
            ),
            IconButton(
              icon: Icon(Icons.more_horiz, size: 20, color: theme.hintColor),
              tooltip: '更多',
              onPressed: _openMoreSheet,
            ),
          ],
        ),
      ),
    );
  }

  Widget _content(ThemeData theme, BookDetail d) {
    final b = d.book;
    final n = d.chapters.length;
    // 目录预览：最近 3 章（无时间字段，按章节顺序给最新 3 章）
    final preview = <int>[
      for (var i = n - 1; i >= 0 && i >= n - 3; i--) i,
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 24),
      children: [
        // ------------------------------------------------------------ 书头
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BookCover(b, width: 94, height: 130, radius: 12),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(b.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 22,
                          height: 1.25,
                          fontWeight: FontWeight.w800)),
                  const SizedBox(height: 5),
                  if (b.author?.isNotEmpty ?? false)
                    Text(b.author!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 12.5, color: theme.hintColor)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      if (b.status?.isNotEmpty ?? false)
                        _tagPill(theme, b.status!),
                      _tagPill(theme, '共 $n 章'),
                    ],
                  ),
                  if (b.latest?.isNotEmpty ?? false) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(Icons.update,
                            size: 13, color: Brand.fg3(context)),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text('更新至 ${b.latest}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                  fontSize: 11.5, color: Brand.fg3(context))),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // ------------------------------------------------------------ 来源面板
        _sourcePanel(theme),

        const SizedBox(height: 12),

        // ------------------------------------------------------------ 按钮行
        Row(
          children: [
            ListenableBuilder(
              listenable: AppStore.I,
              builder: (context, _) {
                final inShelf = AppStore.I.inShelf(b.url);
                return Expanded(
                  child: BrandBtn(
                    inShelf ? '已在书架' : '加入书架',
                    icon: Icon(inShelf
                        ? Icons.bookmark
                        : Icons.bookmark_add_outlined),
                    style: inShelf
                        ? BrandBtnStyle.outline
                        : BrandBtnStyle.primary,
                    onTap: () {
                      if (inShelf) {
                        AppStore.I.removeFromShelf(b.url);
                      } else {
                        AppStore.I.addToShelf(b, chapterCount: n);
                      }
                    },
                  ),
                );
              },
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              child: BrandBtn.icon(
                const Icon(Icons.headset, size: 19),
                onTap: () => _openReader(_startIndex(), tts: true),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 52,
              child: BrandBtn.icon(
                const Icon(Icons.ios_share, size: 18),
                onTap: _share,
              ),
            ),
          ],
        ),
        const SizedBox(height: 18),

        // ------------------------------------------------------------ 简介
        if (b.intro?.isNotEmpty ?? false) ...[
          const SectionHead('简介',
              padding: EdgeInsets.fromLTRB(0, 0, 0, 8)),
          Text(b.intro!,
              style: theme.textTheme.bodyMedium?.copyWith(
                  fontSize: 12.5, height: 1.85, color: theme.hintColor)),
          const SizedBox(height: 18),
        ],

        // ------------------------------------------------------------ 目录预览
        SectionHead(
          '目录',
          padding: const EdgeInsets.fromLTRB(0, 0, 0, 2),
          action: '共 $n 章 · ${_tocAsc ? '正序' : '倒序'} ⌄',
          grayAction: true,
          onAction: _openToc,
        ),
        for (final i in preview)
          InkWell(
            onTap: () => _openReader(i),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 9),
              child: Row(
                children: [
                  Expanded(
                    child: Text(d.chapters[i].title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(
                            fontSize: 13.5,
                            color: i == n - 1
                                ? theme.colorScheme.onSurface
                                : theme.hintColor)),
                  ),
                  if (i == n - 1)
                    Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1.5),
                        decoration: BoxDecoration(
                          color: Brand.greenSoft,
                          borderRadius: BorderRadius.circular(5),
                        ),
                        child: const Text('最新',
                            style: TextStyle(
                                fontSize: 9.5,
                                fontWeight: FontWeight.w700,
                                color: Brand.green)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (d.nextChaptersUrl != null)
          Center(
            child: _loadingMore
                ? const Padding(
                    padding: EdgeInsets.all(8),
                    child:
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)))
                : TextButton(
                    onPressed: _loadMoreChapters,
                    child: const Text('加载更多目录'),
                  ),
          ),
      ],
    );
  }

  Widget _tagPill(ThemeData theme, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2.5),
      decoration: BoxDecoration(
        color: theme.brightness == Brightness.dark
            ? const Color(0xFF20292B)
            : const Color(0xFFEEF2EA),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10.5, color: theme.hintColor)),
    );
  }

  /// 来源面板：当前源 + 可用源数 + 换源（效果图的「一句话讲清换源」）。
  Widget _sourcePanel(ThemeData theme) {
    final name = sourceNameOf(_src.id);
    final sub = _availSources == null
        ? '正在检索其他书源…'
        : '$_availSources 个来源可用 · 换源后按章节自动对齐进度';
    return Container(
      padding: const EdgeInsets.fromLTRB(13, 12, 10, 12),
      decoration: BoxDecoration(
        color: Brand.card(context),
        border: Border.all(color: Brand.hair(context)),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: Brand.greenSoft,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.layers_outlined,
                size: 18, color: Brand.green),
          ),
          const SizedBox(width: 11),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('当前来源 · $name',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium
                        ?.copyWith(fontSize: 13, fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(sub,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                        fontSize: 11, color: Brand.fg3(context))),
              ],
            ),
          ),
          const SizedBox(width: 6),
          BrandBtn('换源',
              style: BrandBtnStyle.outline,
              height: 31,
              radius: 999,
              onTap: _switchSource),
        ],
      ),
    );
  }

  /// 底部固定栏：目录 / 缓存 / 加书架并开始阅读。
  Widget _bottomBar(ThemeData theme, BookDetail d) {
    return Container(
      padding: EdgeInsets.fromLTRB(
          18, 8, 16, 8 + MediaQuery.viewPaddingOf(context).bottom),
      decoration: BoxDecoration(
        color: Brand.card(context).withValues(alpha: 0.97),
        border: Border(top: BorderSide(color: Brand.hair(context))),
      ),
      child: Row(
        children: [
          _barItem(theme, Icons.menu_book_outlined, '目录', _openToc),
          const SizedBox(width: 18),
          _barItem(
            theme,
            _downloading ? Icons.close : Icons.download_outlined,
            _downloading ? '缓存 $_dlDone/$_dlTotal' : '缓存',
            () {
              if (_downloading) {
                setState(() => _cancelDl = true);
              } else {
                _download();
              }
            },
          ),
          const SizedBox(width: 14),
          ListenableBuilder(
            listenable: AppStore.I,
            builder: (context, _) {
              final inShelf = AppStore.I.inShelf(d.book.url);
              return BrandBtn(
                inShelf ? '开始阅读' : '加书架并开始阅读',
                icon: const Icon(Icons.auto_stories_outlined),
                height: 42,
                flex: 1,
                onTap: inShelf
                    ? () => _openReader(_startIndex())
                    : _addAndRead,
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _barItem(
      ThemeData theme, IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 20, color: theme.hintColor),
          const SizedBox(height: 2),
          Text(label,
              style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.w600,
                  color: theme.hintColor)),
        ],
      ),
    );
  }

  int _startIndex() {
    final e = AppStore.I.shelfEntry(_detail?.book.url ?? _book.url) ??
        AppStore.I.history.firstWhere(
            (x) => x.book.url == (_detail?.book.url ?? _book.url),
            orElse: () => ShelfEntry(book: _book));
    final n = _detail?.chapters.length ?? 0;
    if (n == 0) return 0;
    return e.chapterIndex.clamp(0, n - 1).toInt();
  }
}
