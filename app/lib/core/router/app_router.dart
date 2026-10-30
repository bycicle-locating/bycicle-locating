import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/presentation/login_page.dart';
import '../../features/device/pairing/pairing_page.dart';
import '../../features/device/presentation/device_page.dart';
import '../../features/map/presentation/map_page.dart';
import '../../features/ride/presentation/ride_list_page.dart';
import '../../features/settings/presentation/settings_page.dart';

/// 路由表。
///
/// `/bind?d=&c=` 必须保留：NFC 标签里写的就是这个 URI，
/// iOS 锁屏触碰与 Android 都靠它直接唤起 App 到绑定页（pairing.md §2）。
final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/map',
    routes: [
      GoRoute(
        path: '/map',
        builder: (context, state) => const MapPage(),
      ),
      GoRoute(
        path: '/rides',
        builder: (context, state) => const RideListPage(),
      ),
      GoRoute(
        path: '/device',
        builder: (context, state) => const DevicePage(),
      ),
      GoRoute(
        path: '/device/pair',
        builder: (context, state) => const PairingPage(),
      ),
      GoRoute(
        path: '/bind',
        builder: (context, state) => PairingPage(
          initialDeviceId: state.uri.queryParameters['d'],
          initialClaimCode: state.uri.queryParameters['c'],
        ),
      ),
      GoRoute(
        path: '/login',
        builder: (context, state) => const LoginPage(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsPage(),
      ),
    ],
  );
});
