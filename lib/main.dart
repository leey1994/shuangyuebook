import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'announcement.dart';
import 'data/font_store.dart';
import 'data/stats_store.dart';
import 'feed_cache.dart';
import 'legado/cookie_jar.dart';
import 'legado/source_health.dart';
import 'legado/source_store.dart';
import 'legado/source_vars.dart';
import 'legado/webview_engine.dart';
import 'pet/pet_store.dart';
import 'pet/pet_view.dart';
import 'platform/open_file_dispatch.dart';
import 'screens/home_screen.dart';
import 'screens/profile_screen.dart';
import 'screens/rank_screen.dart';
import 'screens/shelf_screen.dart';
import 'sources/registry.dart';
import 'store.dart';
import 'theme.dart';
import 'title_bar.dart';
import 'ui/brand.dart';
import 'ui/pet_top_band.dart';
import 'ui/storage_gate.dart';
import 'ui/system_metrics.dart';
import 'update_check.dart';

/// 崩溃兜底：写入临时目录日志，避免未捕获异常直接杀进程。
void _logCrash(Object e, StackTrace s) {
  try {
    final f = File('${Directory.systemTemp.path}/shuangyue_crash.log');
    f.writeAsStringSync('==== ${DateTime.now()} ====\n$e\n$s\n\n',
        mode: FileMode.append);
  } catch (_) {}
}

Future<void> main(List<String> args) async {
  // 启动标记：崩溃定位用（存在 = Dart 已进入 main）
  try {
    File('${Directory.systemTemp.path}/sy_boot.txt')
        .writeAsStringSync('${DateTime.now().toIso8601String()} args=$args\n');
  } catch (_) {}
  WidgetsFlutterBinding.ensureInitialized();
  FlutterError.onError =
      (d) => _logCrash(d.exception, d.stack ?? StackTrace.current);
  PlatformDispatcher.instance.onError = (e, s) {
    _logCrash(e, s);
    return true; // 吞掉未捕获异常，不让进程退出
  };
  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      // 自绘窗体控制：隐藏系统标题栏，内容区顶端放自己的标题栏（可拖动/缩放）
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    } catch (e, s) {
      _logCrash(e, s);
    }
  }
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.landscapeLeft,
    DeviceOrientation.landscapeRight,
  ]);
  if (Platform.isAndroid) {
    // 安卓全程 edge-to-edge：应用画到系统栏底下，顶部那条状态栏区域就是
    // 桌宠的活动带（原来显示时间 / 信号强度的地方）。不开的话系统会另外
    // 占掉一整条状态栏，我们的窄带就被挤到它下面，顶部等于两条叠加。
    // 阅读器会临时切到 immersive 隐藏状态栏，退出时由 _applySystemUi 还原。
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  }
  try {
    await AppStore.I.init();
  } catch (_) {
    // 个别环境（权限/杀软拦截）下偏好初始化失败时不阻塞启动，降级为无持久化运行
  }
  // 首帧之前只做「必须有」的事：书源（含 1000+ 条的 JSON 解析，已挪到后台
  // isolate）与脚本变量。其余（磁盘缓存、统计、体检、公告）都挪到首帧之后，
  // 低端机上「点开图标到出画面」这一段每省 100ms 都是体感。
  try {
    // 「阅读 3.0」书源：先补内置源，再把用户启用的源登记进 allSources。
    // 失败不阻塞启动 —— 内置书源照常可用。
    final sources = SourceStore();
    await sources.load();
    await sources.syncBuiltinSources();
    SourceStore.shared = sources;
    // 书源变量（脚本里 source.getVariable/setVariable 的持久层）：要在任何
    // 抓取之前就绪，否则「搜索存 token → 正文取 token」的源会拿到空值。
    final vars = SourceVars();
    await vars.load();
    SourceVars.shared = vars;
    // Cookie 仓库（同 legado 的 CookieManager）：登录态/会话跨请求、跨重启保留。
    final cookies = LegadoCookieJar();
    await cookies.load();
    LegadoCookieJar.shared = cookies;
    syncImportedSources(sources.enabled);
    sources.addListener(() => syncImportedSources(sources.enabled));
  } catch (_) {}
  // 桌宠的偏好句柄接在 AppStore 上（反过来 import 会和 store 循环引用）
  try {
    PetStore.prefsProvider = () => AppStore.I.sp;
    PetStore.I.load();
    // 成就徽章点亮时让小墨报喜（stats 不反向 import pet，走回调注入）
    StatsStore.onBadgeEarned =
        (b) => PetStore.I.celebrate('${b.name}达成！', exp: 10);
  } catch (_) {}
  runApp(const NovelApp());
  // 首帧之后再做的事：磁盘缓存、统计、体检 —— 都不影响能不能进应用。
  WidgetsBinding.instance.addPostFrameCallback((_) => _afterFirstFrame());
}

