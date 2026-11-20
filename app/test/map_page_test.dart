import 'dart:async';
import 'dart:convert';

import 'package:bkl_app/core/api/api_client.dart';
import 'package:bkl_app/core/providers.dart';
import 'package:bkl_app/core/router/app_router.dart' show floatingRoute;
import 'package:bkl_app/core/router/main_shell.dart';
import 'package:bkl_app/core/session.dart';
import 'package:bkl_app/core/theme/app_surface.dart';
import 'package:bkl_app/features/device/presentation/device_page.dart';
import 'package:bkl_app/features/map/presentation/map_backdrop.dart';
import 'package:bkl_app/features/map/presentation/map_page.dart';
import 'package:bkl_app/features/ride/presentation/ride_list_page.dart';
import 'package:bkl_app/features/settings/presentation/settings_page.dart';
import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:latlong2/latlong.dart';

const _device = DeviceView(
    id: 'BKL-2026-990001', model: 'BKL1', state: 'CLAIMED', bound: true);

DeviceTrackPoint _point(int seq, {double speed = 5, double? latitude}) =>
    DeviceTrackPoint(
      deviceId: _device.id,
      seq: seq,
      ts: DateTime.utc(2026, 11, 20, 7, 10, seq),
      lat: latitude ?? 31.23 + seq * .0001,
      lon: 121.47,
      speedMps: speed,
      courseDeg: 90,
      fix: 3,
    );

class _TestSession extends SessionController {
  @override
  Future<String?> build() async => 'first-test-session';

  void change(String? token) => state = AsyncData(token);
}

class _TestApi extends ApiClient {
  _TestApi({required this.location, this.track = const []});

  final Future<DeviceTrackPoint?> Function() location;
  final List<DeviceTrackPoint> track;
  int locationReads = 0;
  CancelToken? lastLocationToken;

  @override
  Future<DeviceTrackPoint?> fetchLocation(String deviceId,
      {CancelToken? cancelToken}) {
    expect(deviceId, _device.id);
    locationReads++;
    lastLocationToken = cancelToken;
    return location();
  }

  @override
  Future<List<DeviceTrackPoint>> fetchTrack(String deviceId,
      {DateTime? since, int limit = 500, CancelToken? cancelToken}) async {
    expect(deviceId, _device.id);
    return track;
  }
}

class _MemoryTiles extends TileProvider {
  static final _pixel = MemoryImage(base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAAEElEQVR4AQEFAPr/AM3a0v8IagN57DbvQgAAAABJRU5ErkJggg=='));

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _pixel;
}

Future<ProviderContainer> _mount(WidgetTester tester, _TestApi first,
    {_TestApi? second}) async {
  final container = ProviderContainer(overrides: [
    sessionProvider.overrideWith(_TestSession.new),
    devicesProvider.overrideWith((ref) async =>
        ref.watch(sessionProvider).valueOrNull == null ? [] : [_device]),
    apiClientProvider.overrideWith((ref) =>
        ref.watch(sessionProvider).valueOrNull == 'second-test-session'
            ? second!
            : first),
  ]);
  addTearDown(container.dispose);
  final tiles = _MemoryTiles();
  final router = GoRouter(initialLocation: '/map', routes: [
    StatefulShellRoute.indexedStack(
      builder: (_, __, navigationShell) => MainShell(
        navigationShell: navigationShell,
        mapBackgroundBuilder: (sheet) =>
            MapBackdrop(sheet: sheet, tileProvider: tiles),
      ),
      branches: [
        for (final (path, page) in const [
          ('/map', MapPage()),
          ('/rides', RideListPage()),
          ('/settings', SettingsPage()),
        ])
          StatefulShellBranch(routes: [
            GoRoute(
                path: path,
                pageBuilder: (_, state) =>
                    NoTransitionPage(key: state.pageKey, child: page)),
          ]),
      ],
    ),
    GoRoute(
        path: '/device',
        pageBuilder: (_, state) => floatingRoute(state, const DevicePage())),
  ]);
  addTearDown(router.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: CupertinoApp.router(routerConfig: router),
  ));
  await tester.pump();
  return container;
}

