// 漫画阅读器（图片书源 bookSourceType=2，对齐 legado 图片源与厚墨系漫画阅读）。
//
// 与文本阅读器完全分开：图片书的「页」= 一张图，没有排版/分页/听书，
// 有的只是——左右翻页（可切上下滚动）、双指缩放、章节切换、进度记录。
// 图片下载走书源自己的 header（UA/Cookie/Referer 一条链），内存 LRU 常驻
// 已解码字节数组，翻回上一页零等待。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../data/image_downloader.dart';
import '../data/image_file_cache.dart';
import '../models.dart';
import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../theme.dart';
import 'book_detail_screen.dart';

/// 单章图片字节缓存（进程内 LRU，~64MB 封顶）。
class _ImageCache {
  _ImageCache._();

  static final Map<String, Uint8List> _m = {};
  static final List<String> _order = [];
  static const int _maxBytes = 64 << 20;
  static int _bytes = 0;

  static Uint8List? get(String k) {
    final v = _m[k];
    if (v == null) return null;
    _order.remove(k);
    _order.add(k);
    return v;
  }

  static void put(String k, Uint8List v) {
    if (_m.containsKey(k)) return;
    _m[k] = v;
    _order.add(k);
    _bytes += v.length;
    while (_bytes > _maxBytes && _order.isNotEmpty) {
      final old = _m.remove(_order.removeAt(0));
      if (old != null) _bytes -= old.length;
    }
  }
}

class ImageReaderScreen extends StatefulWidget {
  const ImageReaderScreen({
    super.key,
    required this.book,
    required this.chapterIndex,
  });

  final Book book;
  final int chapterIndex;

  @override
  State<ImageReaderScreen> createState() => _ImageReaderScreenState();
}

class _ImageReaderScreenState extends State<ImageReaderScreen> {
  final _store = AppStore.I;
  late Book _book;
  late int _chIdx;

  /// 进阅读器时恢复到上次的章内页（书架进度记录）。
  int _startPage = 0;
  List<Chapter> _chapters = const [];
  List<String> _images = const [];
  bool _loading = true;
  String? _error;
  bool _vertical = false; // false = 左右翻页（默认），true = 上下滚动
  final _pageCtrl = PageController();
  final _scrollCtrl = ScrollController();
  final Map<int, _ImgState> _states = {}; // 页号 → 加载状态

  @override
  void initState() {
    super.initState();
    _book = widget.book;
    _chIdx = widget.chapterIndex;
    final e = _store.shelfEntry(_book.url);
    if (e != null && e.chapterIndex == _chIdx && e.page > 0) {
      _startPage = e.page;
    }
    _load();
  }

