import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/link.dart';

import '../../../core/providers.dart';
import '../../../core/theme/app_surface.dart';

class MapBackdrop extends ConsumerStatefulWidget {
  const MapBackdrop({super.key, required this.sheet, this.tileProvider});

  final DraggableScrollableController sheet;
  final TileProvider? tileProvider;

  @override
  ConsumerState<MapBackdrop> createState() => _MapBackdropState();
}

class _MapBackdropState extends ConsumerState<MapBackdrop> {
  late final Timer _refreshTimer;

  @override
  void initState() {
    super.initState();
    _refreshTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      final lifecycle = WidgetsBinding.instance.lifecycleState;
      if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
      final target = ref.read(selectedTelemetryTargetProvider);
      if (target == null ||
          ref.read(deviceLocationProvider(target)).isLoading ||
          ref.read(deviceTrackProvider(target)).isLoading) {
        return;
      }
      refreshDeviceTelemetry(ref, target);
    });
  }

  @override
  void dispose() {
    _refreshTimer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final target = ref.watch(selectedTelemetryTargetProvider);
    if (target == null) return const SizedBox.shrink();
    return ref.watch(deviceTelemetryProvider(target)).when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (data) {
            final latest = data.current;
            if (latest == null) return const SizedBox.shrink();
            return _VehicleMap(
              key: ObjectKey(target),
              position: LatLng(latest.lat, latest.lon),
              points: data.track.map((p) => LatLng(p.lat, p.lon)).toList(),
              sheet: widget.sheet,
              tileProvider: widget.tileProvider,
            );
          },
        );
  }
}

class _VehicleMap extends StatefulWidget {
  const _VehicleMap({
    super.key,
    required this.position,
    required this.points,
    required this.sheet,
    required this.tileProvider,
  });

  final LatLng position;
  final List<LatLng> points;
  final DraggableScrollableController sheet;
  final TileProvider? tileProvider;

  @override
  State<_VehicleMap> createState() => _VehicleMapState();
}

class _VehicleMapState extends State<_VehicleMap> {
  final _controller = MapController();
  late final _tiles = widget.tileProvider ?? NetworkTileProvider();
  Timer? _adjustment;
  bool _ready = false;

  @override
  void initState() {
    super.initState();
    widget.sheet.addListener(_onSheetChange);
  }

  @override
  void didUpdateWidget(covariant _VehicleMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sheet != widget.sheet) {
      oldWidget.sheet.removeListener(_onSheetChange);
      widget.sheet.addListener(_onSheetChange);
    }
    if (_ready &&
        oldWidget.position != widget.position &&
        _markerInView(oldWidget.position) &&
        !_markerInView(widget.position)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_markerInView(widget.position)) {
          _controller.fitCamera(_fit(maxZoom: _controller.camera.zoom));
        }
      });
    }
  }

  @override
  void dispose() {
    widget.sheet.removeListener(_onSheetChange);
    _adjustment?.cancel();
    _controller.dispose();
    super.dispose();
  }

  double _coveredHeight(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final safe = MediaQuery.paddingOf(context);
    final extent = widget.sheet.isAttached ? widget.sheet.size : .5;
    return safe.bottom +
        8 +
        math.max(0, size.height - safe.vertical - 16) * extent;
  }

  bool _markerInView(LatLng position) {
    const radius = 20.0;
    final size = MediaQuery.sizeOf(context);
    final top = MediaQuery.paddingOf(context).top;
    final visible = Rect.fromLTRB(radius, top + radius, size.width - radius,
        size.height - _coveredHeight(context) - radius);
    return visible.contains(_controller.camera.latLngToScreenOffset(position));
  }

  CameraFit _fit({bool includeTrack = false, double maxZoom = 17}) {
    final size = MediaQuery.sizeOf(context);
    final top = MediaQuery.paddingOf(context).top + 10;
    final bottom = math.min(
        _coveredHeight(context) + 10, math.max(0.0, size.height - top - 20));
    return CameraFit.coordinates(
      coordinates: [if (includeTrack) ...widget.points, widget.position],
      padding: EdgeInsets.fromLTRB(24, top, 24, bottom),
      maxZoom: maxZoom,
    );
  }

  void _onSheetChange() {
    _adjustment?.cancel();
    // 面板拖动时保留地图实例，吸附后再把被挡住的车辆移回可见区。
    _adjustment = Timer(const Duration(milliseconds: 180), () {
      if (!_ready || !mounted) return;
      final marker = _controller.camera.latLngToScreenOffset(widget.position);
      final bottom =
          MediaQuery.sizeOf(context).height - _coveredHeight(context);
      if (marker.dy + 20 > bottom) _controller.fitCamera(_fit());
    });
  }

  @override
  Widget build(BuildContext context) {
    final color = CupertinoTheme.of(context).primaryColor;
    return Stack(
      fit: StackFit.expand,
      children: [
        FlutterMap(
          mapController: _controller,
          options: MapOptions(
            initialCenter: widget.position,
            initialZoom: 16,
            initialCameraFit: _fit(includeTrack: true),
            minZoom: 2,
            maxZoom: 19,
            onMapReady: () => _ready = true,
            backgroundColor: CupertinoColors.systemGrey5.resolveFrom(context),
          ),
          children: [
            TileLayer(
              urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
              userAgentPackageName: 'top.byciclelocating.app',
              maxNativeZoom: 19,
              tileProvider: _tiles,
            ),
            if (widget.points.length >= 2)
              PolylineLayer(polylines: [
                Polyline(points: widget.points, color: color, strokeWidth: 4),
              ]),
            MarkerLayer(markers: [
              Marker(
                point: widget.position,
                width: 40,
                height: 40,
                child: Semantics(
                  label: '车辆最新位置',
                  child: Icon(CupertinoIcons.location_circle_fill,
                      size: 34, color: color),
                ),
              ),
            ]),
          ],
        ),
        AnimatedBuilder(
          animation: widget.sheet,
          child: AppSurface(
            glass: true,
            radius: 12,
            child: Link(
              uri: Uri.https('www.openstreetmap.org', '/copyright'),
              target: LinkTarget.blank,
              builder: (_, followLink) => CupertinoButton(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                minimumSize: const Size(0, 24),
                onPressed: followLink,
                child: const Text('© OpenStreetMap contributors',
                    style: TextStyle(fontSize: 12)),
              ),
            ),
          ),
          builder: (context, child) => Positioned(
            left: 12,
            bottom: _coveredHeight(context) + 4,
            child: child!,
          ),
        ),
        Positioned(
          top: MediaQuery.paddingOf(context).top + 12,
          right: 12,
          child: AppSurface(
            glass: true,
            radius: 12,
            child: CupertinoButton(
              padding: const EdgeInsets.all(8),
              onPressed: () {
                if (_ready) _controller.fitCamera(_fit());
              },
              child: Semantics(
                label: '回到车辆位置',
                child:
                    Icon(CupertinoIcons.location_fill, color: color, size: 20),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
