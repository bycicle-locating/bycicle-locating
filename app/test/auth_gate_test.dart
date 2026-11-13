import 'package:bkl_app/app.dart';
import 'package:bkl_app/core/router/app_router.dart';
import 'package:bkl_app/core/session.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

class TestSession extends SessionController {
  @override
  Future<String?> build() async => null;

  void signIn() => state = const AsyncData('test');
  void signOut() => state = const AsyncData(null);
}

void main() {
  testWidgets('未登录时所有业务路由均跳到登录页', (tester) async {
    final container = ProviderContainer(overrides: [
      sessionProvider.overrideWith(TestSession.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const BklApp(),
    ));
    await tester.pumpAndSettle();
    final router = container.read(appRouterProvider);
    for (final path in [
      '/map',
      '/rides',
      '/device',
      '/settings',
      '/device/pair'
    ]) {
      router.go(path);
      await tester.pumpAndSettle();
      expect(router.routeInformationProvider.value.uri.path, '/login');
      expect(find.text('地图'), findsNothing);
      expect(find.byType(CupertinoTextField), findsNWidgets(2));
    }
  });

  testWidgets('绑定深链登录后恢复，退出后回登录页', (tester) async {
    final container = ProviderContainer(overrides: [
      sessionProvider.overrideWith(TestSession.new),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const BklApp(),
    ));
    await tester.pumpAndSettle();
    final router = container.read(appRouterProvider);
    router.go('/bind?d=BKL-2026-000123&c=7QK2M5XJ4TZP6RWN');
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/login');
    final session = container.read(sessionProvider.notifier) as TestSession;
    session.signIn();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/bind');
    expect(
        tester
            .widget<CupertinoTextField>(find.byType(CupertinoTextField).first)
            .controller!
            .text,
        'BKL-2026-000123');
    session.signOut();
    await tester.pumpAndSettle();
    expect(router.routeInformationProvider.value.uri.path, '/login');
    expect(find.text('确认绑定'), findsNothing);
  });
}
