/// BLE 近场状态。契约见 docs/pairing.md §5–§6。
///
/// ⚠️ 边界：BLE 只提供"连接状态 / 在附近 / 找车"，**不提供绑定或解绑能力**，
/// 也不得用 RSSI 作为布防、撤防或任何安全判定的依据。
library;

/// 一次近场状态快照。
class BleStatus {
  const BleStatus({
    required this.deviceId,
    required this.connected,
    this.rssiDbm,
    this.batteryPercent,
    this.gpsFix,
  });

  final String deviceId;
  final bool connected;
  final int? rssiDbm;
  final int? batteryPercent;
  final bool? gpsFix;

  /// 是否"在车旁边"。
  ///
  /// 仅用于 UI 文案与"找我的车"按钮高亮。真实实现必须做滞回与去抖
  /// （进入 -65 dBm、退出 -78 dBm、连续 3 个采样才翻转），见 Env 与 pairing.md §6。
  bool get isNearby => rssiDbm != null && rssiDbm! >= -65;
}

/// BLE 客户端接口。真实实现基于 flutter_blue_plus，M1 接入。
abstract class BleClient {
  /// 订阅某设备的状态。实现应在断开时继续重连，直到取消订阅。
  Stream<BleStatus> watchStatus(String deviceId);

  /// 让车闪灯 + 蜂鸣，便于在车群中找到自己的车。
  Future<void> findBike(String deviceId, {Duration duration});

  Future<void> dispose();
}

/// 尚未接入插件时的占位实现：订阅立即结束，找车直接报"未实现"。
class UnimplementedBleClient implements BleClient {
  const UnimplementedBleClient();

  @override
  Stream<BleStatus> watchStatus(String deviceId) {
    return const Stream<BleStatus>.empty();
  }

  @override
  Future<void> findBike(String deviceId,
      {Duration duration = const Duration(seconds: 10)}) async {
    throw UnsupportedError('BLE 尚未接入，见 docs/roadmap.md M1');
  }

  @override
  Future<void> dispose() async {}
}
