import 'package:bkl_app/app.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> _pumpApp(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(const ProviderScope(child: BklApp()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('一级 tab、绑定入口与返回可用', (tester) async {
    await _pumpApp(tester);

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

    final submit = find.widgetWithText(CupertinoButton, '确认绑定');
    expect(tester.widget<CupertinoButton>(submit).onPressed, isNull);

    await tester.enterText(
      find.byType(CupertinoTextField).at(0),
      'BKL-2026-000123',
    );
    await tester.enterText(
      find.byType(CupertinoTextField).at(1),
      'ABCDEFGHJKLMNPQR',
    );
    await tester.pump();
    expect(tester.widget<CupertinoButton>(submit).onPressed, isNotNull);

    await tester.tap(find.byType(CupertinoNavigationBarBackButton));
    await tester.pumpAndSettle();
    expect(find.text('我的车'), findsOneWidget);
  });

  testWidgets('深色模式下可渲染一级页面', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await _pumpApp(tester);

    expect(find.text('我的车'), findsOneWidget);
    await tester.tap(find.text('车辆'));
    await tester.pumpAndSettle();
    expect(find.text('尚未绑定车辆'), findsOneWidget);
  });
}
