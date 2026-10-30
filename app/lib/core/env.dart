/// 编译期环境配置。用 --dart-define 覆盖，避免把地址写死在代码里：
///
/// ```
/// flutter run --dart-define=API_BASE_URL=https://api.example.com
/// ```
class Env {
  const Env._();

  /// 后端 REST 基址。默认指向本机 `go run ./cmd/server`。
  static const String apiBaseUrl = String.fromEnvironment(
    'API_BASE_URL',
    defaultValue: 'http://127.0.0.1:8080',
  );

  /// WebSocket 基址（实时位置与告警推送，M1 接入）。
  static const String wsBaseUrl = String.fromEnvironment(
    'WS_BASE_URL',
    defaultValue: 'ws://127.0.0.1:8080',
  );

  /// 绑定落地页域名，与 NFC 标签里写入的 URI 必须一致。
  static const String bindHost = String.fromEnvironment(
    'BIND_HOST',
    defaultValue: 'bkl.example.com',
  );

  /// 开发用户标识。仅用于本地联调（后端 APP_ENV=dev 时信任该请求头），
  /// 接入 JWT 后必须删除。
  static const String devUserId = String.fromEnvironment(
    'DEV_USER_ID',
    defaultValue: '11111111-1111-1111-1111-111111111111',
  );

  /// 近场判定：进入/退出阈值（dBm）。滞回 13 dB，防止边界抖动（pairing.md §6）。
  static const int bleRssiEnterDbm = -65;
  static const int bleRssiExitDbm = -78;

  /// 连续多少个采样才改变"在附近"状态，约 2 秒。
  static const int bleProximitySamples = 3;
}
