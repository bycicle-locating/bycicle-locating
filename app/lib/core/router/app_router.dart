import 'package:flutter/cupertino.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../session.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_page.dart';
import '../../features/device/pairing/pairing_page.dart';
import '../../features/device/presentation/device_page.dart';
import '../../features/map/presentation/map_page.dart';
import '../../features/ride/presentation/ride_list_page.dart';
import '../../features/settings/presentation/settings_page.dart';
import 'main_shell.dart';

/// 路由表。
///
/// `/bind?d=&c=` 必须保留：NFC 标签里写的就是这个 URI，
/// iOS 锁屏触碰与 Android 都靠它直接唤起 App 到绑定页（pairing.md §2）。
final appRouterProvider = Provider<GoRouter>((ref) {
  final refresh = ValueNotifier<int>(0);
  ref.listen(sessionProvider, (_, next) => refresh.value++);
  String? pendingBind;
  final router = GoRouter(
    refreshListenable: refresh,
    redirect: (context, state) {
      final session = ref.read(sessionProvider);
      final signedIn = !session.isLoading &&
          !session.hasError &&
          session.valueOrNull != null;
      if (!signedIn) {
        if (state.uri.path == '/bind') pendingBind = state.uri.toString();
        return state.uri.path == '/login' ? null : '/login';
      }
      if (state.uri.path == '/login') {
        final destination = pendingBind ?? '/map';
        pendingBind = null;
        return destination;
      }
      return null;
    },
    initialLocation: '/map',
    routes: [
      StatefulShellRoute.indexedStack(
        builder: (context, state, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        branches: [
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/map',
                pageBuilder: (context, state) => NoTransitionPage(
                    key: state.pageKey, child: const MapPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/rides',
                pageBuilder: (context, state) => NoTransitionPage(
                    key: state.pageKey, child: const RideListPage()),
              ),
            ],
          ),
          StatefulShellBranch(
            routes: [
              GoRoute(
                path: '/settings',
                pageBuilder: (context, state) => NoTransitionPage(
                    key: state.pageKey, child: const SettingsPage()),
              ),
            ],
          ),
        ],
      ),
      GoRoute(
        path: '/device',
        pageBuilder: (context, state) =>
            floatingRoute(state, const DevicePage()),
      ),
      GoRoute(
        path: '/device/pair',
        pageBuilder: (context, state) =>
            floatingRoute(state, const PairingPage()),
      ),
      GoRoute(
        path: '/bind',
        pageBuilder: (context, state) => floatingRoute(
            state,
            PairingPage(
              initialDeviceId: state.uri.queryParameters['d'],
              initialClaimCode: state.uri.queryParameters['c'],
            )),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
    ],
  );
  ref.onDispose(() {
    router.dispose();
    refresh.dispose();
  });
  return router;
});

CustomTransitionPage<void> floatingRoute(GoRouterState state, Widget child) =>
    CustomTransitionPage<void>(
      key: state.pageKey,
      opaque: false,
      barrierDismissible: false,
      barrierColor: const Color(0x44000000),
      transitionDuration: const Duration(milliseconds: 280),
      reverseTransitionDuration: const Duration(milliseconds: 220),
      child: child,
      transitionsBuilder: (context, animation, secondary, child) {
        if (MediaQuery.disableAnimationsOf(context)) return child;
        final curve = CurvedAnimation(
            parent: animation,
            curve: Curves.easeOutCubic,
            reverseCurve: Curves.easeInCubic);
        return FadeTransition(
            opacity: curve,
            child: SlideTransition(
                position: Tween(begin: const Offset(0, .06), end: Offset.zero)
                    .animate(curve),
                child: child));
      },
    );
