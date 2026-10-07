import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:novel_reader/widgets.dart';

/// 横向滚动容器（书架两行网格 / 排行标签等桌面横划）：
/// 验证鼠标拖拽可右划、纵向滚轮转横移生效。
void main() {
  Widget host() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 300,
            child: HScrollView(
              builder: (context, controller) => GridView.builder(
                controller: controller,
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.all(8),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  mainAxisSpacing: 10,
                  crossAxisSpacing: 10,
                  mainAxisExtent: 124,
                ),
                itemCount: 36,
                itemBuilder: (_, i) => Center(child: Text('B$i')),
              ),
            ),
          ),
        ),
      );

  ScrollPosition pos(WidgetTester t) =>
      t.state<ScrollableState>(find.byType(Scrollable).first).position;

  testWidgets('鼠标拖拽可右划', (t) async {
    await t.pumpWidget(host());
    expect(pos(t).pixels, 0);
    await t.drag(find.byType(GridView), const Offset(-300, 0));
    await t.pumpAndSettle();
    expect(pos(t).pixels, greaterThan(0));
  });

  testWidgets('纵向滚轮转横向滚动', (t) async {
    await t.pumpWidget(host());
    final center = t.getCenter(find.byType(GridView));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(pointer.hover(center));
    await t.sendEventToBinding(PointerScrollEvent(
        position: center, scrollDelta: const Offset(0, -120)));
    await t.pump();
    expect(pos(t).pixels, greaterThan(0));
  });
}
