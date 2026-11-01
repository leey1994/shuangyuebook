
import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../pet/pet_event.dart';
import '../pet/pet_store.dart';
import '../pet/pet_view.dart';
import '../data/font_store.dart';
import '../data/tts_session.dart';
import '../data/stats_store.dart';
import '../models.dart';
import '../paginate.dart';
import '../platform/native_bridge.dart';
import '../sources/registry.dart';
import '../sources/source.dart';
import '../store.dart';
import '../theme.dart';
import '../tts_voices.dart';
import '../ui/brand.dart';
import '../ui/font_picker.dart';
import '../ui/pet_top_band.dart';
import '../ui/reader/cover_turn.dart';
import '../ui/reader/page_snap_physics.dart';
import '../widgets.dart';
import 'book_search_sheet.dart';

/// 章末 / 章首越界拖动的累计量（纯函数，回归测试见
/// test/reader_edge_flip_test.dart）。
///
/// 方向约定：`scrollDelta` 是本页位移动量，**朝「下一页」为正**
/// （手指往左划）。PageSnapPhysics 不吃越界拖动，所以：
/// - 章末继续往下一章方向拖：`pixels > maxExtent`、`scrollDelta > 0`；
/// - 章首继续往上一章方向拖：`pixels < minExtent`、`scrollDelta < 0`；
/// - 页内正常滑动 / 回弹：计数清零（不然往回划也会攒出翻章）。
///
/// 旧实现把两侧符号写反，计数永远攒不起来 —— 「章末手势翻章」
/// 在滑动 / 覆盖模式下从来没生效过。
@visibleForTesting
double pagedEdgeAccum({
  required double acc,
  required double pixels,
  required double minExtent,
  required double maxExtent,
  required double? scrollDelta,
}) {
  final d = scrollDelta ?? 0;
  if (pixels > maxExtent + 0.5 && d > 0) return acc + d;
  if (pixels < minExtent - 0.5 && d < 0) return acc - d;
  return 0;
}

/// 阅读器：左右翻页 / 上下滚动双模式，
/// 目录、进度条、字号行距、主题、书签、离线、换源。
class ReaderScreen extends StatefulWidget {
  final Book book;
  final int chapterIndex;
  final int page; // 翻页模式页码
  final int paragraph; // 滚动模式 = 滚动偏移量

  /// 进入后自动开始听书（详情页「听书」按钮直达）。
  final bool ttsAutostart;

