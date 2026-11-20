import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'ble/ble_client.dart';
import 'session.dart';
import 'nfc/nfc_reader.dart';

/// API 客户端随会话切换，旧请求不能注销新会话。
final apiClientProvider = Provider<ApiClient>((ref) {
  final token = ref.watch(sessionProvider).valueOrNull;
  return ApiClient(
      token: token,
      onUnauthorized: () {
        if (ref.read(sessionProvider).valueOrNull == token) {
          ref.read(sessionProvider.notifier).logout();
        }
      });
});

final devicesProvider = FutureProvider<List<DeviceView>>((ref) async {
  final session = ref.watch(sessionProvider);
  if (session.valueOrNull == null) return [];
  return ref.watch(apiClientProvider).fetchDevices();
});

final selectedDeviceIdProvider = StateProvider<String?>((ref) {
  ref.watch(sessionProvider);
  return null;
});

final selectedDeviceProvider = Provider<DeviceView?>((ref) {
  final session = ref.watch(sessionProvider);
  if (session.isLoading || session.hasError || session.valueOrNull == null) {
    return null;
  }
  final result = ref.watch(devicesProvider);
  final devices = result.isLoading || result.hasError
      ? <DeviceView>[]
      : result.valueOrNull ?? [];
  final id = ref.watch(selectedDeviceIdProvider);
  for (final device in devices) {
    if (device.id == id) return device;
  }
  return devices.isEmpty ? null : devices.first;
});

/// 相同编号在不同会话下使用不同的查询实例。
class DeviceTelemetryTarget {
  const DeviceTelemetryTarget._(this.deviceId, this._client);

  final String deviceId;
  final ApiClient _client;
}

final selectedTelemetryTargetProvider = Provider<DeviceTelemetryTarget?>((ref) {
  final device = ref.watch(selectedDeviceProvider);
  if (device == null) return null;
  return DeviceTelemetryTarget._(device.id, ref.watch(apiClientProvider));
});

final deviceLocationProvider = FutureProvider.autoDispose
    .family<DeviceTrackPoint?, DeviceTelemetryTarget>((ref, target) {
  final cancel = CancelToken();
  ref.onDispose(cancel.cancel);
  return target._client.fetchLocation(target.deviceId, cancelToken: cancel);
});

final deviceTrackProvider = FutureProvider.autoDispose
    .family<List<DeviceTrackPoint>, DeviceTelemetryTarget>((ref, target) {
  final cancel = CancelToken();
  ref.onDispose(cancel.cancel);
  return target._client.fetchTrack(target.deviceId, cancelToken: cancel);
});

class DeviceTelemetry {
  const DeviceTelemetry({required this.latest, required this.track});

  final DeviceTrackPoint? latest;
  final List<DeviceTrackPoint> track;

  DeviceTrackPoint? get current {
    final point = latest;
    final lastTrackPoint = track.isEmpty ? null : track.last;
    if (point == null ||
        (lastTrackPoint != null && lastTrackPoint.seq > point.seq)) {
      return lastTrackPoint;
    }
    return point;
  }
}

final deviceTelemetryProvider = Provider.autoDispose
    .family<AsyncValue<DeviceTelemetry>, DeviceTelemetryTarget>((ref, target) {
  final location = ref.watch(deviceLocationProvider(target));
  final track = ref.watch(deviceTrackProvider(target));
  final error = location.error ?? track.error;
  if (error != null) {
    return AsyncError(
        error, location.stackTrace ?? track.stackTrace ?? StackTrace.empty);
  }
  if (!location.hasValue || !track.hasValue) return const AsyncLoading();
  return AsyncData(
      DeviceTelemetry(latest: location.valueOrNull, track: track.requireValue));
});

void refreshDeviceTelemetry(WidgetRef ref, DeviceTelemetryTarget target) {
  ref.invalidate(deviceLocationProvider(target));
  ref.invalidate(deviceTrackProvider(target));
}

final deviceActionsProvider = Provider((ref) => DeviceActions(ref));

class DeviceActions {
  DeviceActions(this.ref);
  final Ref ref;
  Future<DeviceView> bind(String deviceId, String claimCode) async {
    final device = await ref
        .read(apiClientProvider)
        .bindDevice(deviceId: deviceId, claimCode: claimCode);
    ref.invalidate(devicesProvider);
    ref.read(selectedDeviceIdProvider.notifier).state = device.id;
    return device;
  }

  Future<void> unbind(String deviceId) async {
    await ref.read(apiClientProvider).unbindDevice(deviceId);
    ref.invalidate(devicesProvider);
  }
}

/// BLE 客户端。M1 换成 flutter_blue_plus 实现，页面代码不变。
final bleClientProvider = Provider<BleClient>((ref) {
  const client = UnimplementedBleClient();
  ref.onDispose(() {
    client.dispose();
  });
  return client;
});

/// NFC 读取器。M1 换成 nfc_manager 实现。
final nfcReaderProvider = Provider<NfcReader>((ref) {
  return const UnimplementedNfcReader();
});
