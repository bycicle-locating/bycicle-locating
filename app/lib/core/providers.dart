import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/api_client.dart';
import 'ble/ble_client.dart';
import 'env.dart';
import 'nfc/nfc_reader.dart';

/// 全应用唯一的 API 客户端。
///
/// M1 接入 JWT 后，把 devUser 换成 token 注入 + 401 刷新逻辑，调用方不用改。
final apiClientProvider = Provider<ApiClient>((ref) {
  return ApiClient(devUser: Env.devUserId);
});

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