  @override
  void dispose() {
    _store.flushProgress();
    _pageCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  NovelSource? get _src {
    final s = sourceById(_book.sourceId);
    return s;
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _images = const [];
      _states.clear();
    });
    try {
      var detail = await _store.cachedDetail(_book);
      if (detail == null || detail.chapters.isEmpty) {
        final s = _src;
        if (s == null) throw Exception('书源不存在，可能已被删除');
        detail = await s.fetchDetail(_book);
        if (detail.chapters.isEmpty) throw Exception('未解析到章节');
        _store.setChapterCount(_book.url, detail.chapters.length);
      }
      _chapters = detail.chapters;
      if (_chIdx >= _chapters.length) _chIdx = 0;
      final s = _src;
      if (s == null) throw Exception('书源不存在，可能已被删除');
      final imgs = await _store.chapterImages(s, detail, _chapters[_chIdx]);
      if (imgs.isEmpty) throw Exception('本章没有解析到图片（站点可能改版）');
      if (!mounted) return;
      setState(() {
        _images = imgs;
        _loading = false;
      });
      // 恢复到上次的章内页（换章时 _startPage 归零）；进度按恢复后的页写，
      // 否则 jumpToPage 之前的 _saveProgress 会把页码覆写成 0
      final p = _startPage.clamp(0, imgs.length - 1);
      _startPage = 0;
      _saveProgress(page: p);
      if (p > 0) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_vertical && _pageCtrl.hasClients) {
            _pageCtrl.jumpToPage(p);
          }
        });
      }
      _prefetch(p);
      unawaited(_prefetchNextChapter(detail));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e'.replaceFirst('Exception: ', '');
      });
    }
  }

  void _saveProgress({int? page}) {
    if (_chapters.isEmpty) return;
    _store.updateProgress(
      _book,
      chapterIndex: _chIdx,
      chapterTitle: _chapters[_chIdx].title,
      page: page ?? (_vertical ? 0 : (_pageCtrl.hasClients ? _pageCtrl.page?.round() ?? 0 : 0)),
      paragraph: 0,
      chapterCount: _chapters.length,
    );
  }

  void _prefetch(int from) {
    // 预取当前页起的 3 张图（原图字节），翻页零等待
    for (var i = from; i < from + 3 && i < _images.length; i++) {
      _loadImage(i);
    }
  }

  /// 章末零等待：后台把下一章前 2 张图落盘（图片字节缓存命中后离线也可读）。
  Future<void> _prefetchNextChapter(BookDetail detail) async {
    final next = _chIdx + 1;
    if (next >= detail.chapters.length) return;
    final src = _src;
    if (src == null) return;
    try {
      final imgs = await _store.chapterImages(src, detail, detail.chapters[next]);
      for (final u in imgs.take(2)) {
        if (!u.startsWith('http') || await ImageFileCache.has(u)) continue;
        final bytes = await fetchImageBytes(u, src: src, referer: _book.url);
        await ImageFileCache.write(u, bytes);
      }
    } catch (_) {
      // 预取失败不影响本章阅读
    }
  }

  Future<void> _loadImage(int idx) async {
    if (_states[idx] != null) return;
    final url = _images[idx];
    final cached = _ImageCache.get(url);
    if (cached != null) {
      _states[idx] = _ImgState(data: cached);
      if (mounted) setState(() {});
      return;
    }
    _states[idx] = _ImgState();
    try {
      // 磁盘缓存优先：断网也能翻已读过的章节
      final disk = await ImageFileCache.read(url);
      if (disk != null) {
        _ImageCache.put(url, disk);
        _states[idx] = _ImgState(data: disk);
      } else {
        final bytes = await _fetchImage(url);
        _ImageCache.put(url, bytes);
        unawaited(ImageFileCache.write(url, bytes));
        _states[idx] = _ImgState(data: bytes);
      }
    } catch (e) {
      _states[idx] = _ImgState(error: '$e'.replaceFirst('Exception: ', ''));
    }
    if (mounted) setState(() {});
  }

  /// 图片下载：复用公共取图链路（书源 UA/Cookie/Referer 一条链）。
  Future<Uint8List> _fetchImage(String url) async {
    final src = _src;
    if (src == null) throw Exception('书源不存在，可能已被删除');
    return fetchImageBytes(url, src: src, referer: _book.url);
  }

  void _openDetail() {
    Navigator.of(context).push(MaterialPageRoute(
        builder: (_) => BookDetailScreen(book: _book)));
  }

  Future<void> _jumpChapter(int idx) async {
    if (idx < 0 || idx >= _chapters.length) return;
    setState(() => _chIdx = idx);
    await _load();
  }

  void _showToc() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView.builder(
          shrinkWrap: true,
          itemCount: _chapters.length,
          itemBuilder: (ctx, i) => ListTile(
            dense: true,
            selected: i == _chIdx,
            title: Text(_chapters[i].title, maxLines: 1,
                overflow: TextOverflow.ellipsis),
            onTap: () {
              Navigator.pop(ctx);
              _jumpChapter(i);
            },
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    PetStore.I.emit(PetAction.openBook);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            _topBar(),
            Expanded(child: _body()),
            _bottomBar(),
          ],
        ),
      ),
    );
  }

  Widget _topBar() {
    return SizedBox(
      height: 46,
      child: Row(
        children: [
          BackButton(color: Colors.white70, onPressed: () => Navigator.pop(context)),
          Expanded(
            child: Text(
              _chapters.isEmpty ? _book.title : _chapters[_chIdx].title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.menu_book_outlined, color: Colors.white70),
            tooltip: '章节目录',
            onPressed: _showToc,
          ),
          IconButton(
            icon: const Icon(Icons.info_outline, color: Colors.white70),
            tooltip: '书籍详情',
            onPressed: _openDetail,
          ),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
        CircularProgressIndicator(color: Brand.green),
        SizedBox(height: 12),
        Text('正在加载本章图片…', style: TextStyle(color: Colors.white70)),
      ]));
    }
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!, textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70)),
            const SizedBox(height: 12),
            OutlinedButton(onPressed: _load, child: const Text('重试')),
            const SizedBox(height: 8),
            OutlinedButton(
                onPressed: _chIdx + 1 < _chapters.length
                    ? () => _jumpChapter(_chIdx + 1)
                    : null,
                child: const Text('跳到下一章')),
          ],
        ),
      );
    }
    return _vertical ? _verticalBody() : _pagedBody();
  }

  Widget _pagedBody() {
    return PageView.builder(
      controller: _pageCtrl,
      itemCount: _images.length,
      onPageChanged: (i) {
        _prefetch(i);
        _saveProgress();
      },
      itemBuilder: (ctx, i) => _imagePage(i),
    );
  }

  Widget _verticalBody() {
    return ListView.builder(
      controller: _scrollCtrl,
      itemCount: _images.length,
      itemBuilder: (ctx, i) => _imagePage(i),
    );
  }

  Widget _imagePage(int i) {
    _loadImage(i);
    final st = _states[i];
    final child = st == null || st.loading
        ? const Center(
            child: SizedBox(
                width: 26,
                height: 26,
                child: CircularProgressIndicator(color: Colors.white24)))
        : st.error != null
            ? Center(
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.broken_image_outlined,
                    size: 40, color: Colors.white24),
                const SizedBox(height: 8),
                Text(st.error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.white38, fontSize: 12)),
              ]))
            : InteractiveViewer(
                maxScale: 4,
                child: Center(
                    child: Image.memory(st.data!, fit: BoxFit.contain)),
              );
    return Container(
      color: Colors.black,
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _bottomBar() {
    final n = _images.length;
    return SizedBox(
      height: 48,
      child: Row(
        children: [
          TextButton(
            onPressed: _chIdx > 0 ? () => _jumpChapter(_chIdx - 1) : null,
            child: const Text('上一章',
                style: TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
          const Spacer(),
          Text('$_chIdx+1/${_chapters.length} 章 · $n 图',
              style: const TextStyle(color: Colors.white38, fontSize: 11)),
          const Spacer(),
          IconButton(
            tooltip: _vertical ? '切换为左右翻页' : '切换为上下滚动',
            onPressed: () => setState(() => _vertical = !_vertical),
            icon: Icon(
              _vertical ? Icons.swap_horiz : Icons.swap_vert,
              color: Colors.white70,
              size: 20,
            ),
          ),
          TextButton(
            onPressed:
                _chIdx + 1 < _chapters.length ? () => _jumpChapter(_chIdx + 1) : null,
            child: const Text('下一章',
                style: TextStyle(color: Colors.white70, fontSize: 12.5)),
          ),
        ],
      ),
    );
  }
}

class _ImgState {
  _ImgState({this.data, this.error});
  final Uint8List? data;
  final String? error;
  bool get loading => data == null && error == null;
}