/// 首帧之后的收尾任务（失败一律忽略）。
Future<void> _afterFirstFrame() async {
  try {
    await FeedCache.init(); // 首页/排行/搜索磁盘缓存，二次打开免重新拉取
  } catch (_) {}
  try {
    await StatsStore.I.load(); // 阅读统计（时长 / 连续天数 / 最近 7 天）
  } catch (_) {}
  try {
    await SourceHealthStore.I.load(); // 健康档案先落座，30 秒后的体检才有的写
    // 书源健康档案：每天首次启动自动体检一次（只标记不删源）。
    // 隔几天没打开 ⇒ 打开那天必然触发整轮巡检，所以这里两个约束：
    //  - 延后 30 秒：不与首页推荐 / 公告 / 更新检查抢同一段带宽和站点限流；
    //  - 并发固定 2：后台巡检不该按手动体检的档位全速跑（用户设置只作用于
    //    「书源管理」里手动体检）。网络与解析都在分身池里跑（见 parse_worker.dart），
    //    主 isolate 只收结论 —— 这是「打开就卡」的根治处。
    Future.delayed(const Duration(seconds: 30), () {
      unawaited(SourceHealthStore.I.autoRunIfNeeded(concurrency: 2).then((r) {
        // 有失效书源就提醒一句，具体清单去「阅读记录」里看
        if (r != null && r.hasFailure && r.failed.isNotEmpty) {
          debugPrint('[书源体检] ${r.summary}');
        }
      }));
    });
  } catch (_) {}
  try {
    // 上次选过网络字体：后台把字体下好（只下一次），下完进阅读器即刻生效。
    FontStore.I.warmUpSelected(AppStore.I.prefs.fontFamily);
  } catch (_) {}
}

/// 只在主题变化时重建 MaterialApp，
/// 避免书架进度等高频 notifyListeners 触发整棵 widget 树重建（卡顿根源之一）。
class NovelApp extends StatefulWidget {
  const NovelApp({super.key});

  @override
  State<NovelApp> createState() => _NovelAppState();
}

class _NovelAppState extends State<NovelApp> {
  int _theme = AppStore.I.prefs.theme;

  @override
  void initState() {
    super.initState();
    AppStore.I.addListener(_onStore);
  }

  @override
  void dispose() {
    AppStore.I.removeListener(_onStore);
    super.dispose();
  }

  void _onStore() {
    final t = AppStore.I.prefs.theme;
    if (t != _theme && mounted) setState(() => _theme = t);
  }

