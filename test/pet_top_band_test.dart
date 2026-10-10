// 安卓顶部几何的回归测试。
//
// 为什么单独测：顶部高度栽过两次（状态栏 + 窄带两条叠加，看着像被顶下去了），
// 而真机不一定在手边。这块只能靠断言，不能靠推理。
//
// 同时守住另一件事：edge-to-edge 下 padding.top 恒为 0，高度只在 viewPadding 上，
// captureSystemInsets 必须两个都看，否则窄带会退化成 26px 兜底值、和真机对不上。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/pet/pet_view.dart';
import 'package:novel_reader/ui/pet_top_band.dart';
import 'package:novel_reader/ui/system_metrics.dart';

/// 典型机型：1080p 约 28~32 逻辑像素
const double kStatusBar = 28.0;

/// 不套 MaterialApp —— 它会用自己的 MediaQuery 覆盖掉我们给的。
/// 手工补齐 Directionality / Localizations 就够画出窄带与内容了。
/// 测试面尺寸：与 [harness] 的 MediaQuery 保持一致，
/// 否则布局拿到的是 600x800 的默认面，断言全对不上。
const Size kSurface = Size(400, 800);

void useSurface(WidgetTester tester) {
  tester.view.physicalSize = kSurface;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

Widget harness({
  required Widget child,
  Size size = kSurface,
  EdgeInsets viewPadding = EdgeInsets.zero,
}) {
  return Localizations(
    locale: const Locale('zh', 'CN'),
    delegates: const [
      DefaultMaterialLocalizations.delegate,
      DefaultWidgetsLocalizations.delegate,
    ],
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: MediaQueryData(size: size, viewPadding: viewPadding),
        child: child,
      ),
    ),
  );
}

Widget band(double h,
        {Key? bodyKey, Color background = const Color(0xFFFFFFFF)}) =>
    PetTopBand(
      band: h,
      background: background,
      child: SizedBox.expand(key: bodyKey ?? const Key('body')),
    );

/// 在给定 MediaQuery 下跑一次 [captureSystemInsets]。
/// 注意不能用 [harness]：它会自建一个 MediaQuery，把这里传进去的 data 盖掉。
Future<void> capture(WidgetTester tester, MediaQueryData data) async {
  await tester.pumpWidget(Localizations(
    locale: const Locale('zh', 'CN'),
    delegates: const [
      DefaultMaterialLocalizations.delegate,
      DefaultWidgetsLocalizations.delegate,
    ],
    child: Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: data,
        child: Builder(builder: (context) {
          captureSystemInsets(context);
          return const SizedBox.shrink();
        }),
      ),
    ),
  ));
  await tester.pump();
}

