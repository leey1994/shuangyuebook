// 开屏的回归测试。
//
// 开屏是个纯装饰的等待页，但它坏了很难定位：报错的栈落在
// MaterialApp.builder 里，看不出是开屏没走完还是首页没起来。
// 锁四件事：铺满、到点会走、横竖版选对、提前销毁时 Timer 被撤掉。
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/ui/splash_gate.dart';

const _app = Text('APP');

Widget harness({Duration d = const Duration(milliseconds: 900), Size? size}) {
  final gate = SplashGate(
    minDuration: d,
    child: const MaterialApp(home: _app),
  );
  return size == null
      ? gate
      : MediaQuery(data: MediaQueryData(size: size), child: gate);
}

void main() {
  testWidgets('铺满整个窗口 —— 上面那条不能漏出别的东西', (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(harness());
    await tester.pump();

    final box = tester.getSize(find.byType(SplashGate));
    expect(box, const Size(1280, 800));

    // 底色铺满：图没铺满的地方不能透出底下（桌面端标题栏就在底下）
    final bg = tester.getRect(find.byType(ColoredBox).first);
    expect(bg.top, 0.0);
    expect(bg.height, box.height);

    // 图居中，且完整落在窗口内
    final img = tester.getRect(find.byType(Image));
    expect(img.left, greaterThanOrEqualTo(0.0));
    expect(img.right, lessThanOrEqualTo(box.width));
    expect((img.center.dx - box.width / 2).abs(), lessThan(1.0));
  });

  testWidgets('到点后换成真正的应用', (tester) async {
    await tester.pumpWidget(harness());
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('APP'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(Image), findsOneWidget, reason: '还没到停留时长');

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(Image), findsNothing);
    await tester.pump();
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('零时长也走一次事件循环，不会首帧空白', (tester) async {
    await tester.pumpWidget(harness(d: Duration.zero));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget, reason: '零时长时首帧仍应是开屏');
    await tester.pumpAndSettle();
    expect(find.text('APP'), findsOneWidget);
  });

  testWidgets('开屏期间被换掉时不再 setState', (tester) async {
    await tester.pumpWidget(harness(d: const Duration(seconds: 5)));
    expect(find.byType(Image), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Text('REPLACED')));
    expect(find.text('REPLACED'), findsOneWidget);

    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull,
        reason: 'Timer 若没在 dispose 撤掉，回调会打在已销毁的 State 上');
  });

  group('横竖版选图', () {
    final desktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;

    test('桌面端固定横版，不管窗口被拖成什么样', () {
      const wide = 'assets/brand/splash-landscape.png';
      expect(SplashGate.assetFor(landscape: true, desktop: true), wide);
      expect(SplashGate.assetFor(landscape: false, desktop: true), wide,
          reason: '窗口被拖成竖条时也不能切回竖版图');
    });

    test('移动端按屏幕方向切', () {
      expect(SplashGate.assetFor(landscape: false, desktop: false),
          'assets/brand/splash-portrait.png');
      expect(SplashGate.assetFor(landscape: true, desktop: false),
          'assets/brand/splash-landscape.png');
    });

    testWidgets('实际渲染用的图跟 desktop 标记一致', (tester) async {
      await tester.pumpWidget(harness(size: const Size(400, 900)));
      await tester.pump();
      final img = tester.widget<Image>(find.byType(Image));
      expect(
        img.image as AssetImage,
        AssetImage(SplashGate.assetFor(landscape: false, desktop: desktop)),
      );
    });
  });
}
