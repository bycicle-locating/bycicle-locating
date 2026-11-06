import 'package:bkl_app/app.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('一级 tab 与绑定入口可用', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(const ProviderScope(child: BklApp()));
    await tester.pumpAndSettle();

    expect(find.text('我的车'), findsOneWidget);
    expect(find.text('地图'), findsOneWidget);
    expect(find.text('骑行'), findsOneWidget);
    expect(find.text('车辆'), findsOneWidget);

    await tester.tap(find.text('车辆'));
    await tester.pumpAndSettle();
    expect(find.text('尚未绑定车辆'), findsOneWidget);

    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();
    expect(find.text('我的车'), findsOneWidget);

    await tester.tap(find.text('绑定设备'));
    await tester.pumpAndSettle();
    expect(find.text('触碰标签完成绑定'), findsOneWidget);
    expect(find.text('确认绑定'), findsOneWidget);
  });
}
