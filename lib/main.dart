import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import 'announcement.dart';
import 'data/stats_store.dart';
import 'feed_cache.dart';
import 'legado/source_store.dart';
import 'legado/webview_engine.dart';
import 'screens/discover_screen.dart';
import 'screens/search_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/shelf_screen.dart';
import 'sources/registry.dart';
import 'store.dart';
import 'theme.dart';
import 'title_bar.dart';
import 'ui/storage_gate.dart';
import 'update_check.dart';

/// 宽/窄屏分界（逻辑像素）：<= 视为安卓尺寸（底部菜单 + 缩放生效），> 为宽屏（左侧菜单不缩放）。
const double kNarrowBreakpoint = 720;

/// 崩溃兜底：写入临时目录日志，避免未捕获异常直接杀进程。
void _logCrash(Object e, StackTrace s) {
  try {
    final f = File('${Directory.systemTemp.path}/novel_reader_crash.log');
    f.writeAsStringSync('==== ${DateTime.now()} ====\n$e\n$s\n\n',
        mode: FileMode.append);
  } catch (_) {}
}

Future<void> main(List<String> args) async {
  // 启动标记：崩溃定位用（存在 = Dart 已进入 main）
  try {
    File('${Directory.systemTemp.path}/nr_boot.txt')
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
  try {
    await AppStore.I.init();
  } catch (_) {
    // 个别环境（权限/杀软拦截）下偏好初始化失败时不阻塞启动，降级为无持久化运行
  }
  try {
    await FeedCache.init(); // 首页/排行/搜索磁盘缓存，二次打开免重新拉取
  } catch (_) {}
  try {
    await StatsStore.I.load(); // 阅读统计（时长 / 连续天数 / 最近 7 天）
  } catch (_) {}
  try {
    // 「阅读 3.0」书源：先补内置源，再把用户启用的源登记进 allSources。
    // 失败不阻塞启动 —— 11 个固化书源照常可用。
    final sources = SourceStore();
    await sources.load();
    await sources.ensureBuiltinSources();
    SourceStore.shared = sources;
    syncImportedSources(sources.enabled);
    sources.addListener(() => syncImportedSources(sources.enabled));
  } catch (_) {}
  runApp(const NovelApp());
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
      // 状态栏/导航栏底色与主题背景一致（锦绣白/极光黑），图标随明暗反转
      final bg = AppThemes.scaffold(_theme);
      SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
        statusBarColor: bg,
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
      // 正常模式 padding 已带状态栏高度；edge-to-edge 时 padding=0、
      // 高度落在 viewPadding，手动补上，保证顶部操作不被状态栏挡住。
      // 顶缝先铺主题底色：状态栏区域（含 edge-to-edge 透传）与应用同色。
      final top = mq.padding.top > 0 ? 0.0 : mq.viewPadding.top;
      app = ColoredBox(
        color: AppThemes.scaffold(_theme),
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: SafeArea(top: true, bottom: false, child: app),
        ),
      );
    }
    // 隐藏 WebView 宿主（1×1，仅 Android 且引擎激活后才构建）：
    // 放在最外层保证跨路由存活，Windows 上自动透传。
    app = WebViewEngineHost(child: app);
    return MediaQuery(data: mq, child: app);
  }
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;
  bool _railOpen = false; // 宽屏侧边菜单展开/收起
  Timer? _noticePoll; // 实时公告轮询

  @override
  void initState() {
    super.initState();
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
        children: const [
          ShelfScreen(),
          DiscoverScreen(),
          SearchScreen(),
          SettingsScreen(),
        ],
      );

  static const _labels = ['书架', '发现', '搜索', '设置'];
  static const _icons = [
    (Icons.book_outlined, Icons.book),
    (Icons.explore_outlined, Icons.explore),
    (Icons.search, Icons.search),
    (Icons.settings_outlined, Icons.settings),
  ];

  void _select(int i) => setState(() => _index = i);

  @override
  Widget build(BuildContext context) {
    // 窄屏（安卓尺寸）：底部菜单；宽屏：左侧可收缩菜单
    if (MediaQuery.sizeOf(context).width < kNarrowBreakpoint) {
      return Scaffold(
        body: _pages(),
        bottomNavigationBar: NavigationBar(
          selectedIndex: _index,
          onDestinationSelected: _select,
          destinations: [
            for (var i = 0; i < _labels.length; i++)
              NavigationDestination(
                icon: Icon(_icons[i].$1),
                selectedIcon: Icon(_icons[i].$2),
                label: _labels[i],
              ),
          ],
        ),
      );
    }
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _index,
            onDestinationSelected: _select,
            extended: _railOpen,
            leading: IconButton(
              icon: Icon(_railOpen ? Icons.menu_open : Icons.menu),
              tooltip: _railOpen ? '收起菜单' : '展开菜单',
              onPressed: () => setState(() => _railOpen = !_railOpen),
            ),
            destinations: [
              for (var i = 0; i < _labels.length; i++)
                NavigationRailDestination(
                  icon: Icon(_icons[i].$1),
                  selectedIcon: Icon(_icons[i].$2),
                  label: Text(_labels[i]),
                ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(child: _pages()),
        ],
      ),
    );
  }
}
