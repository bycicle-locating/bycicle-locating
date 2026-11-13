/// 编译期环境配置。用 --dart-define 覆盖，避免把地址写死在代码里：
///
/// ```
/// flutter run --dart-define=API_BASE_URL=https://api.example.com
/// ```
class Env {
  const Env._();

  /// 公开 API 入口；业务请求使用用户 JWT 鉴权。
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'https://api.bycicle-locating.top',
  );

  /// WebSocket 基址（M1 接入，握手与鉴权尚未实现）。
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'wss://api.bycicle-locating.top',
  );

  /// 绑定落地页域名，与 NFC 标签里写入的 URI 必须一致。
  static const String bindHost = String.fromEnvironment(
    'BIND_HOST',
    defaultValue: 'bkl.example.com',
  );

  /// 近场判定：进入/退出阈值（dBm）。滞回 13 dB，防止边界抖动（pairing.md §6）。
  static const int bleRssiEnterDbm = -65;
  static const int bleRssiExitDbm = -78;

  /// 连续多少个采样才改变"在附近"状态，约 2 秒。
  static const int bleProximitySamples = 3;
}