  const ReaderScreen({
    super.key,
    required this.book,
    this.chapterIndex = 0,
    this.page = 0,
    this.paragraph = 0,
    this.ttsAutostart = false,
  });

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen>
    with WidgetsBindingObserver {
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
  bool _tocOpen = false; // 宽屏右侧目录抽屉

  final _scrollCtrl = ScrollController();
  Timer? _scrollSave;

  /// 分页模式的页面控制器（滑动 / 覆盖 / 淡入共用）。
  final _pageCtrl = PageController();

  /// 章末/章首越界拖动的累计距离（像素）。
  double _edgeDrag = 0;

  /// 一次越界手势只翻一章的闩（松手时复位）。
  bool _edgeLock = false;

  /// 越界拖够这么多像素就换章。
  static const double _kEdgeDragToChapter = 120;

  /// 阅读计时：前台活跃时累计，单次 ≤90s 防挂机（写入 StatsStore）。
  Timer? _clock;

  /// 本次进入是否已记过「读完一本」，避免在末尾反复计入。
  bool _finished = false;
  int _sinceTick = 0;

  /// 页脚时钟与电量（每 30s 刷新一次即可，不必更密）。
  /// 页脚时间：单独一个 ValueNotifier。
  ///
  /// 每秒变一次，但只需要重画这一行文字 —— 原来走 setState 时整页正文
  /// 每秒重建一次（低端机上的「一直有点卡」就是这么来的）。
  final ValueNotifier<String> _clockText = ValueNotifier<String>('');

  /// 仅测试用：暴露页脚时间的活源（用来断言「时钟不再整页 setState」）。
  @visibleForTesting
  ValueListenable<String> get debugClockText => _clockText;
  BatteryStatus? _battery;

  /// 顶部的预留留白现在由全局那条窄带承担（安卓在状态栏下方、桌面在自绘标题栏
  /// 里），桌宠就住在那儿。所以阅读器自己不再额外留边距 ——
  /// 否则会把同一条状态栏高度算两遍。
  double get _reservedTop => 0;

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
  // 分批分页：长章节首屏只排一个时间预算，其余让出一帧后继续（P1-7）
  ParaPaginator? _pager;
  int _pagerGen = 0;

  // 偏好快照：排版签名（字号/行距/字距/缩进/字体/边距/翻页方式/背景）变化才重建
  late String _pLayout;

  // 听书（TTS）：引擎、进度、跨章推进全部在全局会话里（后台播放），
  // 阅读器只是它的一个视图 —— 退出阅读器朗读继续，回来再接上。
  /// 在线音色表（Edge TTS）：prefs 值 → (显示名, 合成音色 id)。音色面板只列这些。
  static const _edgeVoices = kEdgeVoices;
  static const _kVoiceDefault = kVoiceDefaultKey; // 默认在线音色
  TtsSession get _ttsSession => TtsSession.I;

  /// 本书正在朗读（会话还在读这本书；退出阅读器也不会中断）。
  bool get _speaking => _ttsSession.isReading(_book);
  bool get _ttsPaused => _ttsSession.paused;
  DateTime? get _ttsSince => _ttsSession.since;
  int get _sleepMin => _ttsSession.sleepMinutes;
  String get _sleepLeft => _ttsSession.sleepLeft;

  /// 正在朗读的段落（高亮/跟随）：只在「同一本书、同一章」时对得上号。
  int get _ttsCur => (_ttsSession.isReading(_book) &&
          _ttsSession.chapterIndex == _chIdx)
      ? _ttsSession.paraIndex
      : -1;

  bool _ttsAutostartDone = false; // 听书直达只自动开播一次
  bool _ttsPage = false; // 全屏听书页（效果图 08）
  int _followedPara = -1; // 上次跟随滚动的段落（会话每秒刷新，避免反复动画）
  final Map<int, GlobalKey> _paraKeys = {};

  /// 分页总页数变化信号（分批补排时只刷新页脚，不重建整页）。
  final ValueNotifier<int> _pageCountTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _src = sourceById(widget.book.sourceId) ?? allSources.first;
    _chIdx = widget.chapterIndex;
    _startPage = widget.page;
    _startOffset = widget.paragraph;
    final p = _prefs;
    _pLayout = _layoutSig;
    AppStore.I.addListener(_onPrefs);
    FontStore.I.addListener(_onFonts);
    // 上次选过网络字体：进阅读器就先在后台把字体下好（约 8~13MB，只下一次），
    // 下载完成前正文用系统字体，不会白屏等字。
    FontStore.I.warmUpSelected(p.fontFamily);
    PetStore.I.emit(PetAction.openBook);
    // 阅读时把桌宠钉在顶部窄带：正文要专注，它也不能挡住任何控件
    petPinned.value = true;
    _startClock();
    _initVolumeKeys();
    unawaited(NativeBridge.setKeepScreenOn(true)); // 阅读时不熄屏
    // 隐藏系统状态栏（时间 / 信号 / 电量），把那条空间让给阅读内容。
    // 退出阅读器时在 dispose 里恢复成 edgeToEdge。
    unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky));
    _scrollCtrl.addListener(() {
      if (_paged) return;
      final pos = _scrollCtrl.position;
      // 滚动到当前章末尾附近：自动加载下一章无缝续读。
      // 提前 1200px 就开始抓（约一屏半），滑到底时正文通常已经在手，
      // 不用盯着空白等网络。
      if (pos.pixels >= pos.maxScrollExtent - 1200) _loadMore();
      _scrollSave?.cancel();
      _scrollSave = Timer(const Duration(milliseconds: 600), () {
        if (!mounted || _paged) return;
        // 跨过章界后同步当前章节（标题/进度条跟随）
        final ci = _chapterFromScroll();
        if (ci != _chIdx) setState(() => _chIdx = ci);
        _saveProgress(silent: true);
      });
    });
    WidgetsBinding.instance.addObserver(this);
    TtsSession.I.addListener(_onTtsSession); // 朗读进度 → 高亮/跟随/面板
    _loadDetail();
    // 音色迁移：旧的系统/预设音色值 → 默认在线音色（面板只保留在线音色）
    Future.microtask(() {
      if (!_edgeVoices.containsKey(_prefs.ttsVoice)) {
        _store.setTtsVoice(_kVoiceDefault);
      }
    });
  }

  /// 每秒：累计阅读时长（写统计）+ 刷新页脚时钟；每 30s 刷一次电量。
  ///
  /// 单次累计封顶 [StatsStore.maxChunkSeconds] 防挂机刷时长。
  void _startClock() {
    _clockText.value = _fmtClock(DateTime.now());
    _clock?.cancel();
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      _sinceTick++;
      if (_sinceTick >= StatsStore.maxChunkSeconds) {
        _settleReading();
        _sinceTick = 0;
      }
      final now = DateTime.now();
      // 只更新时间这一个 Text —— 原来这里 setState 的是整个阅读器，
      // 等于每秒重建一次正文（低端机上就是每秒掉一帧）。
      _clockText.value = _fmtClock(now);
      if (_sinceTick % 30 == 0) {
        NativeBridge.batteryStatus().then((b) {
          if (mounted && b != null) setState(() => _battery = b);
        });
      }
    });
  }

  /// 把累计秒数落到统计库。
  void _settleReading() {
    if (_sinceTick <= 0) return;
    try {
      StatsStore.I.addReadingSeconds(_sinceTick);
      // 这段时长里若在听书，同步累计听书时长（听书达人徽章）
      if (_speaking && !_ttsPaused) StatsStore.I.addTtsSeconds(_sinceTick);
    } catch (_) {
      // 统计不可用不影响阅读
    }
    _sinceTick = 0;
  }

  static String _fmtClock(DateTime d) =>
      '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _applySystemUi();
  }

  /// 让状态栏配色跟随阅读背景。
  ///
  /// main.dart 按**全局**主题命令式设状态栏，而阅读器有 6 种独立背景 ——
  /// 不接管的话，选米黄或夜间背景时顶部会留一条颜色对不上的窄条，非常割裂。
  /// 同一个样式还挂在 build 的 [AnnotatedRegion] 上：上层 route 的
  /// AnnotatedRegion 会盖回命令式调用，阅读器永远拿到自己的配色。
  void _applySystemUi() {
    // 顶部桌宠窄带跟着阅读背景走，否则选米黄/夜间背景时顶部会留一条异色带
    petBandBackground.value = readerBgOf(_prefs.bgIndex, _prefs.theme).bg;
    SystemChrome.setSystemUIOverlayStyle(_systemUiStyle);
  }

  SystemUiOverlayStyle get _systemUiStyle {
    final bg = readerBgOf(_prefs.bgIndex, _prefs.theme);
    return SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      statusBarIconBrightness: bg.isDark ? Brightness.light : Brightness.dark,
      statusBarBrightness: bg.isDark ? Brightness.dark : Brightness.light,
      systemNavigationBarColor: bg.bg,
      systemNavigationBarIconBrightness:
          bg.isDark ? Brightness.light : Brightness.dark,
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 退到后台：停表并落盘这一段，离开阅读器不再计入时长
    if (state != AppLifecycleState.resumed) {
      _settleReading();
      // 章内翻页只写了轻量进度记录，这里把书架/历史整表补写一次；
      // 进程被系统杀掉也最多丢当前页的页码（下次启动由进度记录补回）。
      if (_detail != null) _store.flushProgress();
    } else if (mounted) {
      unawaited(NativeBridge.setKeepScreenOn(true));
    }
    // 关窗退出时引擎可能不走 widget dispose，这里兜底停掉听书
    if (state == AppLifecycleState.detached && _speaking) {
      unawaited(_ttsSession.stop());
    }
  }

  /// 全局会话变化 → 刷新高亮/面板；朗读推进时跟随滚动（仅同章）。
  void _onTtsSession() {
    if (!mounted) return;
    setState(() {});
    final s = _ttsSession;
    if (!s.isReading(_book) || s.chapterIndex != _chIdx || s.paused) {
      _followedPara = -1;
      return;
    }
    final i = s.paraIndex;
    if (i >= 0 && i != _followedPara) {
      _followedPara = i;
      _followPara(i);
    }
  }

  /// 字体表变了（下载完成 / 删了某款）：分页键含字体表版本，rebuild 即重排。
  void _onFonts() {
    if (!mounted) return;
    setState(() {});
  }

  void _onPrefs() {
    // 换阅读底色后状态栏必须立刻跟上：_applySystemUi 原本只在
    // didChangeDependencies 调一次，改底色不会触发它，顶部就留一条旧色。
    _applySystemUi();
    final sig = _layoutSig;
    if (sig != _pLayout) {
      final wasPaged = _paged;
      final prevMode = _prefs.pageMode;
      _pLayout = sig;
      if (mounted) setState(() {});
      // 滚动（已连载多章）→ 翻页：拆回当前单章再分页，避免跨章混排
      if (wasPaged && prevMode == PageMode.scroll && _chStarts.length > 1) {
        _loadChapter(_chIdx);
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    FontStore.I.removeListener(_onFonts);
    _clock?.cancel();
    _clockText.dispose();
    _settleReading(); // 离场前把这一段时长落盘
    // 离开阅读器：整表补写一次（章内翻页期间只写了轻量进度记录）
    if (_detail != null) _store.flushProgress();
    // 音量键控制权交还系统（原生按 active 直拦，必须主动关闭）
    _volGateSent = null;
    if (Platform.isAndroid) {
      try {
        unawaited(_readerKeys.invokeMethod('setActive', false));
      } catch (_) {}
    }
    _readerKeys.setMethodCallHandler(null);
    PetStore.I.emit(PetAction.exitBook);
    unawaited(NativeBridge.setKeepScreenOn(false)); // 交还系统熄屏控制
    // 顶部窄带底色还给全局主题
    petBandBackground.value = null;
    // 离开阅读器，桌宠恢复整屏溜达
    petPinned.value = false;
    // 恢复状态栏，并把配色还给全局主题
    unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
    // 后台播放：离开阅读器**不**停朗读 —— 会话还在全局跑，悬浮条可控制；
    // 只解除本页对会话的监听（回来再 attach）。
    TtsSession.I.removeListener(_onTtsSession);
    AppStore.I.removeListener(_onPrefs);
    AppStore.I.cancelPrefetch();
    _scrollSave?.cancel();
    _repagTimer?.cancel();
    _scrollCtrl.dispose();
    _pageCtrl.dispose();
    _pageCountTick.dispose();
    super.dispose();
  }

  AppStore get _store => AppStore.I;
  ReaderPrefs get _prefs => _store.prefs;

  Book get _book => _detail?.book ?? widget.book;
  String get _chapterTitle =>
      _chIdx >= 0 && _chIdx < (_detail?.chapters.length ?? 0)
          ? _detail!.chapters[_chIdx].title
          : '';

  /// 进入阅读器：**先读缓存立刻开卷，网络在后面悄悄补**。
  ///
  /// 原先同步 await 目录请求，网络差时要转圈十几秒才进去，进去还先弹一句
  /// 「网络不可用」—— 用户根本没来得及看内容就先吃了个坏心情。
  ///
  /// 现在：
  ///  1. 有缓存目录 → 立刻用缓存铺开并渲染，进度保留；
  ///  2. 后台再拉一次网络目录，成功则无缝替换（已读的那本不受影响）；
  ///  3. 缓存也没有时才转圈，并等网络结果；
  ///  4. 「无网络」只在**既没缓存、网络也失败**时才提示 —— 缓存看完之前不打扰。
  Future<void> _loadDetail() async {
    final cached = await _store.cachedDetail(_book);
    if (!mounted) return;

    if (cached != null && cached.chapters.isNotEmpty) {
      _detail = cached;
      _chIdx = _chIdx.clamp(0, cached.chapters.length - 1).toInt();
      setState(() {
        _loading = false;
        _error = null;
      });
      await _loadChapter(_chIdx,
          startPage: widget.page, startOffset: widget.paragraph);
      if (!mounted) return;
      // 缓存能看就不打断；有网再后台更新目录
      unawaited(_refreshDetailInBackground());
      return;
    }

    // 无缓存：只能等网络，但转圈时不再「先卡住再报错」
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      _detail = await _src.fetchDetail(_book);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e;
      });
      return;
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
    await _loadChapter(_chIdx,
        startPage: widget.page, startOffset: widget.paragraph);
  }

  /// 后台刷新目录：拿到新目录就换掉，并尽量保住当前阅读位置。
  ///
  /// 失败一律静默 —— 缓存能看的时候没理由用错误打断阅读。
  Future<void> _refreshDetailInBackground() async {
    // 刚开卷时正文请求和后台预取正在跑，目录刷新先让 600 ms：三个请求一起
    // 挤同一个站点的限速，「下一章」就要排队等。
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    try {
      final fresh = await _src.fetchDetail(_book);
      if (!mounted || fresh.chapters.isEmpty) return;
      final keepTitle = _chapterTitle;
      setState(() => _detail = fresh);
      // 章节被整体替换后，按标题把阅读位置挪到对应的那一章
      final idx = keepTitle.isEmpty ? _chIdx : _matchChapter(fresh, keepTitle);
      if (idx != _chIdx) {
        _chIdx = idx;
        await _loadChapter(idx);
      }
    } catch (_) {
      // 无网也无所谓：缓存还在手上
    }
  }

  Future<void> _loadChapter(
    int idx, {
    bool toEnd = false,
    int startPage = 0,
    int startOffset = 0,
  }) async {
    if (_detail == null || idx < 0 || idx >= _detail!.chapters.length) return;
    final g = _gen + 1; // 本次加载的代数：await 返回时若已被新加载取代则丢弃
    setState(() {
      _gen++; // 作废进行中的连载加载
      _chIdx = idx;
      _chStarts = [(idx, _kPadTop)];
      _lastMoreFail = DateTime.fromMillisecondsSinceEpoch(0);
      _loading = true;
      _error = null;
      _pages = null;
      _pagesKey = null;
      _pager = null;
      // 段落下标是「按章」的：不清掉就会越攒越多，且旧 key 永远挂不上新段
      _paraKeys.clear();
      _pagerGen++; // 作废进行中的分批分页
      _startPage = toEnd ? 1 << 30 : startPage;
      _startOffset = startOffset;
      _page = 0;
      _followedPara = -1; // 切章后高亮/跟随重新对齐
    });
    try {
      final paras =
          await _store.chapterText(_src, _detail!, _detail!.chapters[idx]);
      if (!mounted || g != _gen) return; // 已切去别的章：迟到结果丢弃，
      // 否则会把旧章正文盖到新章上（快速连跳目录/滑杆时的竞态）
      setState(() {
        _paras = paras;
        _loading = false;
        _page = 0;
      });
      _saveProgress();
      // 「听书直达」：首章文本就绪后自动开播（只触发一次，换章不重开）
      if (widget.ttsAutostart && !_ttsAutostartDone) {
        _ttsAutostartDone = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && g == _gen && !_speaking) unawaited(_toggleTts());
        });
      }
      // 自动预取后续章节（后台低优先级，切换章节/退出时被取消）
      if (_prefs.autoCache > 0 && mounted && _detail != null) {
        final src = _src;
        final d = _detail!;
        _store.prefetchNext(src, d, idx + 1, _prefs.autoCache);
      }
      if (_startOffset > 0) {
        // 滚动模式恢复位置
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (g != _gen || !_scrollCtrl.hasClients) return;
          _scrollCtrl.jumpTo(_startOffset
              .toDouble()
              .clamp(0, _scrollCtrl.position.maxScrollExtent)
              .toDouble());
        });
      }
      // 滚动模式：本章不足一屏（短章）时自动续载下一章
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && g == _gen && !_prefs.paginate && _scrollCtrl.hasClients) {
          if (_scrollCtrl.position.maxScrollExtent < 300) _loadMore();
        }
      });
    } catch (e) {
      if (!mounted || g != _gen) return; // 过期加载的报错不打扰新章节
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
      ..showSnackBar(
          SnackBar(content: Text(msg), duration: const Duration(seconds: 2)));
  }

  // ---------- 翻页 / 换章 ----------

  List<List<String>> get _currentPages => _pages ?? const [[]];

  /// 翻到指定页：同步 [_page] 与 PageView 控制器（两者互为对方的真值来源）。
  void _setPage(int i, {bool animate = true}) {
    final target = i.clamp(0, _currentPages.length - 1);
    if (target == _page) return;
    setState(() => _page = target);
    _saveProgress();
    if (_prefs.pageMode == PageMode.slide ||
        _prefs.pageMode == PageMode.cover) {
      if (_pageCtrl.hasClients) {
        if (animate) {
          _pageCtrl.animateToPage(target,
              duration: const Duration(milliseconds: 260),
              curve: Curves.easeOutCubic);
        } else {
          _pageCtrl.jumpToPage(target);
        }
      }
    }
  }

  void _goNext() {
    if (_loading || _detail == null) return;
    if (_page < _currentPages.length - 1) {
      _setPage(_page + 1);
      return;
    }
    if (_chIdx < _detail!.chapters.length - 1) {
      _loadChapter(_chIdx + 1);
      PetStore.I.emit(PetAction.nextChapter);
    } else {
      _markFinished();
      _snack('已经是最后一章了');
      setState(() {});
    }
  }

  /// 读到最后一章的末尾：记一次「读完一本」。每本书每次进入只记一次 ——
  /// 末尾可以反复点，不该反复计数。
  void _markFinished() {
    if (_finished || _detail == null) return;
    _finished = true;
    StatsStore.I.addFinishedBook();
    PetStore.I.emit(PetAction.finishBook);
  }

  void _goPrev() {
    if (_loading || _detail == null) return;
    if (_page > 0) {
      _setPage(_page - 1);
      return;
    }
    if (_chIdx > 0) {
      _loadChapter(_chIdx - 1, toEnd: true);
      PetStore.I.emit(PetAction.prevChapter);
    } else {
      _snack('已经是第一章了');
    }
  }

  /// 音量键翻门控状态缓存：native 通道只在变化时才发，避免每次 setState 都跨桥。
  bool? _volGateSent;

  /// 音量键翻页是否生效：分页模式、不在听书、不在全屏听书页。
  /// （滚动模式点按即换章，音量键翻「页」没有合理语义，留给系统调音量。）
  bool get _volumePageOn => _paged && !_speaking && !_ttsPage;

  static const MethodChannel _readerKeys =
      MethodChannel('dev.reader.novel_reader/reader_keys');

  /// 向原生声明「阅读器在前台 / 音量键当前归我管」。
  ///
  /// Android 上部分 ROM 不经 Flutter 键通道派发音量键（社区长期问题），
  /// 原生 [MainActivity.dispatchKeyEvent] 按 [readerActive] 直接拦 — 这是
  /// 真机可用路径；Flutter 的 Focus 处理器继续留着：Windows 等桌面端走它。
  void _syncVolumeGate() {
    if (!Platform.isAndroid) return;
    final active = _volumePageOn;
    if (_volGateSent == active) return;
    _volGateSent = active;
    try {
      _readerKeys.invokeMethod('setActive', active);
    } catch (_) {
      // 桥未就绪 / 桌面端没有该通道：忽略，Focus 处理器兜底
    }
  }

  void _initVolumeKeys() {
    if (!Platform.isAndroid) return;
    _readerKeys.setMethodCallHandler((call) async {
      if (call.method == 'turn') {
        // KeyEvent.KEYCODE_VOLUME_UP = 24, KEYCODE_VOLUME_DOWN = 25
        if (call.arguments == 24) {
          _goPrev();
        } else if (call.arguments == 25) {
          _goNext();
        }
      }
      return null;
    });
  }

  /// 音量键翻页：音量下 = 下一页，音量上 = 上一页（桌面端 / Focus 链路）。
  ///
  /// 返回 [KeyEventResult.handled] 才能真正吞掉按键（否则系统音量条会跟着
  /// 弹）；up / repeat 事件也吞 —— 长按不连翻、听书外的场景不漏音量变化。
  KeyEventResult _onVolumeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyUpEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final k = event.logicalKey;
    final isVol = k == LogicalKeyboardKey.audioVolumeUp ||
        k == LogicalKeyboardKey.audioVolumeDown;
    if (!isVol) return KeyEventResult.ignored;
    if (!_volumePageOn) return KeyEventResult.ignored;
    if (event is KeyDownEvent) {
      k == LogicalKeyboardKey.audioVolumeDown ? _goNext() : _goPrev();
    }
    return KeyEventResult.handled;
  }

  void _jumpChapter(int idx) {
    if (_detail == null) return;
    if (idx < 0 || idx >= _detail!.chapters.length) return;
    setState(() => _menu = false);
    _loadChapter(idx);
  }

  void _showSearch() {
    final d = _detail;
    if (d == null) return;
    showBookSearch(context, d, _jumpToHit);
  }

  /// 书内搜索跳转：载入目标章后定位到段落。
  /// 翻页模式按「页首段落探针」反查页码；滚动模式复用听书的段落跟随。
  void _jumpToHit(int chIdx, int paraIdx) {
    if (_detail == null) return;
    if (chIdx < 0 || chIdx >= _detail!.chapters.length) return;
    setState(() => _menu = false);
    _loadChapter(chIdx).then((_) {
      if (!mounted || _chIdx != chIdx) return;
      if (_prefs.paginate) {
        // 等这一帧把页排出来，再按段落探针找页
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || paraIdx >= _paras.length) return;
          final para = _paras[paraIdx];
          // 长段可能被切成多页：用前 8 字探针找它的第一页
          final probe = para.substring(0, para.length < 8 ? para.length : 8);
          var pi = _currentPages
              .indexWhere((page) => page.any((t) => t.contains(probe)));
          if (pi < 0 && probe.length > 4) {
            // 探针恰好被分页切开时退半步，用更短的头部再试
            pi = _currentPages.indexWhere(
                (page) => page.any((t) => t.contains(probe.substring(0, 4))));
          }
          if (pi >= 0) _setPage(pi, animate: false);
        });
      } else {
        _followPara(paraIdx);
      }
    });
  }

  // ---------- 主题配色（与全局主题同步） ----------

  /// 当前阅读配色。六种背景任选，越界时按全局主题回退。
  ({Color bg, Color fg, Color dim}) _colors() {
    final b = readerBgOf(_prefs.bgIndex, _prefs.theme);
    return (bg: b.bg, fg: b.fg, dim: b.dim);
  }

  /// 正文是否处于夜间背景（决定高亮色等派生色）。
  bool get _isNightBg => readerBgIsDark(_prefs.bgIndex, _prefs.theme);

  TextStyle get _bodyStyle {
    // 网络字体：只有「已下载并注册」时才把家族名塞进 TextStyle —— 否则
    // Flutter 会按缺字回退，先按默认字体排一遍、字体到了再重排，肉眼就是闪一下。
    final f = FontStore.I.activeFont(_prefs.fontFamily);
    return TextStyle(
      fontSize: _prefs.fontSize,
      height: _prefs.lineHeight,
      letterSpacing: _prefs.letterSpacing,
      color: _colors().fg,
      fontFamily: f?.family,
      fontFamilyFallback: f?.fallback,
    );
  }

  /// 排版签名 + 字体表版本：字体下载完成后也要重排一次（同段落行高会变）。
  String get _layoutSig =>
      '${_prefs.layoutSignature}|${FontStore.I.generation}';

  /// 页眉 / 页脚各占的高度（关闭时为 0，正文区相应变大）。
  double get _headerH => _prefs.showHeader ? 26 : 0;
  double get _footerH => _prefs.showFooter ? 24 : 0;

  bool get _paged => _prefs.pageMode != PageMode.scroll;

  // ---------- 构建 ----------

  @override
  Widget build(BuildContext context) {
    final c = _colors();
    // 音量键门控同步：_speaking / _ttsPage / pageMode 任何一变，build 都会路过
    _syncVolumeGate();
    // 顶部那条预留带（桌宠住的地方）由全局提供，这里不再重复留边距。
    final mq = MediaQuery.of(context);
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: _systemUiStyle,
      child: Focus(
        autofocus: true,
        onKeyEvent: _onVolumeKey,
        child: Scaffold(
      backgroundColor: c.bg,
      body: Stack(
        children: [
          MediaQuery(
            data: mq.copyWith(
              padding: mq.padding.copyWith(top: _reservedTop),
              viewPadding: mq.viewPadding.copyWith(top: _reservedTop),
            ),
            child: SafeArea(
              child: LayoutBuilder(
                builder: (context, box) {
                  // 正文可用区：扣掉左右页边距、上下留白，以及页眉 / 页脚占位
                  final w = box.maxWidth - _prefs.marginH * 2;
                  final h =
                      box.maxHeight - _prefs.marginV * 2 - _headerH - _footerH;
                  _lastW = w;
                  _lastH = h;
                  final ts = MediaQuery.textScalerOf(context);
                  _lastScaler = ts;
                  if (w > 0 && h > 0) {
                    final key = Object.hash(identityHashCode(_paras), w, h,
                        _layoutSig, ts.toString());
                    if (_pages == null) {
                      // 新章节首排：只排一个时间预算（首屏立即有字），
                      // 余下部分让出一帧后分批补排，避免长章节卡住这一帧
                      final pager = ParaPaginator(
                        paras: _paras,
                        width: w,
                        height: h,
                        style: _bodyStyle,
                        paraSpacing: _prefs.fontSize * 0.6,
                        textScaler: ts,
                        indent: _prefs.indentFirstLine ? '　　' : '',
                        // 插图段落按固定块高测量，否则图片会被当成一行字
                        heightOf: (p) => imagePathOf(p) == null
                            ? null
                            : imageBlockHeight(h),
                      );
                      _pagerGen++;
                      final gen = _pagerGen;
                      _pager = pager;
                      pager.pump(const Duration(milliseconds: 8));
                      _pages = pager.pages;
                      _pagesKey = key;
                      if (_startPage != 0) {
                        _page = _startPage >= _pages!.length
                            ? _pages!.length - 1
                            : _startPage;
                        _startPage = 0;
                      }
                      if (!pager.done) unawaited(_pumpRest(gen, pager));
                    } else if (_pagesKey != key) {
                      // 窗口拖拽/字号变化：防抖重排，期间沿用旧分页（防止每帧全量重排卡死）
                      _repagTimer?.cancel();
                      _repagTimer =
                          Timer(const Duration(milliseconds: 160), _repaginate);
                    }
                  }
                  if (_pages != null && _pages!.isNotEmpty) {
                    _page = _page.clamp(0, _pages!.length - 1).toInt();
                  }

                  final wide = box.maxWidth > kNarrowBreakpoint;
                  return Stack(
                    children: [
                      Padding(
                        padding:
                            EdgeInsets.only(top: _headerH, bottom: _footerH),
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTapUp: (d) {
                            if (_prefs.pageMode == PageMode.scroll) {
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
                      ),
                      if (_prefs.showHeader)
                        Positioned(
                            top: 0, left: 0, right: 0, child: _buildHeader(c)),
                      if (_prefs.showFooter)
                        Positioned(
                            bottom: 0,
                            left: 0,
                            right: 0,
                            child: _buildFooter(c)),
                      if (_loading) _overlay(const CircularProgressIndicator()),
                      if (_error != null) _overlay(_errorView()),
                      // 加载/出错期间没有菜单入口，提供返回控件防止“出不去”
                      if ((_loading || _error != null) &&
                          Navigator.of(context).canPop())
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
                      if (wide && _tocOpen) _tocDrawerOverlay(c),
                      if (_speaking && !_menu) _ttsBar(c),
                      if (_ttsPage) _ttsPageOverlay(c),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    ),
      ),
    );
  }

  /// 防抖重排（窗口尺寸变化 / 字号行距变化后调用）。
  /// 同样只排首屏预算，剩余部分交给 [_pumpRest] 分批补排。
  void _repaginate() {
    if (!mounted || _lastW <= 0 || _lastH <= 0) return;
    final pager = ParaPaginator(
      paras: _paras,
      width: _lastW,
      height: _lastH,
      style: _bodyStyle,
      paraSpacing: _prefs.fontSize * 0.6,
      textScaler: _lastScaler,
      indent: _prefs.indentFirstLine ? '　　' : '',
      heightOf: (p) => imagePathOf(p) == null
          ? null
          : imageBlockHeight(_lastH),
    );
    _pagerGen++;
    final gen = _pagerGen;
    _pager = pager;
    pager.pump(const Duration(milliseconds: 8));
    if (!mounted) return;
    setState(() {
      _pages = pager.pages;
      _pagesKey = Object.hash(identityHashCode(_paras), _lastW, _lastH,
          _layoutSig, _lastScaler.toString());
      _page = _page.clamp(0, pager.pages.length - 1).toInt();
    });
    _pageCountTick.value++;
    if (!pager.done) unawaited(_pumpRest(gen, pager));
  }

  /// 把剩余段落分批排完：每次让出一帧，排一个小预算后刷新页码。
  /// 章节切换 / 重排会自增 [_pagerGen]，过期任务在此退出（P1-7）。
  Future<void> _pumpRest(int gen, ParaPaginator pager) async {
    await Future<void>.delayed(Duration.zero); // 先让首屏那一帧渲染出来
    while (mounted && gen == _pagerGen && identical(_pager, pager) && !pager.done) {
      pager.pump(const Duration(milliseconds: 6));
      if (!mounted || gen != _pagerGen || !identical(_pager, pager)) return;
      _pageCountTick.value++; // 页脚「第 x/y 页」跟着涨
      final np = _page.clamp(0, pager.pages.length - 1).toInt();
      // 页码没变就不 setState：否则整个章节页在补排期间被反复重建。
      if (np != _page) setState(() => _page = np);
      await Future<void>.delayed(Duration.zero);
    }
  }

  Widget _overlay(Widget child) => Container(
        color: _bg().withValues(alpha: 0.7),
        alignment: Alignment.center,
        child: child,
      );

  Color _bg() => _colors().bg;

  /// 把底层异常翻译成人话。
  ///
  /// 缓存看完之后再往后翻才会走到这里，此时用户真正需要知道的是
  /// 「没网了」而不是一串 SocketException / Failed host。
  String _errorText(Object e) {
    final s = e.toString();
    if (s.contains('SocketException') ||
        s.contains('Failed host') ||
        s.contains('Network is unreachable') ||
        s.contains('Connection refused') ||
        s.contains('请求超时') ||
        s.contains('网络错误') ||
        s.contains('Connection timed out')) {
      return '网络不可用，这一章还没缓存。\n连上网后点「重试」即可继续。';
    }
    return '加载失败：$s';
  }

  Widget _errorView() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_errorText(_error!),
                textAlign: TextAlign.center,
                style: TextStyle(color: _colors().dim)),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              OutlinedButton(
                onPressed: () => _loadChapter(_chIdx),
                child: const Text('重试'),
              ),
              const SizedBox(width: 10),
              // 这个源这章读不出来时，直接换源续读（按章节名对齐进度）
              OutlinedButton(
                onPressed: _switchSource,
                child: const Text('换源'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 正文区域：按翻页方式分派。
  Widget _buildContent() => switch (_prefs.pageMode) {
        PageMode.scroll => _buildScrollBody(),
        PageMode.fade => _buildFadeBody(),
        PageMode.slide || PageMode.cover => _buildPagedBody(),
      };

  /// 首行缩进两字（中文排版惯例）。
  ///
  /// 用两个全角空格做「视觉缩进」，而不是 TextStyle.indent —— 后者会连同换行
  /// 一起缩进，在分页测量里会与 cutToFit 的二分边界打架。
  String _indent(String s) => _prefs.indentFirstLine ? '　　$s' : s;

  // ---- EPUB 插图 ----
  //
  // 解析 EPUB 时 `local_source` 把插图落盘，并把正文里的占位标记改写成
  // `\u0001IMG:<本地路径>\u0001`（见 EpubParser.imageMarkerPrefix）。
  // 这里把它渲染成图片块：高度固定为页高的一半左右，分页测量用同一个值，
  // 网页图片原尺寸未知也不会让版面溢出。
  static const String _imgPrefix = '\u0001IMG:';
  static const String _imgEnd = '\u0001';

  /// 插图段落 → 本地文件路径；普通正文段落返回 null。
  static String? imagePathOf(String para) {
    if (!para.startsWith(_imgPrefix)) return null;
    final end = para.indexOf(_imgEnd, _imgPrefix.length);
    if (end < 0) return null;
    final path = para.substring(_imgPrefix.length, end);
    return path.isEmpty ? null : path;
  }

  /// 插图块高度（分页测量与渲染必须一致）。
  static double imageBlockHeight(double pageHeight) =>
      pageHeight > 0 ? pageHeight * 0.55 : 200;

  /// 一段正文的渲染：插图渲染成图片块，其余按正文排版。
  Widget _paraText(String para, double blockH, {bool highlight = false}) {
    final img = imagePathOf(para);
    if (img != null) {
      final f = File(img);
      return SizedBox(
        height: blockH,
        width: double.infinity,
        child: f.existsSync()
            ? Image.file(
                f,
                fit: BoxFit.contain,
                filterQuality: FilterQuality.medium,
                gaplessPlayback: true,
              )
            : Center(
                child: Text('［插图］',
                    style: TextStyle(color: _colors().dim, fontSize: 13)),
              ),
      );
    }
    final t = _indent(para);
    return highlight
        ? ColoredBox(
            color: _isNightBg
                ? const Color(0x333DDC97)
                : const Color(0x222F6B3C),
            child: Text(t, style: _bodyStyle),
          )
        : Text(t, style: _bodyStyle);
  }

  /// 一页正文的排版（所有分页模式共用，保证测量与渲染一致）。
  Widget _pageBody(List<String> page) {
    final blockH = imageBlockHeight(_lastH);
    return Padding(
      padding: EdgeInsets.symmetric(
          horizontal: _prefs.marginH, vertical: _prefs.marginV),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < page.length; i++) ...[
            _paraText(page[i], blockH),
            if (i < page.length - 1) SizedBox(height: _prefs.fontSize * 0.6),
          ],
        ],
      ),
    );
  }

  /// 滑动 / 覆盖翻页：PageView + 爽阅的页对齐物理。
  ///
  /// 覆盖模式额外给每页套 [CoverTurnItem]（钉住当前页、显式裁剪已揭示部分、
  /// 前缘投影），与「阅读 3.0」的 CoverPageDelegate 行为一致。
  Widget _buildPagedBody() {
    final pages = _currentPages;
    if (pages.isEmpty) {
      // 尺寸无效（如最小化）时绝不渲染全部段落，等重排完成
      return Center(child: CircularProgressIndicator(color: _colors().fg));
    }
    final cover = _prefs.pageMode == PageMode.cover;
    // 控制器页码与 _page 对齐（模式切换 / 章节切换后重建）。
    //
    // 只在**控制器静止时**才对齐。翻页动画（animateToPage / 用户拖拽）期间
    // 控制器正在动，这时 jumpToPage 会把动画打断 —— 表现就是「下一页只显示
    // 一半，过很久才整体显示出来」。静止判定必须放在最前面：动画刚启动的那
    // 一帧 page 还是旧值，光比页码根本区分不出来（那个旧值恰好差整一页）。
    if (_pageCtrl.hasClients && _pageCtrl.page != null) {
      final pos = _pageCtrl.position;
      if (!pos.isScrollingNotifier.value &&
          (_pageCtrl.page! - _page).abs() >= 0.5) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_pageCtrl.hasClients) _pageCtrl.jumpToPage(_page);
        });
      }
    }
    return NotificationListener<ScrollNotification>(
      onNotification: _onPagedScroll,
      child: PageView.builder(
        controller: _pageCtrl,
        physics: const PageSnapPhysics(),
        itemCount: pages.length,
        onPageChanged: (i) {
          if (!mounted || i == _page) return;
          setState(() => _page = i);
          _saveProgress();
        },
        itemBuilder: (ctx, i) {
          final child = _pageBody(pages[i]);
          if (!cover) return child;
          // delta 必须每帧取控制器实时值：itemBuilder 只在条目首次上屏时
          // 构建一次，把 page 快照写死会给「钉住页」冻结住 —— 拖到半屏
          // 裁剪不跟手、松手才弹回（覆盖模式卡顿感的来源之一）。
          return AnimatedBuilder(
            animation: _pageCtrl,
            builder: (_, __) {
              final cur = _pageCtrl.hasClients && _pageCtrl.page != null
                  ? _pageCtrl.page!
                  : _page.toDouble();
              return CoverTurnItem(
                delta: i - cur,
                width: MediaQuery.sizeOf(ctx).width,
                shadowWidth: 14,
                child: child,
              );
            },
          );
        },
      ),
    );
  }

  /// 章末 / 章首继续拖动 → 换章。
  ///
  /// 分页模式原先只有「点右侧翻页」这一条路能进下一章，手势一直滑到底
  /// 什么也不发生。这里把越界拖动累计起来：到了末页还往后拖，攒够
  /// [_kEdgeDragToChapter]（约 0.3 屏宽）就翻下一章；章首往前拖同理回上一章。
  ///
  /// 只在越界方向上计数 —— 页内正常滑动会把计数清零，所以不会误翻。
  ///
  /// 方向约定（ScrollUpdateNotification.scrollDelta = 本帧位移动量）：
  /// PageSnapPhysics 不吃越界拖动，章末继续往后拖时 pixels 会**越过**
  /// maxScrollExtent（scrollDelta 为正），章首同理为负 —— 旧代码把两侧
  /// 符号写反了（`d < 0` / `d > 0`），导致越界计数永远立刻被清零，
  /// 「章末手势翻章」在滑动 / 覆盖模式下从未生效过。
  bool _onPagedScroll(ScrollNotification n) {
    // 一次越界只许翻一章：翻章会重建分页，指针若还拖在身上，越界量会
    // 继续累计并再翻一章（表现为「一划跳过两章」）。松手前锁住。
    if (_edgeLock) {
      if (n is ScrollEndNotification) _edgeLock = false;
      return false;
    }
    if (n is ScrollUpdateNotification) {
      if (n.dragDetails == null) {
        _edgeDrag = 0;
      } else {
        final m = n.metrics;
        _edgeDrag = pagedEdgeAccum(
          acc: _edgeDrag,
          pixels: m.pixels,
          minExtent: m.minScrollExtent,
          maxExtent: m.maxScrollExtent,
          scrollDelta: n.scrollDelta,
        );
      }
      if (_edgeDrag >= _kEdgeDragToChapter) {
        _edgeDrag = 0;
        if (_flipBeyondEdge()) _edgeLock = true;
        return true;
      }
    } else if (n is ScrollEndNotification) {
      // 松手翻章：章末/章首拖出了越界但没到拖动阈值 —— 松手即翻
      // （阅读 3.0 同口径：章末轻划松手直接进下一章），否则回弹归位。
      final drag = _edgeDrag;
      _edgeDrag = 0;
      if (drag >= _kEdgeDragToChapter ~/ 3 && _flipBeyondEdge()) {
        _edgeLock = true;
        return true;
      }
    }
    return false;
  }

  /// 越界方向翻章：当前页在章末 → 下一章，在章首 → 上一章。
  bool _flipBeyondEdge() {
    if (_page >= _currentPages.length - 1) {
      _goNext();
      return true;
    }
    if (_page <= 0) {
      _goPrev();
      return true;
    }
    return false;
  }

  /// 淡入淡出翻页：不跟手，整页交叉淡变（夜里翻页不刺眼）。
  ///
  /// 因为没有 PageView，滑动换章要自己识别：横向拖过 [_kFadeSwipePx]
  /// 且抬手时判定为一次翻页手势，才推进/后退。章末继续滑会跨到下一章。
  Widget _buildFadeBody() {
    final pages = _currentPages;
    if (pages.isEmpty) {
      return Center(child: CircularProgressIndicator(color: _colors().fg));
    }
    final idx = _page.clamp(0, pages.length - 1).toInt();
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        // DragEndDetails 没有累计位移，只有结束速度；用速度阈值判定方向。
        // 慢速轻扫不触发，避免误翻。
        if (v < -_kFadeSwipePx) {
          _goNext();
        } else if (v > _kFadeSwipePx) {
          _goPrev();
        }
      },
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 220),
        switchInCurve: Curves.easeOut,
        switchOutCurve: Curves.easeIn,
        child: KeyedSubtree(
          key: ValueKey(idx),
          child: _pageBody(pages[idx]),
        ),
      ),
    );
  }

  /// 淡入模式下判定为一次翻页手势所需的最小结束速度（px/s）。
  static const double _kFadeSwipePx = 350;

  /// 上下滚动模式：跨章连载，靠底部临近自动续下一章。
  Widget _buildScrollBody() {
    final atEnd = _atBookEnd;
    return ListView.builder(
      controller: _scrollCtrl,
      padding: EdgeInsets.fromLTRB(
          _prefs.marginH, _prefs.marginV, _prefs.marginH, _prefs.marginV + 12),
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
        final highlight = _speaking && _ttsCur == i;
        return Padding(
          key: _paraKeys.putIfAbsent(i, () => GlobalKey()),
          padding: EdgeInsets.only(bottom: _prefs.fontSize * 0.6),
          child: _paraText(_paras[i], imageBlockHeight(_lastH),
              highlight: highlight),
        );
      },
    );
  }

  /// 页眉：章节名（可关）。沉浸在状态栏高度之下。
  Widget _buildHeader(({Color bg, Color fg, Color dim}) c) => SizedBox(
        height: _headerH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              _chapterTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: c.dim, fontSize: 11.5),
            ),
          ),
        ),
      );

  /// 页脚：时间 / 页码进度 / 电量（各自可关）。
  Widget _buildFooter(({Color bg, Color fg, Color dim}) c) => SizedBox(
        height: _footerH,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              ValueListenableBuilder<String>(
                valueListenable: _clockText,
                builder: (_, text, __) => Text(text,
                    style: TextStyle(color: c.dim, fontSize: 11.5)),
              ),
              const Spacer(),
              if (_detail != null)
                ValueListenableBuilder<int>(
                  valueListenable: _pageCountTick,
                  builder: (_, __, ___) => Text(
                    _paged && _currentPages.isNotEmpty
                        ? '第 ${_page + 1}/${_currentPages.length} 页'
                        : '第 ${_chIdx + 1}/${_detail!.chapters.length} 章',
                    style: TextStyle(color: c.dim, fontSize: 11.5),
                  ),
                ),
              const SizedBox(width: 10),
              if (_battery != null) ...[
                Icon(
                  _battery!.charging
                      ? Icons.battery_charging_full
                      : Icons.battery_std,
                  size: 13,
                  color: c.dim,
                ),
                const SizedBox(width: 2),
                Text('${_battery!.level}%',
                    style: TextStyle(color: c.dim, fontSize: 11.5)),
              ],
            ],
          ),
        ),
      );

  // ---------- 覆盖层 ----------

  Widget _topBar(({Color bg, Color fg, Color dim}) c) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        color: c.bg.withValues(alpha: 0.94),
        padding: const EdgeInsets.fromLTRB(2, 2, 6, 2),
        child: Row(
          children: [
            if (Navigator.of(context).canPop())
              IconButton(
                icon: const Icon(Icons.arrow_back, size: 20),
                color: c.fg,
                tooltip: '返回',
                onPressed: () {
                  _saveProgress();
                  Navigator.of(context).pop();
                },
              ),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '${_book.title} · 第 ${_chIdx + 1} 章',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: c.dim, fontSize: 11.5),
              ),
            ),
            IconButton(
              tooltip: '缓存全书',
              icon: const Icon(Icons.download_outlined, size: 18),
              color: c.fg,
              onPressed: _quickCache,
            ),
            IconButton(
              tooltip: '更多',
              icon: const Icon(Icons.more_horiz, size: 20),
              color: c.fg,
              onPressed: () => _moreSheet(c),
            ),
          ],
        ),
      ),
    );
  }

  /// 悬浮深色工具条（效果图 06/12）：进度条 + 目录/换源/听书/设置。
  Widget _bottomPanel(({Color bg, Color fg, Color dim}) c) {
    final total = _detail?.chapters.length ?? 0;
    final frac = total <= 1 ? 0.0 : _chIdx / (total - 1);
    final wide = MediaQuery.sizeOf(context).width > kNarrowBreakpoint;
    const barBg = Color(0xE6172018); // rgba(20,28,20,.88) 的实色近似
    const barDim = Color(0xFFB9C6B4);
    const barOn = Color(0xFF8FD9AE);
    final darkBg = readerBgIsDark(_prefs.bgIndex, _prefs.theme);
    final bar = Container(
      decoration: BoxDecoration(
        color: barBg,
        borderRadius: BorderRadius.circular(wide ? 18 : 20),
        boxShadow: [
          BoxShadow(
              color: Colors.black.withValues(alpha: 0.28),
              blurRadius: 26,
              offset: const Offset(0, 10)),
        ],
      ),
      padding: EdgeInsets.fromLTRB(wide ? 22 : 8, 7, wide ? 22 : 8, wide ? 7 : 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 22,
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                activeTrackColor: barOn,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
                thumbColor: barOn,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 4),
                overlayShape: SliderComponentShape.noOverlay,
              ),
              child: Slider(
                value: frac.clamp(0.0, 1.0).toDouble(),
                onChanged: total <= 1
                    ? null
                    : (v) => _jumpChapter((v * (total - 1)).round()),
              ),
            ),
          ),
          SizedBox(height: wide ? 2 : 4),
          if (wide)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _barBtn(
                    icon: Icons.list,
                    label: '目录',
                    color: _tocOpen ? barOn : barDim,
                    wide: true,
                    onTap: () => setState(() => _tocOpen = !_tocOpen)),
                _barBtn(
                    icon: Icons.swap_horiz,
                    label: '换源',
                    color: barDim,
                    wide: true,
                    onTap: _switchSource),
                _barBtn(
                    icon: _speaking ? Icons.graphic_eq : Icons.headset,
                    label: _speaking ? '听书中' : '听书',
                    color: _speaking ? barOn : barDim,
                    wide: true,
                    onTap: _speaking
                        ? () => setState(() => _ttsPage = true)
                        : () => unawaited(_toggleTts())),
                _barBtn(
                    icon: Icons.tune,
                    label: '设置',
                    color: _showSettings ? barOn : barDim,
                    wide: true,
                    onTap: () =>
                        setState(() => _showSettings = !_showSettings)),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: _barBtn(
                      icon: Icons.list,
                      label: '目录',
                      color: barDim,
                      onTap: _showToc),
                ),
                Expanded(
                  child: _barBtn(
                      icon: Icons.swap_horiz,
                      label: '换源',
                      color: barDim,
                      onTap: _switchSource),
                ),
                Expanded(
                  child: _barBtn(
                      icon: _speaking ? Icons.graphic_eq : Icons.headset,
                      label: _speaking ? '听书中' : '听书',
                      color: _speaking ? barOn : barDim,
                      onTap: _speaking
                          ? () => setState(() => _ttsPage = true)
                          : () => unawaited(_toggleTts())),
                ),
                Expanded(
                  child: _barBtn(
                      icon: Icons.tune,
                      label: '设置',
                      color: _showSettings ? barOn : barDim,
                      onTap: () =>
                          setState(() => _showSettings = !_showSettings)),
                ),
              ],
            ),
        ],
      ),
    );
    return Positioned(
      left: wide ? 0 : 14,
      right: wide ? 0 : 14,
      bottom: 14,
      child: Center(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: wide ? 560 : 620),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_showSettings)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: c.bg.withValues(alpha: 0.98),
                      borderRadius: BorderRadius.circular(18),
                      boxShadow: [
                        BoxShadow(
                            color: Colors.black.withValues(alpha: darkBg ? 0.4 : 0.12),
                            blurRadius: 22,
                            offset: const Offset(0, 8)),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(18),
                      child: _settingsBlock(c),
                    ),
                  ),
                ),
              bar,
            ],
          ),
        ),
      ),
    );
  }

  IconData _modeIcon() => switch (_prefs.pageMode) {
        PageMode.slide => Icons.swipe,
        PageMode.cover => Icons.layers,
        PageMode.fade => Icons.blur_on,
        PageMode.scroll => Icons.article,
      };

  /// 翻页方式选择弹层（滑动 / 覆盖 / 淡入 / 滚动）。
  Future<void> _pickPageMode() async {
    final picked = await showModalBottomSheet<PageMode>(
      context: context,
      builder: (ctx) => SafeArea(
        child: RadioGroup<PageMode>(
          groupValue: _prefs.pageMode,
          onChanged: (v) => Navigator.of(ctx).pop(v),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final m in PageMode.values)
                RadioListTile<PageMode>(
                  value: m,
                  title: Text(m.label),
                  subtitle:
                      Text(m.hint, style: Theme.of(ctx).textTheme.bodySmall),
                ),
            ],
          ),
        ),
      ),
    );
    if (picked != null && picked != _prefs.pageMode) {
      _store.setPageMode(picked);
    }
  }

  /// 悬浮条按钮：窄屏竖排（图标 18 + 字 10），宽屏横排（图标 16 + 字 12）。
  Widget _barBtn({
    required IconData icon,
    required String label,
    required Color color,
    required VoidCallback onTap,
    bool wide = false,
  }) {
    final content = wide
        ? Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 16),
              const SizedBox(width: 7),
              Text(label, style: TextStyle(color: color, fontSize: 12)),
            ],
          )
        : Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: color, size: 18),
              const SizedBox(height: 3),
              Text(label, style: TextStyle(color: color, fontSize: 10)),
            ],
          );
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: wide
            ? const EdgeInsets.symmetric(horizontal: 13, vertical: 5)
            : const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        child: content,
      ),
    );
  }

  /// 更多菜单（顶栏右侧）：书内搜索 / 书签 / 翻页方式 / 明暗 / 上下章 / 缓存。
  void _moreSheet(({Color bg, Color fg, Color dim}) c) {
    final dark = readerBgIsDark(_prefs.bgIndex, _prefs.theme);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.chevron_left),
              title: const Text('上一章'),
              onTap: () {
                Navigator.of(ctx).pop();
                _jumpChapter(_chIdx - 1);
              },
            ),
            ListTile(
              leading: const Icon(Icons.chevron_right),
              title: const Text('下一章'),
              onTap: () {
                Navigator.of(ctx).pop();
                _jumpChapter(_chIdx + 1);
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.search),
              title: const Text('书内搜索'),
              onTap: () {
                Navigator.of(ctx).pop();
                _showSearch();
              },
            ),
            ListTile(
              leading: const Icon(Icons.bookmark_border),
              title: const Text('书签'),
              onTap: () {
                Navigator.of(ctx).pop();
                _showBookmarks();
              },
            ),
            ListTile(
              leading: Icon(_modeIcon()),
              title: Text('翻页方式 · ${_prefs.pageMode.label}'),
              onTap: () {
                Navigator.of(ctx).pop();
                _pickPageMode();
              },
            ),
            ListTile(
              leading: Icon(dark ? Icons.light_mode : Icons.dark_mode),
              title: Text(dark ? '切到浅色背景' : '切到夜间背景'),
              onTap: () {
                Navigator.of(ctx).pop();
                _store.setBgIndex(dark ? 0 : 4);
                setState(() {});
              },
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('缓存全书'),
              subtitle: const Text('断网也能接着读'),
              onTap: () {
                Navigator.of(ctx).pop();
                _quickCache();
              },
            ),
          ],
        ),
      ),
    );
  }

  bool _dlAll = false;

  /// 阅读器内一键缓存全书（进度用 SnackBar 提示，重复触发直接忽略）。
  Future<void> _quickCache() async {
    final d = _detail;
    if (d == null || _dlAll) return;
    _dlAll = true;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(const SnackBar(
        content: Text('开始缓存全书…'), duration: Duration(seconds: 1)));
    var done = 0;
    final ok = await AppStore.I.downloadBook(
      _src,
      d,
      onProgress: (n, t) => done = n,
    );
    if (!mounted) return;
    _dlAll = false;
    messenger.showSnackBar(SnackBar(
        content: Text(ok
            ? '全书缓存完成（$done 章）'
            : '缓存中断（$done/${d.chapters.length} 章）')));
  }

  /// 宽屏右侧目录抽屉（效果图 12）：当前章高亮 + 「在读」标记。
  Widget _tocDrawerOverlay(({Color bg, Color fg, Color dim}) c) {
    final d = _detail;
    if (d == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    const extent = 38.0;
    final ctrl = ScrollController(
      initialScrollOffset:
          (_chIdx * extent - 190).clamp(0.0, double.infinity).toDouble(),
    );
    return Positioned(
      top: 0,
      right: 0,
      bottom: 0,
      child: Container(
        width: 272,
        decoration: BoxDecoration(
          color: theme.cardColor,
          border: Border(left: BorderSide(color: Brand.hair(context))),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 12, 8, 8),
              child: Row(
                children: [
                  Text('目录',
                      style: theme.textTheme.titleSmall
                          ?.copyWith(fontWeight: FontWeight.w800)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('共 ${d.chapters.length} 章',
                        style: TextStyle(
                            fontSize: 11, color: Brand.fg3(context))),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 18, color: theme.hintColor),
                    tooltip: '收起目录',
                    onPressed: () => setState(() => _tocOpen = false),
                  ),
                ],
              ),
            ),
            Divider(height: 1, color: Brand.hair(context)),
            Expanded(
              child: ListView.builder(
                controller: ctrl,
                itemExtent: extent,
                padding: const EdgeInsets.symmetric(vertical: 6),
                itemCount: d.chapters.length,
                itemBuilder: (ctx2, i) {
                  final cur = i == _chIdx;
                  return Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    child: GestureDetector(
                      onTap: () => _jumpChapter(i),
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        alignment: Alignment.centerLeft,
                        decoration: BoxDecoration(
                          color: cur
                              ? (dark
                                  ? Brand.green.withValues(alpha: 0.16)
                                  : Brand.greenSoft)
                              : null,
                          borderRadius: BorderRadius.circular(9),
                        ),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(d.chapters[i].title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    fontWeight:
                                        cur ? FontWeight.w700 : FontWeight.w400,
                                    color: cur
                                        ? Brand.green
                                        : theme.hintColor,
                                  )),
                            ),
                            if (cur)
                              Text('在读',
                                  style: TextStyle(
                                      fontSize: 10,
                                      color: Brand.fg3(context))),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 阅读设置面板：排版 / 外观 / 听书 三页签。
  ///
  /// 限高约 42% 屏高并让正文保持可见 —— 这是社区反馈过的痛点：
  /// 「设置栏太长、调字号看不到正文」。
  Widget _settingsBlock(({Color bg, Color fg, Color dim}) c) {
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.42,
      child: DefaultTabController(
        length: 3,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const TabBar(
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelStyle: TextStyle(fontSize: 13),
              tabs: [
                Tab(height: 32, text: '排版'),
                Tab(height: 32, text: '外观'),
                Tab(height: 32, text: '听书'),
              ],
            ),
            Flexible(
              child: TabBarView(
                children: [_layoutTab(c), _appearanceTab(c), _ttsTab(c)],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _slider(
    ({Color bg, Color fg, Color dim}) c,
    String label,
    double value,
    double min,
    double max,
    int divisions,
    ValueChanged<double> onChanged, {
    String? valueText,
  }) =>
      Row(
        children: [
          SizedBox(
              width: 44,
              child: Text(label, style: TextStyle(color: c.dim, fontSize: 12))),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              onChanged: (v) {
                onChanged(v);
                setState(() {}); // 分页键含排版签名，rebuild 时自动重排
              },
            ),
          ),
          SizedBox(
            width: 38,
            child: Text(valueText ?? value.toStringAsFixed(1),
                textAlign: TextAlign.right,
                style: TextStyle(color: c.dim, fontSize: 12)),
          ),
        ],
      );

  Widget _layoutTab(({Color bg, Color fg, Color dim}) c) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [
          _fontRow(c),
          _slider(c, '字号', _prefs.fontSize, 12, 32, 20, _store.setFontSize,
              valueText: '${_prefs.fontSize.round()}'),
          _slider(
              c, '行距', _prefs.lineHeight, 1.2, 2.6, 14, _store.setLineHeight),
          _slider(c, '字距', _prefs.letterSpacing, -1, 8, 18,
              _store.setLetterSpacing),
          _slider(c, '左右', _prefs.marginH, 0, 64, 16, _store.setMarginH,
              valueText: '${_prefs.marginH.round()}'),
          _slider(c, '上下', _prefs.marginV, 0, 160, 16, _store.setMarginV,
              valueText: '${_prefs.marginV.round()}'),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('首行缩进两字', style: TextStyle(color: c.fg, fontSize: 13)),
            value: _prefs.indentFirstLine,
            onChanged: (v) {
              _store.setIndentFirstLine(v);
              setState(() {});
            },
          ),
        ],
      );

  /// 「字体」一行：显示当前字体，点开挑选（网络字体选中才下载）。
  Widget _fontRow(({Color bg, Color fg, Color dim}) c) {
    final name = _prefs.fontFamily.isEmpty
        ? '系统默认'
        : (FontStore.byId(_prefs.fontFamily)?.name ?? '系统默认');
    final downloading =
        FontStore.I.statusOf(_prefs.fontFamily) == FontStatus.downloading;
    return InkWell(
      onTap: () => showFontPicker(context, bg: c.bg, fg: c.fg, dim: c.dim),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            SizedBox(
                width: 44,
                child: Text('字体',
                    style: TextStyle(color: c.dim, fontSize: 12))),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: c.fg,
                            fontSize: 13,
                            fontFamily: FontStore.I
                                .activeFont(_prefs.fontFamily)
                                ?.family)),
                  ),
                  if (downloading) ...[
                    const SizedBox(width: 6),
                    Text('下载中…',
                        style: TextStyle(color: c.dim, fontSize: 10.5)),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right, size: 18, color: c.dim),
          ],
        ),
      ),
    );
  }

  Widget _appearanceTab(({Color bg, Color fg, Color dim}) c) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [
          Text('翻页方式', style: TextStyle(color: c.dim, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            children: [
              for (final m in PageMode.values)
                ChoiceChip(
                  label: Text(m.label, style: const TextStyle(fontSize: 12)),
                  selected: _prefs.pageMode == m,
                  onSelected: (_) => _store.setPageMode(m),
                ),
            ],
          ),
          const SizedBox(height: 14),
          Text('阅读背景', style: TextStyle(color: c.dim, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < kReaderBgs.length; i++) _bgChip(c, i)
            ],
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title:
                Text('显示页眉（章节名）', style: TextStyle(color: c.fg, fontSize: 13)),
            value: _prefs.showHeader,
            onChanged: (v) {
              _store.setShowHeader(v);
              setState(() {});
            },
          ),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text('显示页脚（时间/页码/电量）',
                style: TextStyle(color: c.fg, fontSize: 13)),
            value: _prefs.showFooter,
            onChanged: (v) {
              _store.setShowFooter(v);
              setState(() {});
            },
          ),
        ],
      );

  /// 背景色卡：色块 + 名称，选中加粗描边。
  Widget _bgChip(({Color bg, Color fg, Color dim}) c, int i) {
    final b = kReaderBgs[i];
    final sel = _prefs.bgIndex == i;
    return GestureDetector(
      onTap: () {
        _store.setBgIndex(i);
        setState(() {});
      },
      child: Container(
        width: 76,
        padding: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(
          color: b.bg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: sel ? c.fg : const Color(0x33888888),
            width: sel ? 2 : 1,
          ),
        ),
        child: Text(
          b.name,
          textAlign: TextAlign.center,
          style: TextStyle(
              color: b.fg,
              fontSize: 12,
              fontWeight: sel ? FontWeight.w700 : null),
        ),
      ),
    );
  }

  Widget _ttsTab(({Color bg, Color fg, Color dim}) c) => ListView(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 16),
        children: [
          _slider(c, '语速', _prefs.ttsRate, 0.1, 1.0, 9, _store.setTtsRate),
          _slider(c, '音调', _prefs.ttsPitch.clamp(0.5, 2.0), 0.5, 2.0, 15,
              _store.setTtsPitch),
          Row(
            children: [
              SizedBox(
                  width: 44,
                  child:
                      Text('音色', style: TextStyle(color: c.dim, fontSize: 12))),
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
          const SizedBox(height: 8),
          Text('在线音色由微软 Edge 合成，需要联网；合成结果会缓存在本地。',
              style: TextStyle(color: c.dim, fontSize: 11)),
          const SizedBox(height: 14),
          Row(
            children: [
              SizedBox(
                  width: 44,
                  child: Text('定时',
                      style: TextStyle(color: c.dim, fontSize: 12))),
              for (final m in const [0, 15, 30, 60])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: GestureDetector(
                    onTap: () => _setSleepTimer(m),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 5),
                      decoration: BoxDecoration(
                        color: _sleepMin == m ? Brand.green : null,
                        border: Border.all(
                            color: _sleepMin == m
                                ? Brand.green
                                : c.dim.withValues(alpha: 0.4)),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        m == 0 ? '关闭' : '$m 分',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: _sleepMin == m ? Colors.white : c.dim,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      );

  // ---------- 听书（TTS） ----------
  void _togglePause() => _ttsSession.togglePause();
  Future<void> _stopTts() => _ttsSession.stop();

  /// 音色/语速/音调变了 → 会话重新应用（系统 TTS 参数）。
  Future<void> _initTts() => _ttsSession.applyVoice();

  /// 小智（温柔）：优先 Yaoyao（女）> Huihui（女）> 任意中文音色

  /// 系统里找台湾腔音色（zh-TW/繁体：Hanhan/Taiwan/Hant），女声优先；没有返回 null。

  /// 台湾腔：有系统台语音色则用，没装则回退 _pickGentleVoice（柔和女声）。

  // ---- 在线音色（Edge TTS）----

  /// 当前是否选中在线音色。


  /// 段落 → 本地缓存 mp3 路径（<缓存>/tts/<sha1(voice|text)>.mp3，命中直接复用）。

  /// 在线合成一段并开播；完成信号复用 _utter（onPlayerComplete → _finishUtter）。
  /// 合成失败抛出，由 [_speakSeg] 回退系统 TTS。

  /// 预热下一段在线合成（播放第 i 段时调用；静默失败）。

  /// 朗读一段：在线音色走 Edge 合成+播放；失败（一场一次提示）回退系统 TTS。
  /// 完成信号统一走 _utter/_finishUtter。

  /// 在线音色首次选择：一次性联网说明（存 prefs.edgeNotice）。
  Future<void> _maybeEdgeNotice() async {
    if (_store.prefs.edgeNotice) return;
    _store.setEdgeNotice(true);
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('在线朗读说明'),
        content: const Text('该音色通过微软 Edge 在线合成语音，需要联网；\n合成结果会缓存在本地，重复收听不再耗流量。'),
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
      await _ttsSession.stop();
      return;
    }
    if (_detail == null || _paras.isEmpty || _loading) return;
    await _ttsSession.start(
      book: _book,
      detail: _detail!,
      source: _src,
      paras: _paras,
      chapterIndex: _chIdx,
      startPara: _ttsStartIndex(),
    );
    if (mounted) setState(() {});
  }

  /// 通知栏动作（Android 锁屏控制）→ 阅读器听书状态机。

  /// 同步「正在朗读」通知（书名 · 章节 + 当前段落摘要）。非 Android 平台直接返回。

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
        final avg = pos.maxScrollExtent / (_paras.isEmpty ? 1 : _paras.length);
        off = _kPadTop + i * (avg > 1 ? avg : 40);
      }
      off = off.clamp(0.0, _scrollCtrl.position.maxScrollExtent).toDouble();
      _scrollCtrl.animateTo(off,
          duration: const Duration(milliseconds: 280), curve: Curves.easeOut);
    });
  }

  // ---------- 听书页（效果图 08） ----------

  /// 定时停止（0 = 关闭）。到点自动停播；听书页与设置面板共用。
  /// 定时停止：状态在会话里，倒计时随会话通知刷新本页。
  void _setSleepTimer(int minutes) => _ttsSession.setSleepTimer(minutes);

  /// 波形高度百分比（效果图 08 的静态形态，按播放进度染色）。
  static const List<int> _waveHeights = [
    24, 40, 58, 32, 68, 46, 26, 54, 72, 38, 30, 62, 48, 34, 56, 66, 42, 28,
    60, 50, 36, 70, 52, 32, 58, 64, 40, 26, 54, 68, 44, 30, 52, 62, 40, 32,
  ];

  String _fmtDur(Duration d) =>
      '${d.inMinutes.toString().padLeft(2, '0')}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  /// 全屏听书页：波形 + 播放控制 + 段落高亮卡 + 音色 / 语速 / 音调 + 定时停止。
  Widget _ttsPageOverlay(({Color bg, Color fg, Color dim}) c) {
    final theme = Theme.of(context);
    final darkBg = readerBgIsDark(_prefs.bgIndex, _prefs.theme);
    final paras = _paras;
    final cur = (_ttsCur >= 0 && _ttsCur < paras.length) ? paras[_ttsCur] : '';
    final elapsed = _ttsSince == null
        ? Duration.zero
        : DateTime.now().difference(_ttsSince!);
    final progress =
        paras.isEmpty ? 0.0 : ((_ttsCur + 1) / paras.length).clamp(0.0, 1.0);
    final totalEst = progress > 0.02
        ? Duration(seconds: (elapsed.inSeconds / progress).round())
        : null;
    const on = Color(0xFF8FD9AE);
    return Positioned.fill(
      child: Container(
        color: c.bg,
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
            children: [
              Row(
                children: [
                  IconButton(
                    icon: Icon(Icons.keyboard_arrow_down, color: c.fg),
                    tooltip: '收起',
                    onPressed: () => setState(() => _ttsPage = false),
                  ),
                  Expanded(
                    child: Text('听书',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                            color: c.fg,
                            fontSize: 17,
                            fontWeight: FontWeight.w800)),
                  ),
                  const SizedBox(width: 48),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  BookCover(_book, width: 52, height: 72, radius: 9),
                  const SizedBox(width: 13),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                            _chapterTitle.isEmpty
                                ? '第 ${_chIdx + 1} 章'
                                : _chapterTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: c.fg,
                                fontSize: 15,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 4),
                        Text(
                          [
                            _book.title,
                            if (_book.author?.isNotEmpty ?? false)
                              _book.author!,
                          ].join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: c.dim, fontSize: 11.5),
                        ),
                        const SizedBox(height: 4),
                        const Text('段落高亮跟随 · 自动跨章',
                            style: TextStyle(
                                color: on,
                                fontSize: 11,
                                fontWeight: FontWeight.w700)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: _openSleepSheet,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        border:
                            Border.all(color: c.dim.withValues(alpha: 0.4)),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.schedule, size: 12, color: c.dim),
                          const SizedBox(width: 4),
                          Text(_sleepMin > 0 ? _sleepLeft : '定时',
                              style:
                                  TextStyle(color: c.dim, fontSize: 11.5)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 22),
              SizedBox(
                height: 46,
                child: Row(
                  children: [
                    for (var i = 0; i < _waveHeights.length; i++) ...[
                      if (i > 0) const SizedBox(width: 3),
                      Expanded(
                        child: Container(
                          height: 46 * _waveHeights[i] / 100,
                          decoration: BoxDecoration(
                            color: i / _waveHeights.length <= progress
                                ? on
                                : (darkBg
                                        ? Colors.white24
                                        : const Color(0xFFD5E0D2))
                                    .withValues(alpha: 0.85),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(_fmtDur(elapsed),
                      style: TextStyle(
                          color: c.dim,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontFamilyFallback: const ['Consolas', 'Courier'])),
                  Text(totalEst == null ? '--:--' : _fmtDur(totalEst),
                      style: TextStyle(
                          color: c.dim,
                          fontSize: 11,
                          fontFamily: 'monospace',
                          fontFamilyFallback: const ['Consolas', 'Courier'])),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    iconSize: 30,
                    icon: Icon(Icons.skip_previous, color: c.dim),
                    tooltip: '上一段',
                    onPressed: _ttsPrevPara,
                  ),
                  const SizedBox(width: 22),
                  GestureDetector(
                    onTap: _speaking
                        ? _togglePause
                        : () => unawaited(_toggleTts()),
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: const LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [Color(0xFF3E8A50), Brand.green]),
                        boxShadow: [
                          BoxShadow(
                              color: Brand.green.withValues(alpha: 0.35),
                              blurRadius: 24,
                              offset: const Offset(0, 10)),
                        ],
                      ),
                      child: Icon(
                        _speaking && !_ttsPaused
                            ? Icons.pause
                            : Icons.play_arrow,
                        size: 30,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  const SizedBox(width: 22),
                  IconButton(
                    iconSize: 30,
                    icon: Icon(Icons.skip_next, color: c.dim),
                    tooltip: '下一段',
                    onPressed: _ttsNextPara,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                decoration: BoxDecoration(
                  color: theme.cardColor,
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                            _ttsPaused
                                ? Icons.pause_circle_outline
                                : Icons.headset,
                            size: 13,
                            color: Brand.green),
                        const SizedBox(width: 5),
                        Expanded(
                          child: Text(
                            _ttsPaused
                                ? '已暂停'
                                : '正在朗读 · ${ttsVoiceLabel(_prefs.ttsVoice)}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: Brand.green,
                                fontSize: 10.5,
                                fontWeight: FontWeight.w700),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 7),
                    Text(
                      cur.isEmpty ? '（等待进入下一段…）' : cur,
                      maxLines: 5,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.8,
                        color: theme.hintColor,
                        fontFamilyFallback: kSerifFallback,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Text('在线音色',
                      style: TextStyle(
                          color: c.fg,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  Text('${kEdgeVoices.length} 款 · 断网自动回退系统语音',
                      style: TextStyle(color: c.dim, fontSize: 10.5)),
                ],
              ),
              const SizedBox(height: 9),
              SizedBox(
                height: 54,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  children: [
                    _voiceChip(c, '', '系统'),
                    for (final e in kEdgeVoices.entries)
                      _voiceChip(
                          c, e.key, e.value.$1.replaceAll('（在线）', '')),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              _slider(c, '语速', _prefs.ttsRate, 0.1, 1.0, 9, _store.setTtsRate,
                  valueText: ttsRateLabel(_prefs.ttsRate)),
              _slider(c, '音调', _prefs.ttsPitch.clamp(0.5, 2.0), 0.5, 2.0, 15,
                  _store.setTtsPitch),
              const SizedBox(height: 10),
              Text('定时停止', style: TextStyle(color: c.dim, fontSize: 12)),
              const SizedBox(height: 7),
              Wrap(
                spacing: 8,
                children: [
                  for (final m in const [0, 15, 30, 60])
                    GestureDetector(
                      onTap: () => _setSleepTimer(m),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 14, vertical: 6),
                        decoration: BoxDecoration(
                          color: _sleepMin == m ? Brand.green : null,
                          border: Border.all(
                              color: _sleepMin == m
                                  ? Brand.green
                                  : c.dim.withValues(alpha: 0.4)),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: Text(
                          m == 0 ? '关闭' : '$m 分',
                          style: TextStyle(
                            fontSize: 12,
                            color: _sleepMin == m ? Colors.white : c.dim,
                            fontWeight:
                                _sleepMin == m ? FontWeight.w700 : null,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              if (_sleepMin > 0) ...[
                const SizedBox(height: 8),
                Text('将在 $_sleepLeft 后自动停止播放',
                    style: TextStyle(color: c.dim, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _voiceChip(
      ({Color bg, Color fg, Color dim}) c, String key, String name) {
    final sel = _prefs.ttsVoice == key ||
        (key.isEmpty && !kEdgeVoices.containsKey(_prefs.ttsVoice));
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () async {
          _store.setTtsVoice(key);
          await _maybeEdgeNotice();
          setState(() {});
          await _initTts();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: sel ? Brand.green.withValues(alpha: 0.14) : null,
            border: Border.all(
                color: sel ? Brand.green : c.dim.withValues(alpha: 0.4)),
            borderRadius: BorderRadius.circular(14),
          ),
          alignment: Alignment.center,
          child: Text(name,
              style: TextStyle(
                fontSize: 12.5,
                fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                color: sel ? Brand.green : c.dim,
              )),
        ),
      ),
    );
  }

  /// 上一段：把播放游标退一格后解除当前阻塞，循环继续时读新段。
  void _ttsPrevPara() => _ttsSession.prevPara();

  /// 下一段：游标加一（越过段尾时循环会自动进入下一章）。
  void _ttsNextPara() => _ttsSession.nextPara();

  Future<void> _openSleepSheet() async {
    final picked = await showModalBottomSheet<int>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final m in const [0, 15, 30, 60])
              ListTile(
                leading: Icon(
                    m == 0 ? Icons.timer_off_outlined : Icons.timer_outlined),
                title: Text(m == 0 ? '关闭定时' : '$m 分钟后停止'),
                selected: _sleepMin == m,
                onTap: () => Navigator.of(ctx).pop(m),
              ),
          ],
        ),
      ),
    );
    if (picked != null) _setSleepTimer(picked);
  }

  Widget _ttsBar(({Color bg, Color fg, Color dim}) c) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: GestureDetector(
        onTap: () => setState(() => _ttsPage = true),
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
                  '${_ttsPaused ? '已暂停' : '正在朗读'} · ${_ttsCur + 1}/${_paras.length} 段'
                  '${_sleepMin > 0 ? ' · $_sleepLeft 后停' : ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.dim, fontSize: 12),
                ),
              ),
              Icon(Icons.keyboard_arrow_up, size: 18, color: c.dim),
              const SizedBox(width: 6),
            ],
          ),
        ),
      ),
    );
  }

  // ---------- 目录 / 书签 / 换源 ----------

  void _showToc() {
    final d = _detail;
    if (d == null) return;
    final chIdx = _chIdx;
    final ctrl = ScrollController();
    final probeKey = GlobalKey(); // 第 0 项：量实际行高（行高随系统字号缩放）
    final curKey = GlobalKey(); // 当前章：跳转后精确对齐
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
                controller: ctrl,
                itemCount: d.chapters.length,
                itemBuilder: (ctx2, i) => ListTile(
                  key: i == 0
                      ? probeKey
                      : (i == chIdx ? curKey : null),
                  dense: true,
                  title: Text(
                    d.chapters[i].title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: i == chIdx
                          ? Theme.of(ctx2).colorScheme.primary
                          : null,
                      fontWeight: i == chIdx ? FontWeight.bold : null,
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
    ).whenComplete(ctrl.dispose);
    // 打开后定位到当前章节：各条目等高（单行 dense ListTile），按第 0 项
    // 实测行高算目标位（列表从顶部构建，第 0 项必然存在），平滑滚过去；
    // 落点与实际行高若有微小偏差，再对当前章条目 ensureVisible 精修。
    // 直接 ensureVisible 不行 —— 跳转前远端条目还没被 builder 构建。
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!ctrl.hasClients) return;
      final box = probeKey.currentContext?.findRenderObject() as RenderBox?;
      final h = box?.size.height ?? 36;
      if (h <= 0) return;
      final pos = ctrl.position;
      final target =
          (chIdx * h).clamp(pos.minScrollExtent, pos.maxScrollExtent).toDouble();
      if ((target - pos.pixels).abs() < 1) return;
      try {
        await ctrl.animateTo(target,
            duration: const Duration(milliseconds: 350),
            curve: Curves.easeOutCubic);
      } catch (_) {
        return; // 动画期间面板被关掉 / controller 已释放
      }
      if (!ctrl.hasClients) return;
      final c = curKey.currentContext;
      if (c == null || !c.mounted) return;
      Scrollable.ensureVisible(c,
          duration: const Duration(milliseconds: 120),
          alignment: 0.5);
    });
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
                                : _paras.first.substring(0,
                                    _paras.first.length.clamp(0, 30).toInt());
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
        if (mounted) StatsStore.I.addSourceSwitch(); // 换源成功才计数（换源大师徽章）
      },
    );
  }

  static String _norm(String s) => s.replaceAll(RegExp(r'[^一-龥a-zA-Z0-9]'), '');

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