void main() {
  testWidgets('地图保留标记和轨迹，上报信息只在车辆管理中显示', (tester) async {
    final empty = _TestApi(location: () async => null);
    await _mount(tester, empty);
    await tester.pumpAndSettle();
    expect(find.text('暂无位置'), findsNothing);
    expect(empty.locationReads, 1);
    expect(find.byType(FlutterMap), findsNothing);
    await tester.tap(find.text('管理车辆'));
    await tester.pumpAndSettle();
    expect(find.text('暂无位置'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());

    final api = _TestApi(location: () async => _point(2), track: [
      _point(1),
      _point(2),
    ]);
    await _mount(tester, api);
    await tester.pumpAndSettle();
    expect(find.byType(MarkerLayer), findsOneWidget);
    expect(find.byWidgetPredicate((widget) => widget is PolylineLayer),
        findsOneWidget);
    expect(find.text('18.0 km/h'), findsNothing);
    expect(find.textContaining('上报时间'), findsNothing);
    expect(find.text('© OpenStreetMap contributors'), findsOneWidget);
    await tester.tap(find.text('管理车辆'));
    await tester.pumpAndSettle();
    expect(find.text('车辆管理'), findsOneWidget);
    expect(find.textContaining('上报时间'), findsOneWidget);
    expect(find.text('18.0 km/h'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换会话时清除同编号车辆的上次位置并取消旧请求', (tester) async {
    final oldResponse = Completer<DeviceTrackPoint?>();
    var firstCall = true;
    final first = _TestApi(location: () async {
      if (firstCall) {
        firstCall = false;
        return _point(2);
      }
      return oldResponse.future;
    });
    final next = Completer<DeviceTrackPoint?>();
    final second = _TestApi(location: () => next.future);
    final container = await _mount(tester, first, second: second);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理车辆'));
    await tester.pumpAndSettle();
    expect(find.text('18.0 km/h'), findsOneWidget);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    final oldRequest = first.lastLocationToken;
    expect(first.locationReads, 2);
    (container.read(sessionProvider.notifier) as _TestSession)
        .change('second-test-session');
    await tester.pump();
    await tester.pump();
    expect(find.text('18.0 km/h'), findsNothing);
    expect(oldRequest?.isCancelled, isTrue);

    oldResponse.complete(_point(3));
    next.complete(_point(4, speed: 10));
    await tester.pumpAndSettle();
    expect(find.text('36.0 km/h'), findsOneWidget);
    expect(find.text('18.0 km/h'), findsNothing);
    (container.read(sessionProvider.notifier) as _TestSession).change(null);
    await tester.pumpAndSettle();
    expect(find.byType(FlutterMap), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('切换浮动面板保留地图视角并继续刷新', (tester) async {
    final api = _TestApi(location: () async => _point(2));
    await _mount(tester, api);
    await tester.pumpAndSettle();
    expect(api.locationReads, 1);
    final map = find.byType(FlutterMap);
    final tabBar = find.byType(CupertinoTabBar);
    final controller = tester.widget<FlutterMap>(map).mapController!;
    const pannedCenter = LatLng(31.24, 121.48);
    controller.move(pannedCenter, 13);
    await tester.pumpAndSettle();

    var reads = 1;
    for (final (index, label) in [(1, '骑行'), (2, '设置'), (0, '地图')]) {
      await tester.tap(find.descendant(of: tabBar, matching: find.text(label)));
      await tester.pumpAndSettle();
      expect(tester.widget<CupertinoTabBar>(tabBar).currentIndex, index);
      expect(map, findsOneWidget);
      expect(tester.widget<FlutterMap>(map).mapController, same(controller));
      expect(controller.camera.center, pannedCenter);
      expect(controller.camera.zoom, 13);

      await tester.pump(const Duration(seconds: 10));
      await tester.pumpAndSettle();
      reads++;
      expect(api.locationReads, reads);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('位置加载失败时可重试', (tester) async {
    final pending = Completer<DeviceTrackPoint?>();
    var firstRequest = true;
    final api = _TestApi(location: () {
      if (firstRequest) {
        firstRequest = false;
        return pending.future;
      }
      return Future.value(null);
    });
    await _mount(tester, api);
    await tester.pumpAndSettle();
    await tester.tap(find.text('管理车辆'));
    await tester.pump();
    pending.completeError(ApiException('位置暂时无法读取'));
    await tester.pumpAndSettle();
    expect(find.text('无法加载位置'), findsOneWidget);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(api.locationReads, 2);
    expect(find.text('暂无位置'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('地图全屏铺底，面板升高时车辆标记留在可见区', (tester) async {
    final api = _TestApi(location: () async => _point(2), track: [
      _point(1),
      _point(2),
    ]);
    await _mount(tester, api);
    await tester.pumpAndSettle();
    final map = find.byType(FlutterMap);
    final panel = find.ancestor(
        of: find.byType(CupertinoTabBar), matching: find.byType(AppSurface));
    final marker = find.byIcon(CupertinoIcons.location_circle_fill);
    expect(tester.getSize(map),
        tester.getSize(find.byType(CupertinoPageScaffold)));
    expect(tester.getCenter(marker).dy, lessThan(tester.getTopLeft(panel).dy));
    tester.widget<MapBackdrop>(find.byType(MapBackdrop)).sheet.jumpTo(.82);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpAndSettle();
    expect(tester.getCenter(marker).dy, lessThan(tester.getTopLeft(panel).dy));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('用两个响应中序号最大的点显示位置和车速', (tester) async {
    final newer = _point(3, speed: 10);
    final api = _TestApi(
      location: () async => _point(2),
      track: [_point(2), newer],
    );
    await _mount(tester, api);
    await tester.pumpAndSettle();
    final marker = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    expect(marker.markers.single.point, LatLng(newer.lat, newer.lon));
    await tester.tap(find.text('管理车辆'));
    await tester.pumpAndSettle();
    expect(find.text('36.0 km/h'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('车辆驶出可见区时移回视野，保留用户主动移开的视角', (tester) async {
    var point = _point(2);
    final api = _TestApi(location: () async => point);
    await _mount(tester, api);
    await tester.pumpAndSettle();
    final map = find.byType(FlutterMap);
    final panel = find.ancestor(
        of: find.byType(CupertinoTabBar), matching: find.byType(AppSurface));
    final marker = find.byIcon(CupertinoIcons.location_circle_fill);
    final controller = tester.widget<FlutterMap>(map).mapController!;

    point = _point(3, latitude: 31.48);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    expect(marker, findsOneWidget);
    expect(tester.getCenter(marker).dy, lessThan(tester.getTopLeft(panel).dy));

    const explored = LatLng(31.12, 121.47);
    controller.move(explored, 16);
    await tester.pumpAndSettle();
    point = _point(4, latitude: 31.70, speed: 10);
    await tester.pump(const Duration(seconds: 10));
    await tester.pumpAndSettle();
    final markerLayer = tester.widget<MarkerLayer>(find.byType(MarkerLayer));
    expect(markerLayer.markers.single.point, LatLng(point.lat, point.lon));
    expect(
        controller.camera.center.latitude, closeTo(explored.latitude, .00001));
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
