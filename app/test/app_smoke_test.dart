import 'package:bkl_app/app.dart';
import 'package:bkl_app/core/api/api_client.dart';
import 'package:bkl_app/core/session.dart';
import 'package:bkl_app/core/providers.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class SignedInSession extends SessionController {
  @override
  Future<String?> build() async => 'test-token';
}

class BindFailApi extends ApiClient {
  @override
  Future<DeviceView> bindDevice(
          {required String deviceId,
          required String claimCode,
          String? label}) async =>
      throw ApiException('绑定失败测试');
}

Future<void> _pumpApp(WidgetTester tester,
    {Size size = const Size(1080, 2400),
    double textScale = 1,
    List<Override> overrides = const []}) async {
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  await tester.pumpWidget(ProviderScope(overrides: [
    sessionProvider.overrideWith(SignedInSession.new),
    devicesProvider.overrideWith((ref) async => []),
    ...overrides,
  ], child: const BklApp()));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('面板各档位和标签使用相同标题字号与对齐', (tester) async {
    await _pumpApp(tester);
    final sheet = tester.widget<DraggableScrollableSheet>(
        find.byType(DraggableScrollableSheet));
    final controller = sheet.controller!;
    final heading = find.text('我的车');
    final style = tester.widget<Text>(heading).style;
    final left = tester.getTopLeft(heading).dx;
    for (final extent in [sheet.minChildSize, .5, .94]) {
      controller.jumpTo(extent);
      await tester.pumpAndSettle();
      expect(tester.widget<Text>(heading).style, style);
      expect(tester.getTopLeft(heading).dx, left);
      expect(heading.hitTestable(), findsOneWidget);
      expect(find.text('地图').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
    for (final tab in ['骑行', '设置']) {
      await tester.tap(find.text(tab).last);
      await tester.pumpAndSettle();
      final title = find.text(tab == '骑行' ? '骑行记录' : '设置').first;
      expect(tester.widget<Text>(title).style, style);
      expect(tester.getTopLeft(title).dx, left);
      expect(controller.size, closeTo(.94, .01));
    }
  });
  for (final size in [const Size(360, 640), const Size(640, 360)]) {
    testWidgets('布局适应 $size 和两倍字号', (tester) async {
      await _pumpApp(tester, size: size, textScale: 2);
      for (final tab in ['设置', '骑行', '地图']) {
        await tester.tap(find.text(tab).last);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }
      final handle = find.byWidgetPredicate((widget) =>
          widget is Semantics && widget.properties.label == '展开或收起面板');
      await tester.tap(handle);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('面板把手上拉展开，导航切换后仍可收起', (tester) async {
    await _pumpApp(tester);
    final sheet = tester
        .widget<DraggableScrollableSheet>(find.byType(DraggableScrollableSheet))
        .controller!;
    expect(sheet.size, closeTo(.5, .01));
    final handle = find.byWidgetPredicate((widget) =>
        widget is Semantics && widget.properties.label == '展开或收起面板');
    await tester.drag(handle, const Offset(0, -900));
    await tester.pumpAndSettle();
    expect(sheet.size, closeTo(.94, .01));
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    await tester.tap(handle);
    await tester.pumpAndSettle();
    expect(sheet.size, closeTo(.5, .01));
    expect(tester.takeException(), isNull);
  });

  testWidgets('一级 tab、绑定入口与返回可用', (tester) async {
    await _pumpApp(tester);

    expect(find.text('我的车'), findsOneWidget);
    expect(find.text('地图'), findsOneWidget);
    expect(find.text('骑行'), findsOneWidget);
    expect(find.text('设置'), findsOneWidget);

    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录'), findsOneWidget);

    await tester.tap(find.text('地图'));
    await tester.pumpAndSettle();
    expect(find.text('我的车'), findsOneWidget);

    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is Icon && widget.semanticLabel == '绑定设备'));
    await tester.pumpAndSettle();
    expect(find.text('添加你的车辆'), findsOneWidget);

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

    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is Icon && widget.semanticLabel == '关闭'));
    await tester.pumpAndSettle();
    expect(find.text('我的车'), findsOneWidget);
  });

  testWidgets('深色模式下可渲染一级页面', (tester) async {
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

    await _pumpApp(tester);

    expect(find.text('我的车'), findsOneWidget);
    await tester.tap(find.text('设置'));
    await tester.pumpAndSettle();
    expect(find.text('退出登录'), findsOneWidget);
  });

  testWidgets('绑定失败显示错误并保留输入', (tester) async {
    await _pumpApp(tester, overrides: [
      apiClientProvider.overrideWith((ref) => BindFailApi()),
    ]);
    await tester.tap(find.byWidgetPredicate(
        (widget) => widget is Icon && widget.semanticLabel == '绑定设备'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byType(CupertinoTextField).at(0), 'BKL-2026-000123');
    await tester.enterText(
        find.byType(CupertinoTextField).at(1), 'ABCDEFGHJKLMNPQR');
    await tester.pump();
    await tester.tap(find.widgetWithText(CupertinoButton, '确认绑定'));
    await tester.pumpAndSettle();

    expect(find.text('绑定失败测试'), findsOneWidget);
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).at(0))
            .controller!
            .text,
        'BKL-2026-000123');
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).at(1))
            .controller!
            .text,
        'ABCDEFGHJKLMNPQR');
    expect(find.text('添加你的车辆'), findsOneWidget);
  });
}
