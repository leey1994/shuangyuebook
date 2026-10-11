// 开屏页的回归测试。
//
// 开屏是个纯装饰的等待页，但它一旦坏了很难定位：报错的栈在
// pushReplacement 之后，看不出是开屏没走完还是首页没起来。
// 所以只锁三件事：图在、到点会走、页面提前销毁时不会再 push。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/ui/splash_screen.dart';

void main() {
  testWidgets('开屏显示宣传语图，到点后切到主界面', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SplashScreen(next: Text('HOME'), minDuration: Duration(milliseconds: 900)),
    ));

    // 图先在
    expect(find.byType(Image), findsOneWidget);
    expect(find.text('HOME'), findsNothing);

    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(Image), findsOneWidget, reason: '还没到停留时长，不该切走');

    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget, reason: '到点后必须进主界面');
  });

  testWidgets('minDuration 为零时立即切走', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: SplashScreen(next: Text('HOME'), minDuration: Duration.zero),
    ));
    await tester.pumpAndSettle();
    expect(find.text('HOME'), findsOneWidget);
  });

  testWidgets('开屏期间被销毁时不再压路由', (tester) async {
    // 模拟系统返回 / 热重启：开屏挂上去后被整棵树换掉。
    // Timer 若没在 dispose 撤掉，回调会往已销毁的 context 上 pushReplacement，
    // 抛的断言只会指向 navigator，看不出跟开屏有关。
    await tester.pumpWidget(const MaterialApp(
      home: SplashScreen(next: Text('HOME'), minDuration: Duration(seconds: 5)),
    ));
    expect(find.byType(Image), findsOneWidget);

    await tester.pumpWidget(const MaterialApp(home: Text('REPLACED')));
    expect(find.text('REPLACED'), findsOneWidget);

    // 越过原本的停留时长，撤掉的 Timer 不该再有任何动静
    await tester.pump(const Duration(seconds: 6));
    expect(tester.takeException(), isNull);
    expect(find.text('HOME'), findsNothing);
  });
}