/// PetBar 在 initState 里起了几个 Timer，必须把树拆掉让 dispose 跑完，
/// 否则测试结束时会以「Timer 还在」失败。
Future<void> disposeTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  group('顶部窄带的几何', () {
    testWidgets('窄带就是状态栏那一行，内容只往下让一个 inset', (tester) async {
      useSurface(tester);
      await tester.pumpWidget(harness(child: band(kStatusBar)));
      await tester.pump();

      // 窄带顶到屏幕最上沿
      expect(tester.getTopLeft(find.byType(PetBar)).dy, 0.0,
          reason: '窄带必须从 y=0 开始，紧贴屏幕顶部');

      // 窄带高度正好等于状态栏高度
      expect(tester.getSize(find.byType(PetBar)).height, kStatusBar);

      // 内容从「一个 inset」开始 —— 不是两条叠加
      expect(tester.getTopLeft(find.byKey(const Key('body'))).dy, kStatusBar,
          reason: '内容只该被状态栏高度挡住；'
              '若等于「状态栏+窄带」，说明又变成两条叠加了');
      await disposeTree(tester);
    });

    testWidgets('窄带与内容首尾相接，中间没有空隙', (tester) async {
      useSurface(tester);
      await tester.pumpWidget(harness(child: band(kStatusBar)));
      await tester.pump();

      final b = tester.getRect(find.byType(PetBar));
      final body = tester.getRect(find.byKey(const Key('body')));
      expect(b.bottom, body.top);
      expect(b.height + body.height, 800);
      await disposeTree(tester);
    });

    testWidgets('窄带随状态栏高度变化，不是写死的 26px', (tester) async {
      for (final h in const [24.0, 28.0, 32.0, 40.0]) {
        useSurface(tester);
        await tester.pumpWidget(harness(child: band(h)));
        await tester.pump();
        expect(tester.getSize(find.byType(PetBar)).height, h);
        expect(tester.getTopLeft(find.byKey(const Key('body'))).dy, h);
        await disposeTree(tester);
      }
    });
  });

  group('captureSystemInsets', () {
    setUp(() {
      SystemMetrics.topInset = 0;
      SystemMetrics.bottomInset = 0;
    });

    testWidgets('edge-to-edge：padding.top=0 时从 viewPadding 取', (tester) async {
      useSurface(tester);
      await capture(
        tester,
        const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.zero,
          viewPadding: EdgeInsets.only(top: kStatusBar, bottom: 24),
        ),
      );
      expect(SystemMetrics.topInset, kStatusBar);
      expect(SystemMetrics.bottomInset, 24);
    });

    testWidgets('非 edge-to-edge：padding 里有值就用 padding', (tester) async {
      useSurface(tester);
      await capture(
        tester,
        const MediaQueryData(
          size: Size(400, 800),
          padding: EdgeInsets.only(top: kStatusBar, bottom: 48),
          viewPadding: EdgeInsets.only(top: kStatusBar, bottom: 48),
        ),
      );
      expect(SystemMetrics.topInset, kStatusBar);
      expect(SystemMetrics.bottomInset, 48);
    });

    testWidgets('只增不减：冷启动首帧抖动不会被小值拉低', (tester) async {
      useSurface(tester);
      await capture(
        tester,
        const MediaQueryData(
          size: Size(400, 800),
          viewPadding: EdgeInsets.only(top: kStatusBar),
        ),
      );
      await capture(
        tester,
        const MediaQueryData(
            size: Size(400, 800), viewPadding: EdgeInsets.zero),
      );
      expect(SystemMetrics.topInset, kStatusBar);
    });
  });

  group('窄带高度来源', () {
    test('量到真机高度就用它，量不到才回落到兜底值', () {
      SystemMetrics.topInset = kStatusBar;
      expect(PetBar.defaultHeight(), kStatusBar,
          reason: '安卓必须跟真机状态栏一致，否则顶部对不齐');
      SystemMetrics.topInset = 0;
      expect(PetBar.defaultHeight(), PetBar.fallbackHeight);
      SystemMetrics.topInset = 0;
    });
  });

  group('窄带底色跟随阅读背景', () {
    tearDown(() => petBandBackground.value = null);

    testWidgets('默认用主题底色', (tester) async {
      useSurface(tester);
      await tester.pumpWidget(harness(
          child: band(kStatusBar, background: const Color(0xFFF6F7F9))));
      await tester.pump();
      final box = tester.widget<ColoredBox>(find.descendant(
          of: find.byType(PetTopBand), matching: find.byType(ColoredBox)));
      expect(box.color, const Color(0xFFF6F7F9));
      await disposeTree(tester);
    });

    testWidgets('阅读器可覆盖成阅读背景色（否则顶部一条割裂色带）', (tester) async {
      useSurface(tester);
      await tester.pumpWidget(harness(
          child: band(kStatusBar, background: const Color(0xFFF6F7F9))));
      await tester.pump();

      const readingBg = Color(0xFFF3E9D2); // 米黄阅读背景
      petBandBackground.value = readingBg;
      await tester.pump();

      final box = tester.widget<ColoredBox>(find.descendant(
          of: find.byType(PetTopBand), matching: find.byType(ColoredBox)));
      expect(box.color, readingBg);
      await disposeTree(tester);
    });

    testWidgets('离开阅读器后（置回 null）恢复主题底色', (tester) async {
      useSurface(tester);
      await tester.pumpWidget(harness(
          child: band(kStatusBar, background: const Color(0xFFF6F7F9))));
      await tester.pump();
      petBandBackground.value = const Color(0xFF1A1A1A);
      await tester.pump();
      petBandBackground.value = null;
      await tester.pump();

      final box = tester.widget<ColoredBox>(find.descendant(
          of: find.byType(PetTopBand), matching: find.byType(ColoredBox)));
      expect(box.color, const Color(0xFFF6F7F9));
      await disposeTree(tester);
    });
  });
}
