import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../edge_tts.dart';
import '../models.dart';
import '../paginate.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../theme.dart';
import '../widgets.dart';

/// 阅读器：左右翻页 / 上下滚动双模式，
/// 目录、进度条、字号行距、主题、书签、离线、换源。
class ReaderScreen extends StatefulWidget {
  final Book book;
  final int chapterIndex;
  final int page; // 翻页模式页码
  final int paragraph; // 滚动模式 = 滚动偏移量

  const ReaderScreen({
    super.key,
    required this.book,
    this.chapterIndex = 0,
    this.page = 0,
    this.paragraph = 0,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> with WidgetsBindingObserver {
  late NovelSource _src;
  BookDetail? _detail;
  Object? _error;
  bool _loading = true;

  late int _chIdx;
  List<String> _paras = [];
  int _page = 0;
  int _startPage = 0;
  int _startOffset = 0;
  bool _menu = false;
  bool _showSettings = false;

  final _scrollCtrl = ScrollController();
  Timer? _scrollSave;

  // 滚动模式跨章连载：已加载章节及其在合并内容中的起始像素
  // （首章起始 = 顶部内边距；后续章起始 = 旧 maxScrollExtent - 底部内边距）
  static const double _kPadTop = 12;
  static const double _kPadBottom = 24;
  List<(int, double)> _chStarts = [];
  int _gen = 0; // 章节切换代数：作废进行中的连载加载
  bool _loadingMore = false;
  DateTime _lastMoreFail = DateTime.fromMillisecondsSinceEpoch(0);

  // 分页缓存（_pagesKey 标记当前分页对应的尺寸/样式）
  List<List<String>>? _pages;
  Object? _pagesKey;
  double _lastW = 0, _lastH = 0;
  TextScaler _lastScaler = TextScaler.noScaling;
  Timer? _repagTimer;

  // 偏好快照：只有字体/行距/主题/翻页模式变化才重建阅读器
  late int _pTheme;
  late double _pFont;
  late double _pLh;
  late bool _pPag;

  // 听书（TTS）
  final FlutterTts _tts = FlutterTts();
  List<Map<String, String>> _voiceList = []; // 系统音色（name/locale，仅作在线失败时的垫音回退）
  /// 在线音色表（Edge TTS）：prefs 值 → (显示名, 合成音色 id)。音色面板只列这些。
  static const _edgeVoices = <String, (String, String)>{
    '__edge_hsiaochen__': ('小臻（在线）', 'zh-TW-HsiaoChenNeural'),
    '__edge_hsiaoyu__': ('小瑜（在线）', 'zh-TW-HsiaoYuNeural'),
    '__edge_xiaoxiao__': ('晓晓·甜美女声（在线）', 'zh-CN-XiaoxiaoNeural'),
    '__edge_yunxi__': ('云希·阳光青年（在线）', 'zh-CN-YunxiNeural'),
    '__edge_yunjian__': ('云健·解说男声（在线）', 'zh-CN-YunjianNeural'),
    '__edge_yunxia__': ('云夏·清亮少年（在线）', 'zh-CN-YunxiaNeural'),
    '__edge_xiaoyi__': ('晓伊·活力女声（在线）', 'zh-CN-XiaoyiNeural'),
    '__edge_yunyang__': ('云扬·新闻播报（在线）', 'zh-CN-YunyangNeural'),
    '__edge_xiaobei__': ('晓北·东北味（在线）', 'zh-CN-liaoning-XiaobeiNeural'),
    '__edge_xiaoni__': ('晓妮·陕西味（在线）', 'zh-CN-shaanxi-XiaoniNeural'),
    '__edge_hiumaan__': ('晓曼·粤语女声（在线）', 'zh-HK-HiuMaanNeural'),
    '__edge_yunjhe__': ('云哲·台湾男声（在线）', 'zh-TW-YunJheNeural'),
  };
  static const _kVoiceDefault = '__edge_hsiaochen__'; // 默认在线音色
  final AudioPlayer _edgePlayer = AudioPlayer(); // 在线音色播放器
  bool _edgeBroken = false; // 会话内合成失败过 → 本场回退系统 TTS
  Completer<void>? _utter; // 当前朗读完成信号（完成/取消/出错都会触发）
  bool _speaking = false;
  bool _ttsPaused = false;
  int _ttsIdx = 0; // 待读段落下标
  int _ttsCur = -1; // 正在朗读的段落（高亮/跟随）
  bool _ttsLoopOn = false;
  final Map<int, GlobalKey> _paraKeys = {};

  @override
  void initState() {
    super.initState();
    _src = sourceById(widget.book.sourceId) ?? allSources.first;
    _chIdx = widget.chapterIndex;
    _startPage = widget.page;
    _startOffset = widget.paragraph;
    final p = _prefs;
    _pTheme = p.theme;
    _pFont = p.fontSize;
    _pLh = p.lineHeight;
    _pPag = p.paginate;
    AppStore.I.addListener(_onPrefs);
    _scrollCtrl.addListener(() {
      if (_prefs.paginate) return;
      final pos = _scrollCtrl.position;
      // 滚动到当前章末尾附近：自动加载下一章无缝续读
      if (pos.pixels >= pos.maxScrollExtent - 400) _loadMore();
      _scrollSave?.cancel();
      _scrollSave = Timer(const Duration(milliseconds: 600), () {
        if (!mounted || _prefs.paginate) return;
        // 跨过章界后同步当前章节（标题/进度条跟随）
        final ci = _chapterFromScroll();
        if (ci != _chIdx) setState(() => _chIdx = ci);
        _saveProgress(silent: true);
      });
    });
    _tts.setCompletionHandler(_finishUtter);
    _tts.setCancelHandler(_finishUtter);
    _tts.setErrorHandler((_) => _finishUtter());
    // 在线音色播放完成 → 同一完成信号（_utter）
    _edgePlayer.onPlayerComplete.listen((_) => _finishUtter());
    WidgetsBinding.instance.addObserver(this);
    _loadDetail();
    _loadVoices(); // 预载系统音色清单（在线失败时的垫音回退用）
    // 音色迁移：旧的系统/预设音色值 → 默认在线音色（面板只保留在线音色）
    Future.microtask(() {
      if (!_edgeVoices.containsKey(_prefs.ttsVoice)) {
        _store.setTtsVoice(_kVoiceDefault);
      }
    });
  }

  Future<void> _loadVoices() async {
    try {
      final v = await _tts.getVoices;
      final list = <Map<String, String>>[];
      if (v is List) {
        for (final x in v) {
          if (x is! Map) continue;
          list.add(Map<String, String>.from(
              x.map((k, val) => MapEntry(k.toString(), val.toString()))));
        }
      }
      if (mounted) setState(() => _voiceList = list);
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 关窗退出时引擎可能不走 widget dispose，这里兜底停掉听书
    if (state == AppLifecycleState.detached && _speaking) {
      _speaking = false;
      try {
        unawaited(_tts.stop());
      } catch (_) {}
      try {
        unawaited(_edgePlayer.stop());
      } catch (_) {}
    }
  }

  void _onPrefs() {
    final p = _prefs;
    if (p.theme != _pTheme ||
        p.fontSize != _pFont ||
        p.lineHeight != _pLh ||
        p.paginate != _pPag) {
      final wasPag = _pPag;
      _pTheme = p.theme;
      _pFont = p.fontSize;
      _pLh = p.lineHeight;
      _pPag = p.paginate;
      if (mounted) setState(() {});
      // 滚动（已连载多章）→ 翻页：拆回当前单章再分页，避免跨章混排
      if (p.paginate && !wasPag && _chStarts.length > 1) {
        _loadChapter(_chIdx);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (_speaking) {
      _speaking = false;
      try {
        unawaited(_tts.stop());
      } catch (_) {}
    }
    try {
      unawaited(_edgePlayer.stop());
    } catch (_) {}
    unawaited(_edgePlayer.dispose());
    AppStore.I.removeListener(_onPrefs);
    AppStore.I.cancelPrefetch();
    _scrollSave?.cancel();
    _repagTimer?.cancel();
    _scrollCtrl.dispose();
    super.dispose();
  }

  AppStore get _store => AppStore.I;
  ReaderPrefs get _prefs => _store.prefs;

  Book get _book => _detail?.book ?? widget.book;
  String get _chapterTitle => _chIdx >= 0 && _chIdx < (_detail?.chapters.length ?? 0)
      ? _detail!.chapters[_chIdx].title
      : '';

  Future<void> _loadDetail() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final d = await _src.fetchDetail(_book);
      _detail = d;
    } catch (e) {
      final cached = await _store.cachedDetail(_book);
      if (cached == null) {
        if (mounted) {
          setState(() {
            _loading = false;
            _error = e;
          });
        }
        return;
      }
      _detail = cached;
      _snack('网络不可用，正在离线阅读');
    }
    if (!mounted) return;
    if (_detail == null || _detail!.chapters.isEmpty) {
      setState(() {
        _loading = false;
        _error = Exception('没有可用章节');
      });
      return;
    }
    _chIdx = _chIdx.clamp(0, _detail!.chapters.length - 1).toInt();
    await _loadChapter(_chIdx, startPage: widget.page, startOffset: widget.paragraph);
  }

  Future<void> _loadChapter(
    int idx, {
    bool toEnd = false,
    int startPage = 0,
    int startOffset = 0,
  }) async {
    if (_detail == null || idx < 0 || idx >= _detail!.chapters.length) return;
    setState(() {
      _gen++; // 作废进行中的连载加载
      _chIdx = idx;
      _chStarts = [(idx, _kPadTop)];
      _lastMoreFail = DateTime.fromMillisecondsSinceEpoch(0);
      _loading = true;
      _error = null;
      _pages = null;
      _pagesKey = null;
      _startPage = toEnd ? 1 << 30 : startPage;
      _startOffset = startOffset;
      _page = 0;
      _ttsIdx = 0; // 听书：切章后从新章开头读
      _ttsCur = -1;
    });
    try {
      final paras =
          await _store.chapterText(_src, _detail!, _detail!.chapters[idx]);
      if (!mounted) return;
      setState(() {
        _paras = paras;
        _loading = false;
        _page = 0;
      });
      _saveProgress();
      // 自动预取后续章节（后台低优先级，切换章节/退出时被取消）
      if (_prefs.autoCache > 0 && mounted && _detail != null) {
        final src = _src;
        final d = _detail!;
        _store.prefetchNext(src, d, idx + 1, _prefs.autoCache);
      }
      if (_startOffset > 0) {
        // 滚动模式恢复位置
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.jumpTo(_startOffset
                .toDouble()
                .clamp(0, _scrollCtrl.position.maxScrollExtent)
                .toDouble());
          }
        });
      }
      // 滚动模式：本章不足一屏（短章）时自动续载下一章
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_prefs.paginate && _scrollCtrl.hasClients) {
          if (_scrollCtrl.position.maxScrollExtent < 300) _loadMore();
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
    }
  }

  void _saveProgress({bool silent = false}) {
    if (_detail == null) return;
    _store.updateProgress(
      _book,
      chapterIndex: _chIdx,
      chapterTitle: _chapterTitle,
      page: _prefs.paginate ? _page : 0,
      paragraph: _prefs.paginate
          ? 0
          : _scrollCtrl.hasClients
              ? _scrollRelativeOffset().round()
              : 0,
      silent: silent,
      chapterCount: _detail!.chapters.length,
    );
  }

  /// 滚动位置换算为「当前章内单章坐标」：定位所属章 → 取章内相对偏移。
  /// 恢复时以单章内容 jumpTo 该值，与旧数据完全兼容（单章时 base=顶部内边距）。
  double _scrollRelativeOffset() {
    if (!_scrollCtrl.hasClients) return 0;
    final px = _scrollCtrl.offset;
    if (_chStarts.isEmpty) return px;
    var base = _chStarts.first.$2;
    for (final (_, s) in _chStarts) {
      if (px >= s) {
        base = s;
      } else {
        break;
      }
    }
    return px - base + _kPadTop;
  }

  /// 滚动位置所属章节（跨章连载时跟随阅读位置）。
  int _chapterFromScroll() {
    if (_chStarts.isEmpty || !_scrollCtrl.hasClients) return _chIdx;
    final px = _scrollCtrl.offset;
    var ci = _chStarts.first.$1;
    for (final (c, s) in _chStarts) {
      if (px >= s) {
        ci = c;
      } else {
        break;
      }
    }
    return ci;
  }

  bool get _atBookEnd =>
      !_prefs.paginate &&
      _chStarts.isNotEmpty &&
      _detail != null &&
      _chStarts.last.$1 >= _detail!.chapters.length - 1;

  /// 滚动模式连载：靠近章末自动加载下一章并附加显示，实现无缝续读。
  Future<void> _loadMore() async {
    if (_prefs.paginate || _loading || _loadingMore || _detail == null) return;
    if (_chStarts.isEmpty) return;
    final next = _chStarts.last.$1 + 1;
    if (next >= _detail!.chapters.length) return;
    if (DateTime.now().difference(_lastMoreFail).inSeconds < 5) return;
    final g = _gen;
    _loadingMore = true;
    try {
      final paras =
          await _store.chapterText(_src, _detail!, _detail!.chapters[next]);
      if (!mounted || g != _gen || _prefs.paginate) return;
      final px =
          _scrollCtrl.hasClients ? _scrollCtrl.position.maxScrollExtent : 0.0;
      setState(() {
        _paras.addAll(paras);
        // 新章起点 = 附加前的内容末尾（去掉当时挂在末尾的底部内边距）
        _chStarts.add((next, px - _kPadBottom));
      });
      _saveProgress(silent: true); // 跨章位置立即落盘
    } catch (_) {
      _lastMoreFail = DateTime.now(); // 失败冷却 5 秒，避免死循环重试
    } finally {
      _loadingMore = false;
    }
    // 内容不足一屏（短章）时继续加载，直到铺满或读完
    if (mounted && !_prefs.paginate && g == _gen && _scrollCtrl.hasClients) {
      final p = _scrollCtrl.position;
      if (p.maxScrollExtent < 300) _loadMore();
    }
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ---------- 翻页 / 换章 ----------

  List<List<String>> get _currentPages => _pages ?? const [[]];

  void _goNext() {
    if (_loading || _detail == null) return;
    if (_page < _currentPages.length - 1) {
      setState(() => _page++);
      _saveProgress();
      return;
    }
    if (_chIdx < _detail!.chapters.length - 1) {
      _loadChapter(_chIdx + 1);
    } else {
      _snack('已经是最后一章了');
      setState(() {});
    }
  }

  void _goPrev() {
    if (_loading || _detail == null) return;
    if (_page > 0) {
      setState(() => _page--);
      _saveProgress();
      return;
    }
    if (_chIdx > 0) {
      _loadChapter(_chIdx - 1, toEnd: true);
    } else {
      _snack('已经是第一章了');
    }
  }

  void _jumpChapter(int idx) {
    if (_detail == null) return;
    if (idx < 0 || idx >= _detail!.chapters.length) return;
    setState(() => _menu = false);
    _loadChapter(idx);
  }

  // ---------- 主题配色（与全局主题同步） ----------

  ({Color bg, Color fg, Color dim}) _colors() => readerColors(_prefs.theme);

  TextStyle get _bodyStyle => TextStyle(
        fontSize: _prefs.fontSize,
        height: _prefs.lineHeight,
        color: _colors().fg,
      );

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final c = _colors();
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final w = box.maxWidth - 32;
            final h = box.maxHeight - 24;
            _lastW = w;
            _lastH = h;
            final ts = MediaQuery.textScalerOf(context);
            _lastScaler = ts;
            if (w > 0 && h > 0) {
              final key = Object.hash(identityHashCode(_paras), w, h,
                  _prefs.fontSize, _prefs.lineHeight, ts.toString());
              if (_pages == null) {
                // 新章节首排：立即分页（避免白屏）
                _pages = paginateParas(
                  paras: _paras,
                  width: w,
                  height: h,
                  style: _bodyStyle,
                  paraSpacing: _prefs.fontSize * 0.6,
                  textScaler: ts,
                );
                _pagesKey = key;
                if (_startPage != 0) {
                  _page = _startPage >= _pages!.length
                      ? _pages!.length - 1
                      : _startPage;
                  _startPage = 0;
                }
              } else if (_pagesKey != key) {
                // 窗口拖拽/字号变化：防抖重排，期间沿用旧分页（防止每帧全量重排卡死）
                _repagTimer?.cancel();
                _repagTimer = Timer(
                    const Duration(milliseconds: 160), _repaginate);
              }
            }
            if (_pages != null && _pages!.isNotEmpty) {
              _page = _page.clamp(0, _pages!.length - 1).toInt();
            }

            return Stack(
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) {
                    if (!_prefs.paginate) {
                      setState(() => _menu = !_menu);
                      return;
                    }
                    final third = box.maxWidth / 3;
                    if (d.globalPosition.dx < third) {
                      _goPrev();
                    } else if (d.globalPosition.dx > third * 2) {
                      _goNext();
                    } else {
                      setState(() => _menu = !_menu);
                    }
                  },
                  child: _buildContent(),
                ),
                if (_loading) _overlay(const CircularProgressIndicator()),
                if (_error != null) _overlay(_errorView()),
                // 加载/出错期间没有菜单入口，提供返回控件防止“出不去”
                if ((_loading || _error != null) && Navigator.of(context).canPop())
                  Positioned(
                    top: 4,
                    left: 4,
                    child: IconButton(
                      icon: Icon(Icons.arrow_back, color: _colors().fg),
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                if (_menu) _topBar(c),
                if (_menu) _bottomPanel(c),
                if (_speaking && !_menu) _ttsBar(c),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 防抖重排（窗口尺寸变化 / 字号行距变化后调用）。
  void _repaginate() {
    if (!mounted || _lastW <= 0 || _lastH <= 0) return;
    final pages = paginateParas(
      paras: _paras,
      width: _lastW,
      height: _lastH,
      style: _bodyStyle,
      paraSpacing: _prefs.fontSize * 0.6,
      textScaler: _lastScaler,
    );
    if (!mounted) return;
    setState(() {
      _pages = pages;
      _pagesKey = Object.hash(identityHashCode(_paras), _lastW, _lastH,
          _prefs.fontSize, _prefs.lineHeight, _lastScaler.toString());
      _page = _page.clamp(0, pages.length - 1).toInt();
    });
  }

  Widget _overlay(Widget child) => Container(
        color: _bg().withValues(alpha: 0.7),
        alignment: Alignment.center,
        child: child,
      );

  Color _bg() => _colors().bg;

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text('加载失败：$_error',
                textAlign: TextAlign.center, style: TextStyle(color: _colors().dim)),
          ),
          OutlinedButton(
            onPressed: () => _loadChapter(_chIdx),
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }

  Widget _buildContent() {
    if (_prefs.paginate) {
      final pages = _pages;
      if (pages == null || pages.isEmpty) {
        // 尺寸无效（如最小化）时绝不渲染全部段落，等重排完成
        return Center(
            child: CircularProgressIndicator(color: _colors().fg));
      }
      final idx = _page.clamp(0, pages.length - 1).toInt();
      final page = pages[idx];
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < page.length; i++) ...[
              Text(page[i], style: _bodyStyle),
              if (i < page.length - 1)
                SizedBox(height: _prefs.fontSize * 0.6),
            ],
          ],
        ),
      );
    }
    final atEnd = _atBookEnd;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      itemCount: _paras.length + (atEnd ? 1 : 0),
      itemBuilder: (context, i) {
        if (i >= _paras.length) {
          // 已到全书最后一章的末尾
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 28),
            child: Center(
              child: Text(
                '—— 已是最新章节 ——',
                style: TextStyle(color: _colors().dim, fontSize: 13),
              ),
            ),
          );
        }
        return Padding(
          key: _paraKeys.putIfAbsent(i, () => GlobalKey()),
          padding: EdgeInsets.only(bottom: _prefs.fontSize * 0.6),
          child: _speaking && _ttsCur == i
              ? ColoredBox(
                  color: _prefs.theme == AppThemes.black
                      ? const Color(0x333DDC97)
                      : const Color(0x222F6B3C),
                  child: Text(_paras[i], style: _bodyStyle),
                )
              : Text(_paras[i], style: _bodyStyle),
        );
      },
    );
  }

  // ---------- 覆盖层 ----------

  Widget _topBar(({Color bg, Color fg, Color dim}) c) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: c.bg.withValues(alpha: 0.95),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              color: c.fg,
              onPressed: () {
                _saveProgress();
                Navigator.of(context).pop();
              },
            ),
            Expanded(
              child: Text(
                _chapterTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.fg, fontSize: 15),
              ),
            ),
            IconButton(
              tooltip: '目录',
              icon: const Icon(Icons.list),
              color: c.fg,
              onPressed: _showToc,
            ),
            IconButton(
              tooltip: '书签',
              icon: const Icon(Icons.bookmark_border),
              color: c.fg,
              onPressed: _showBookmarks,
            ),
            IconButton(
              tooltip: '换源',
              icon: const Icon(Icons.swap_horiz),
              color: c.fg,
              onPressed: _switchSource,
            ),
            IconButton(
              tooltip: '设置',
              icon: const Icon(Icons.tune),
              color: c.fg,
              onPressed: () => setState(() => _showSettings = !_showSettings),
            ),
          ],
        ),
      ),
    );
  }

  Widget _bottomPanel(({Color bg, Color fg, Color dim}) c) {
    final total = _detail?.chapters.length ?? 0;
    final inChapters = _currentPages.length;
    final frac = total <= 1 ? 0.0 : _chIdx / (total - 1);
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        color: c.bg.withValues(alpha: 0.95),
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_showSettings) _settingsBlock(c),
            Row(
              children: [
                Text('${_chIdx + 1}/${total > 0 ? total : 0}',
                    style: TextStyle(color: c.dim, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: frac.clamp(0.0, 1.0).toDouble(),
                    onChanged: (v) {
                      final idx = (v * (total - 1)).round();
                      _jumpChapter(idx);
                    },
                  ),
                ),
                Text(
                  _prefs.paginate && inChapters > 0
                      ? '${_page + 1}/$inChapters 页'
                      : '${_chIdx + 1}章',
                  style: TextStyle(color: c.dim, fontSize: 12),
                ),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              children: [
                _panelBtn(
                    _speaking ? Icons.stop : Icons.headset,
                    _speaking ? '停止' : '听书',
                    c,
                    () => unawaited(_speaking ? _stopTts() : _toggleTts())),
                _panelBtn(Icons.chevron_left, '上一章', c,
                    () => _jumpChapter(_chIdx - 1)),
                _panelBtn(
                    _prefs.paginate ? Icons.format_size : Icons.swap_vert,
                    _prefs.paginate ? '字号' : '滚动',
                    c, () => setState(() => _showSettings = !_showSettings)),
                _panelBtn(
                    _prefs.theme == AppThemes.black
                        ? Icons.light_mode
                        : Icons.dark_mode,
                    '主题',
                    c,
                    () => _store.setTheme(_prefs.theme == AppThemes.black
                        ? AppThemes.white
                        : AppThemes.black)),
                _panelBtn(_prefs.paginate ? Icons.swipe : Icons.article,
                    _prefs.paginate ? '翻页' : '滚动', c, () {
                  _store.setPaginate(!_prefs.paginate);
                  setState(() {});
                }),
                _panelBtn(Icons.chevron_right, '下一章', c,
                    () => _jumpChapter(_chIdx + 1)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelBtn(IconData icon, String label, ({Color bg, Color fg, Color dim}) c,
      VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: c.fg, size: 20),
            Text(label, style: TextStyle(color: c.dim, fontSize: 11)),
          ],
        ),
      ),
    );
  }

  Widget _settingsBlock(({Color bg, Color fg, Color dim}) c) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text('字号', style: TextStyle(color: c.dim, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _prefs.fontSize,
                min: 12,
                max: 32,
                divisions: 20,
                onChanged: (v) {
                  _store.setFontSize(v);
                  setState(() {}); // 分页键含字号，rebuild 时自动重排
                },
              ),
            ),
            Text('行距', style: TextStyle(color: c.dim, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _prefs.lineHeight,
                min: 1.2,
                max: 2.6,
                divisions: 14,
                onChanged: (v) {
                  _store.setLineHeight(v);
                  setState(() {});
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text('语速', style: TextStyle(color: c.dim, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _prefs.ttsRate,
                min: 0.1,
                max: 1.0,
                divisions: 9,
                onChanged: (v) {
                  _store.setTtsRate(v);
                  setState(() {});
                  unawaited(_tts.setSpeechRate(v)); // 播放中即时生效
                },
              ),
            ),
            Text(_prefs.ttsRate.toStringAsFixed(1),
                style: TextStyle(color: c.dim, fontSize: 12)),
          ],
        ),
        Row(
          children: [
            Text('音色', style: TextStyle(color: c.dim, fontSize: 12)),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: _edgeVoices.containsKey(_prefs.ttsVoice)
                    ? _prefs.ttsVoice
                    : _kVoiceDefault,
                items: [
                  for (final e in _edgeVoices.entries)
                    DropdownMenuItem(
                      value: e.key,
                      child: Text(
                        e.value.$1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                ],
                onChanged: (n) async {
                  if (n == null) return;
                  _store.setTtsVoice(n);
                  await _maybeEdgeNotice(); // 首次选择：一次性联网说明
                  setState(() {});
                  await _initTts(); // 统一应用
                },
              ),
            ),
          ],
        ),
        Row(
          children: [
            Text('音调', style: TextStyle(color: c.dim, fontSize: 12)),
            Expanded(
              child: Slider(
                value: _prefs.ttsPitch.clamp(0.5, 2.0),
                min: 0.5,
                max: 2.0,
                divisions: 15,
                onChanged: (v) {
                  _store.setTtsPitch(v);
                  setState(() {});
                  unawaited(_tts.setPitch(v)); // 播放中下一句生效
                },
              ),
            ),
            Text(_prefs.ttsPitch.toStringAsFixed(1),
                style: TextStyle(color: c.dim, fontSize: 12)),
          ],
        ),
        Row(
          children: [
            for (final (i, name) in const [
              (AppThemes.white, '锦绣白'),
              (AppThemes.black, '极光黑'),
            ])
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(name, style: const TextStyle(fontSize: 12)),
                  selected: _prefs.theme == i,
                  onSelected: (_) => _store.setTheme(i),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  // ---------- 听书（TTS） ----------

  void _finishUtter() {
    final c = _utter;
    if (c != null && !c.isCompleted) c.complete();
  }

  Future<void> _initTts() async {
    try {
      await _tts.setSpeechRate(_prefs.ttsRate);
      await _tts.setVolume(1.0);
      await _tts.setPitch(_prefs.ttsPitch);
    } catch (_) {}
    try {
      await _tts.setLanguage('zh-CN'); // 先语言后音色，音色覆盖语言选择
    } catch (_) {}
    try {
      if (_voiceList.isEmpty) await _loadVoices();
      final saved = _prefs.ttsVoice;
      // 在线音色：系统 TTS 先垫好回退音色（zh-TW 优先），
      // 合成失败时本会话直接用系统语音续读
      if (_edgeVoices.containsKey(saved)) {
        final tw = _pickZhTwVoice();
        if (tw != null) await _tts.setVoice(tw);
        return;
      }
      // 回退：自动选中中文语音
      for (final v in _voiceList) {
        final s = v.values.join(' ').toLowerCase();
        if (s.contains('zh') || s.contains('chinese')) {
          await _tts.setVoice(v);
          break;
        }
      }
    } catch (_) {}
  }

  /// 小智（温柔）：优先 Yaoyao（女）> Huihui（女）> 任意中文音色
  Map<String, String>? _pickGentleVoice() {
    Map<String, String>? soft, zhAny;
    for (final v in _voiceList) {
      final n = (v['name'] ?? '').toLowerCase();
      final s = v.values.join(' ').toLowerCase();
      final isZh = s.contains('zh') || s.contains('chinese');
      if (n.contains('yaoyao')) return v; // 柔和女声首选
      if (n.contains('huihui')) soft ??= v;
      if (isZh) zhAny ??= v;
    }
    return soft ?? zhAny;
  }

  /// 系统里找台湾腔音色（zh-TW/繁体：Hanhan/Taiwan/Hant），女声优先；没有返回 null。
  Map<String, String>? _findTwVoice() {
    Map<String, String>? tw;
    for (final v in _voiceList) {
      final n = (v['name'] ?? '').toLowerCase();
      final locale = (v['locale'] ?? '').toLowerCase();
      final s = v.values.join(' ').toLowerCase();
      final isTw = locale.startsWith('zh-tw') ||
          s.contains('cmn-hant') ||
          s.contains('zh-tw') ||
          n.contains('taiwan') ||
          n.contains('hanhan');
      if (!isTw) continue;
      final male = n.contains('male') && !n.contains('female');
      final cur = (tw?['name'] ?? '').toLowerCase();
      final curMale = cur.contains('male') && !cur.contains('female');
      if (tw == null || (curMale && !male)) tw = v; // 女声优先
    }
    return tw;
  }

  /// 台湾腔：有系统台语音色则用，没装则回退 _pickGentleVoice（柔和女声）。
  Map<String, String>? _pickZhTwVoice() => _findTwVoice() ?? _pickGentleVoice();

  // ---- 在线音色（Edge TTS）----

  /// 当前是否选中在线音色。
  bool get _edgeVoiceOn => _edgeVoices.containsKey(_prefs.ttsVoice);

  String _edgeVoiceId() =>
      _edgeVoices[_prefs.ttsVoice]?.$2 ?? _edgeVoices[_kVoiceDefault]!.$2;

  /// 段落 → 本地缓存 mp3 路径（<缓存>/tts/<sha1(voice|text)>.mp3，命中直接复用）。
  Future<String> _edgeSynthFile(String text) async {
    final dir = await _store.ttsAudioDir();
    if (dir == null) throw const EdgeTtsException('缓存目录不可用');
    final key = sha1
        .convert(utf8.encode('${_edgeVoiceId()}|$text'))
        .toString()
        .substring(0, 24);
    final f = File('${dir.path}/$key.mp3');
    if (await f.exists() && await f.length() > 500) return f.path;
    final bytes = await EdgeTts.synth(text, voice: _edgeVoiceId());
    await f.writeAsBytes(bytes, flush: true);
    return f.path;
  }

  /// 在线合成一段并开播；完成信号复用 _utter（onPlayerComplete → _finishUtter）。
  /// 合成失败抛出，由 [_speakSeg] 回退系统 TTS。
  Future<void> _edgePlay(String text) async {
    final path = await _edgeSynthFile(text);
    if (!mounted || !_speaking) return; // 等待合成期间已停止 → 不播
    // prosody 固定 +0%，语速在播放层生效（ttsRate 0.5 → 1.0 倍速）
    await _edgePlayer.setPlaybackRate((_prefs.ttsRate * 2).clamp(0.5, 2.0));
    await _edgePlayer.play(DeviceFileSource(path));
  }

  /// 预热下一段在线合成（播放第 i 段时调用；静默失败）。
  Future<void> _edgePreheat(int i) async {
    if (_edgeBroken || !_speaking || !_edgeVoiceOn || i >= _paras.length) {
      return;
    }
    final text = _paras[i].trim();
    if (text.isEmpty) return;
    try {
      await _edgeSynthFile(text);
    } catch (_) {}
  }

  /// 朗读一段：在线音色走 Edge 合成+播放；失败（一场一次提示）回退系统 TTS。
  /// 完成信号统一走 _utter/_finishUtter。
  Future<void> _speakSeg(String text) async {
    if (_edgeVoiceOn && !_edgeBroken) {
      try {
        await _edgePlay(text);
        return;
      } catch (_) {
        _edgeBroken = true;
        if (mounted) _snack('在线朗读合成失败，本场已回退系统语音');
        // 系统回退音色已在 _initTts 垫好，直接续读
      }
    }
    // Android 引擎挂死时 speak future 可能永不返回 → 限时防循环卡死
    await _tts.speak(text)
        .timeout(Duration(seconds: (text.length * 0.4 + 20).toInt()));
  }

  /// 在线音色首次选择：一次性联网说明（存 prefs.edgeNotice）。
  Future<void> _maybeEdgeNotice() async {
    if (_store.prefs.edgeNotice) return;
    _store.setEdgeNotice(true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('在线朗读说明'),
        content: const Text(
            '该音色通过微软 Edge 在线合成语音，需要联网；\n合成结果会缓存在本地，重复收听不再耗流量。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Future<void> _toggleTts() async {
    if (_speaking) {
      await _stopTts();
      return;
    }
    if (_detail == null || _paras.isEmpty || _loading) return;
    _edgeBroken = false; // 新一场播放：给在线合成重试机会（每场最多一次回退提示）
    await _initTts();
    if (!mounted) return;
    _speaking = true;
    _ttsPaused = false;
    _ttsIdx = _ttsStartIndex();
    _ttsCur = -1;
    setState(() {});
    unawaited(_ttsLoop());
  }

  Future<void> _stopTts() async {
    _speaking = false;
    _ttsPaused = false;
    _finishUtter(); // 解除循环阻塞
    try {
      await _tts.stop();
    } catch (_) {}
    try {
      await _edgePlayer.stop();
    } catch (_) {}
    if (mounted) setState(() => _ttsCur = -1);
  }

  void _togglePause() {
    if (!_speaking) return;
    setState(() => _ttsPaused = !_ttsPaused);
  }

  Future<void> _ttsLoop() async {
    if (_ttsLoopOn) return;
    _ttsLoopOn = true;
    try {
      while (_speaking && mounted) {
        if (_ttsPaused) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
          continue;
        }
        if (_ttsIdx >= _paras.length) {
          if (!await _ttsLoadNext()) break;
          continue;
        }
        final i = _ttsIdx;
        final text = _paras[i].trim();
        if (text.isEmpty) {
          _ttsIdx = i + 1;
          continue;
        }
        _ttsCur = i;
        if (mounted) setState(() {});
        _followPara(i);
        final c = Completer<void>();
        _utter = c;
        try {
          await _speakSeg(text);
        } catch (_) {
          _finishUtter();
          _speaking = false;
          if (mounted) {
            setState(() => _ttsCur = -1);
            _snack('听书启动失败，请检查系统语音引擎');
          }
          break;
        }
        // 段落已开播：并行预热下一段在线合成（静默失败）
        unawaited(_edgePreheat(i + 1));
        // 完成/取消/出错都会 complete；超时兜底防引擎挂死
        final sec = (text.length * 0.4 + 20).toInt();
        await c.future.timeout(Duration(seconds: sec), onTimeout: () {});
        if (!_speaking || !mounted) break;
        if (_ttsPaused) continue; // 暂停期间读完：不推进，恢复时重读本段
        if (_ttsIdx == i) _ttsIdx = i + 1;
      }
    } finally {
      _ttsLoopOn = false;
    }
  }

  Future<bool> _ttsLoadNext() async {
    final d = _detail;
    if (d == null) return false;
    if (_prefs.paginate) {
      if (_chIdx >= d.chapters.length - 1) return false;
      await _loadChapter(_chIdx + 1);
      _ttsIdx = 0;
      if (_paras.isNotEmpty) return true;
      if (_error != null) _snack('章节加载失败，听书已停止');
      return false;
    }
    // 滚动模式：已到最后连载章即止
    if (_chStarts.isEmpty || _chStarts.last.$1 >= d.chapters.length - 1) {
      return false;
    }
    final before = _paras.length;
    await _loadMore();
    if (_paras.length > before) return true;
    // 网络/冷却失败：稍候重试一次
    await Future<void>.delayed(const Duration(seconds: 6));
    if (!mounted || !_speaking) return false;
    final b2 = _paras.length;
    await _loadMore();
    return _paras.length > b2;
  }

  int _ttsStartIndex() {
    try {
      if (_prefs.paginate) {
        final pages = _pages;
        if (pages == null || pages.isEmpty || _paras.isEmpty) return 0;
        final pi = _page.clamp(0, pages.length - 1).toInt();
        final pageText = pages[pi];
        if (pageText.isNotEmpty) {
          final head = pageText.first.trim();
          if (head.length > 8) {
            final probe = head.substring(0, 8);
            final hit = _paras.indexWhere((p) => p.contains(probe));
            if (hit >= 0) return hit;
          }
        }
        // 比例兜底
        final est = (_paras.length * (pi + 1) / (pages.length + 1)).round();
        return est.clamp(0, _paras.length - 1).toInt();
      }
      // 滚动模式：按平均段高估算当前首屏段落
      if (_scrollCtrl.hasClients && _paras.isNotEmpty) {
        final pos = _scrollCtrl.position;
        final avg = pos.maxScrollExtent / _paras.length;
        if (avg > 1) {
          final est = ((_scrollCtrl.offset - _kPadTop) / avg).floor();
          return est.clamp(0, _paras.length - 1).toInt();
        }
      }
    } catch (_) {}
    return 0;
  }

  void _followPara(int i) {
    if (_prefs.paginate) return; // 翻页模式不随读翻页（听书以音频为主）
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollCtrl.hasClients) return;
      double? off;
      try {
        final box = _paraKeys[i]?.currentContext?.findRenderObject();
        if (box is RenderBox && box.attached) {
          // RenderViewport 既是 RenderBox 又实现 AbstractViewport（兄弟接口，需显式转换）
          final vp = RenderAbstractViewport.maybeOf(box) as RenderBox?;
          if (vp != null && vp.attached) {
            final vpTop = vp.localToGlobal(Offset.zero).dy;
            final itemTop = box.localToGlobal(Offset.zero).dy;
            off = _scrollCtrl.offset + (itemTop - vpTop);
          }
        }
      } catch (_) {}
      if (off == null) {
        // 段落未渲染：平均段高估算
        final pos = _scrollCtrl.position;
        final avg =
            pos.maxScrollExtent / (_paras.isEmpty ? 1 : _paras.length);
        off = _kPadTop + i * (avg > 1 ? avg : 40);
      }
      off = off.clamp(0.0, _scrollCtrl.position.maxScrollExtent).toDouble();
      _scrollCtrl.animateTo(off,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    });
  }

  Widget _ttsBar(({Color bg, Color fg, Color dim}) c) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: c.bg.withValues(alpha: 0.95),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Row(
          children: [
            IconButton(
              icon: Icon(_ttsPaused ? Icons.play_arrow : Icons.pause,
                  color: c.fg, size: 22),
              onPressed: _togglePause,
            ),
            IconButton(
              icon: Icon(Icons.stop, color: c.fg, size: 22),
              onPressed: () => unawaited(_stopTts()),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                _ttsPaused
                    ? '已暂停'
                    : '正在朗读 · ${_ttsCur + 1}/${_paras.length} 段',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.dim, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------- 目录 / 书签 / 换源 ----------

  void _showToc() {
    final d = _detail;
    if (d == null) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => SizedBox(
        height: MediaQuery.of(ctx).size.height * 0.7,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('${d.book.title} · 共 ${d.chapters.length} 章',
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            Expanded(
              child: ListView.builder(
                itemCount: d.chapters.length,
                itemBuilder: (ctx2, i) => ListTile(
                  dense: true,
                  title: Text(
                    d.chapters[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: i == _chIdx
                          ? Theme.of(ctx2).colorScheme.primary
                          : null,
                      fontWeight: i == _chIdx ? FontWeight.bold : null,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(ctx).pop();
                    _jumpChapter(i);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showBookmarks() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx2, setSheetState) {
            final list = _store.bookmarksOf(_book.url);
            return SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    children: [
                      Text('书签', style: Theme.of(ctx).textTheme.titleMedium),
                      const Spacer(),
                      FilledButton.icon(
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('添加当前页'),
                        onPressed: () {
                          final snippet = _paras.isEmpty
                              ? ''
                              : _paras.first.substring(
                                  0, _paras.first.length.clamp(0, 30).toInt());
                          _store.addBookmark(
                            _book.url,
                            Bookmark(
                              chapterIndex: _chIdx,
                              page: _page,
                              paragraph: _prefs.paginate
                                  ? 0
                                  : _scrollCtrl.hasClients
                                      ? _scrollCtrl.offset.round()
                                      : 0,
                              chapterTitle: _chapterTitle,
                              snippet: snippet,
                            ),
                          );
                          setSheetState(() {});
                        },
                      ),
                    ],
                  ),
                ),
                if (list.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Text('暂无书签'),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: list.length,
                      itemBuilder: (ctx3, i) {
                        final b = list[i];
                        return ListTile(
                          dense: true,
                          title: Text(b.chapterTitle,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                              '${b.snippet}  ·  ${b.createdAt.month}/${b.createdAt.day}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis),
                          trailing: IconButton(
                            icon: const Icon(Icons.delete_outline),
                            onPressed: () {
                              _store.removeBookmark(_book.url, i);
                              setSheetState(() {});
                            },
                          ),
                          onTap: () {
                            Navigator.of(ctx).pop();
                            _jumpChapterTo(b);
                          },
                        );
                      },
                    ),
                  ),
              ],
            ),
            );
          },
        );
      },
    );
  }

  void _jumpChapterTo(Bookmark b) {
    if (_prefs.paginate) {
      _loadChapter(b.chapterIndex).then((_) {
        if (mounted) setState(() => _page = b.page);
      });
    } else {
      _loadChapter(b.chapterIndex, startOffset: b.paragraph);
    }
  }

  void _switchSource() {
    showSourceSwitch(
      context,
      _book,
      onSelected: (src, b) async {
        _snack('已切换到 ${src.name}');
        final oldTitle = _chapterTitle; // 先取旧章节标题（_detail 置空后取不到）
        setState(() {
          _src = src;
          _detail = null;
          _loading = true;
          _error = null;
        });
        BookDetail? nd;
        try {
          nd = await src.fetchDetail(b);
        } catch (_) {
          nd = await _store.cachedDetail(b);
        }
        if (!mounted) return;
        if (nd == null || nd.chapters.isEmpty) {
          setState(() {
            _loading = false;
            _error = Exception('新书源无章节');
          });
          return;
        }
        // 按章节标题匹配当前位置
        final target = _matchChapter(nd, oldTitle);
        setState(() => _detail = nd);
        await _loadChapter(target);
      },
    );
  }

  static String _norm(String s) =>
      s.replaceAll(RegExp(r'[^一-龥a-zA-Z0-9]'), '');

  int _matchChapter(BookDetail nd, String oldTitle) {
    final t = _norm(oldTitle);
    if (t.isEmpty) return 0;
    for (var i = 0; i < nd.chapters.length; i++) {
      if (_norm(nd.chapters[i].title) == t) return i;
    }
    // 完全匹配不到时按序号数字匹配
    final num = RegExp(r'^\d+').firstMatch(oldTitle)?.group(0);
    if (num != null) {
      final n = int.tryParse(num);
      if (n != null) {
        for (var i = 0; i < nd.chapters.length; i++) {
          final cn = RegExp(r'^\d+').firstMatch(nd.chapters[i].title)?.group(0);
          if (cn != null && int.tryParse(cn) == n) return i;
        }
      }
    }
    return 0;
  }
}
