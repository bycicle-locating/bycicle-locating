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