  @override
  Widget build(BuildContext context) {
    final dark = _theme == AppThemes.black;
    if (Platform.isAndroid) {
      // 状态栏透明：edge-to-edge 之下由应用自己铺底色（见 _wrap 的 ColoredBox），
      // 这样那条带子里除了系统图标还能放桌宠。图标明暗随主题反转。
      final bg = AppThemes.scaffold(_theme);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: dark ? Brightness.light : Brightness.dark,
        statusBarBrightness: dark ? Brightness.dark : Brightness.light,
        systemNavigationBarColor: bg,
        systemNavigationBarIconBrightness:
            dark ? Brightness.light : Brightness.dark,
      ));
    }
    // Windows 引擎 accessibility bridge 已知 bug（flutter#182444）：
    // AXTree 更新顺序错乱后拒绝后续更新，窗口 resize 时 bridge 解引用失效节点
    // 直接原生崩溃（0xC000041D，表现为调整窗体大小闪退）。本应用无屏幕阅读器
    // 需求，根部关闭 semantics 让 bridge 不生成可 diff 的树，上游修复合入后可移除。
    Widget app = MaterialApp(
      title: '爽阅',
      debugShowCheckedModeBanner: false,
      theme: AppThemes.material(AppThemes.white),
      darkTheme: AppThemes.material(AppThemes.black),
      themeMode: dark ? ThemeMode.dark : ThemeMode.light,
      // 存储权限门：Android 11+ 导入本地书需要「所有文件访问」。
      // 非 Android 直接透传，不做任何检查。
      home: const StorageGate(child: HomeShell()),
      builder: (context, child) => _wrap(context, child),
    );
    if (Platform.isWindows) app = ExcludeSemantics(child: app);
    return app;
  }

  /// 全局包装：
  /// 1) 桌面端按窗口宽度等比缩放文字与图标（基准 1280 逻辑宽）；
  /// 2) Windows 顶部放自绘标题栏（可拖动、最小化/最大化/关闭）；
  /// 3) 安卓顶部让出状态栏（含 edge-to-edge 下 viewPadding 兜底），避免被挡。
  Widget _wrap(BuildContext context, Widget? child) {
    var mq = MediaQuery.of(context);
    Widget app = child ?? const SizedBox.shrink();

    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // 缩放只在窄屏（安卓尺寸）下生效防内容溢出，宽屏一律原样不缩放
      final w = mq.size.width;
      final scale = w <= kNarrowBreakpoint
          ? (w / kNarrowBreakpoint).clamp(0.6, 1.0).toDouble()
          : 1.0;
      mq = mq.copyWith(textScaler: TextScaler.linear(scale));
      app = Column(
        children: [
          const DesktopTitleBar(),
          Expanded(child: app),
        ],
      );
      final icon = IconTheme.of(context);
      return MediaQuery(
        data: mq,
        child: IconTheme(
          data: icon.copyWith(size: (icon.size ?? 24) * scale),
          child: app,
        ),
      );
    }

    if (Platform.isAndroid) {
      // 安卓走 edge-to-edge（见 main 里的 setEnabledSystemUIMode）：应用画到
      // 状态栏底下，所以桌宠窄带**就是**状态栏本身那一行 —— 原来显示时间 /
      // 信号强度的地方，而不是状态栏下面再补一条。
      // 不开 edge-to-edge 的话顶部会变成两条叠加（≈56px），看着像被顶下去了。
      //
      // 高度用启动时量好的 [SystemMetrics.topInset]（见 captureSystemInsets），
      // 不读实时 MediaQuery —— 阅读器会隐藏状态栏，实时读数会塌成 0，整条带子跟着跳。
      app = PetTopBand(
        band: PetBar.defaultHeight(),
        background: AppThemes.scaffold(_theme),
        child: app,
      );
    }
    // 隐藏 WebView 宿主（1×1，仅 Android 且引擎激活后才构建）：
    // 放在最外层保证跨路由存活，Windows 上自动透传。
    app = WebViewEngineHost(child: app);
    return MediaQuery(data: mq, child: app);
  }
}

/// 主壳：窄屏底部 4 Tab / 宽屏左侧边栏（首页 / 排行 / 书架 / 我的）。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _railOpen = false; // 宽屏侧边菜单展开/收起
  Timer? _noticePoll; // 实时公告轮询
  /// 访问过的 Tab。IndexedStack 一旦构建子页就会 initState 开始拉网，
  /// 四个页面全建 = 启动瞬间首页和排行同时开跑（几十个并发请求），
  /// 所以只构建点开过的，之后留在栈里保状态。
  final _visited = <int>{0};

  @override
  void initState() {
    super.initState();
    // 趁状态栏还看得见，把它的高度量下来。阅读器会隐藏状态栏并手动补回
    // 这段留白 —— 到时候 MediaQuery 已经是 0 了，只能现在记。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) captureSystemInsets(context);
    });
    // 「用爽阅打开」文件关联：txt/epub 导入并进阅读器，json 导入为书源
    installOpenFileHandler(context);
    // 启动 2 秒后先查实时公告（GitHub 托管 JSON，新 id 全屏弹出并等关闭），
    // 结束后再静默检查 GitHub Release，避免两个弹窗叠加。
    Future.delayed(const Duration(seconds: 2), () async {
      if (mounted) await NoticeChecker.check(context);
      if (mounted) {
        Future.delayed(const Duration(seconds: 1), () {
          if (mounted) UpdateChecker.check(context);
        });
      }
    });
    // 运行期间每 10 分钟轮询一次，运行中发布的公告也能及时全屏送达
    _noticePoll = Timer.periodic(const Duration(minutes: 10), (_) {
      if (mounted) NoticeChecker.check(context);
    });
  }

  @override
  void dispose() {
    _noticePoll?.cancel();
    super.dispose();
  }

  Widget _pages() => IndexedStack(
        index: _index,
        children: [
          const HomeScreen(),
          _visited.contains(1) ? const RankScreen() : const SizedBox.shrink(),
          _visited.contains(2) ? const ShelfScreen() : const SizedBox.shrink(),
          _visited.contains(3)
              ? const ProfileScreen()
              : const SizedBox.shrink(),
        ],
      );

  static const _labels = ['首页', '排行', '书架', '我的'];
  static const _icons = [
    (Icons.home_outlined, Icons.home_rounded),
    (Icons.leaderboard_outlined, Icons.leaderboard_rounded),
    (Icons.menu_book_outlined, Icons.menu_book_rounded),
    (Icons.person_outline_rounded, Icons.person_rounded),
  ];

  void _select(int i) => setState(() {
        _index = i;
        _visited.add(i);
      });

  @override
  Widget build(BuildContext context) {
    // 窄屏（安卓尺寸）：底部菜单；宽屏：左侧可收缩菜单
    if (MediaQuery.sizeOf(context).width < kNarrowBreakpoint) {
      return Scaffold(
        body: _pages(),
        bottomNavigationBar: _BottomTabBar(
          index: _index,
          labels: _labels,
          icons: _icons,
          onSelect: _select,
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          _SideRail(
            index: _index,
            open: _railOpen,
            labels: _labels,
            icons: _icons,
            onSelect: _select,
            onToggle: () => setState(() => _railOpen = !_railOpen),
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: _pages()),
        ],
      ),
    );
  }
}

/// 底部 4 Tab（效果图 .tabbar：高 60、图标 19、字 10.5，选中墨绿加粗）。
class _BottomTabBar extends StatelessWidget {
  const _BottomTabBar({
    required this.index,
    required this.labels,
    required this.icons,
    required this.onSelect,
  });

  final int index;
  final List<String> labels;
  final List<(IconData, IconData)> icons;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottomInset = MediaQuery.viewPaddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.only(bottom: bottomInset),
      decoration: BoxDecoration(
        color: Brand.card(context).withValues(alpha: 0.94),
        border: Border(top: BorderSide(color: Brand.hair(context))),
      ),
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            for (var i = 0; i < labels.length; i++)
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => onSelect(i),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        index == i ? icons[i].$2 : icons[i].$1,
                        size: 19,
                        color: index == i
                            ? Brand.green
                            : Brand.fg3(context),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        labels[i],
                        style: theme.textTheme.labelSmall?.copyWith(
                          fontSize: 10.5,
                          color: index == i
                              ? Brand.green
                              : Brand.fg3(context),
                          fontWeight: index == i
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 宽屏左侧栏（效果图 .drail：收起 88 / 展开 210，选中项墨绿软底）。
class _SideRail extends StatelessWidget {
  const _SideRail({
    required this.index,
    required this.open,
    required this.labels,
    required this.icons,
    required this.onSelect,
    required this.onToggle,
  });

  final int index;
  final bool open;
  final List<String> labels;
  final List<(IconData, IconData)> icons;
  final ValueChanged<int> onSelect;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final activeBg =
        dark ? Brand.green.withValues(alpha: 0.16) : Brand.greenSoft;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: open ? 210 : 88,
      color: theme.scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 58,
            child: Row(
              mainAxisAlignment:
                  open ? MainAxisAlignment.start : MainAxisAlignment.center,
              children: [
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(open ? Icons.menu_open : Icons.menu,
                      size: 20, color: Brand.fg3(context)),
                  tooltip: open ? '收起菜单' : '展开菜单',
                  onPressed: onToggle,
                ),
                if (open) ...[
                  const SizedBox(width: 2),
                  const Mascot(size: 24),
                  const SizedBox(width: 8),
                  Text('爽阅',
                      style: theme.textTheme.titleMedium
                          ?.copyWith(fontWeight: FontWeight.w800)),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),
          for (var i = 0; i < labels.length; i++)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onSelect(i),
                child: Container(
                  height: 58,
                  decoration: BoxDecoration(
                    color: index == i ? activeBg : null,
                    borderRadius: BorderRadius.circular(13),
                  ),
                  child: open
                      ? Row(
                          children: [
                            const SizedBox(width: 16),
                            Icon(
                              index == i ? icons[i].$2 : icons[i].$1,
                              size: 20,
                              color: index == i
                                  ? Brand.green
                                  : Brand.fg3(context),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              labels[i],
                              style: theme.textTheme.bodyMedium?.copyWith(
                                fontSize: 13.5,
                                fontWeight: index == i
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: index == i
                                    ? Brand.green
                                    : theme.hintColor,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              index == i ? icons[i].$2 : icons[i].$1,
                              size: 20,
                              color: index == i
                                  ? Brand.green
                                  : Brand.fg3(context),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              labels[i],
                              style: theme.textTheme.labelSmall?.copyWith(
                                fontSize: 10.5,
                                fontWeight: index == i
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: index == i
                                    ? Brand.green
                                    : Brand.fg3(context),
                              ),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          const Spacer(),
        ],
      ),
    );
  }
}
