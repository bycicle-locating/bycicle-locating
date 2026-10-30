/// NFC 绑定标签的读取与解析。契约见 docs/pairing.md §2–§3。
///
/// 标签是 **ST25DV16K**（ISO/IEC 15693，NFC Forum **Type 5**），内容为 NDEF URI：
/// `https://<domain>/bind?d=<deviceId>&c=<claimCode>`。
///
/// 实现要点（M1）：
/// - 轮询配置必须包含 **ISO 15693**，只开 ISO 14443（Type 2）是读不到的；
/// - Android 直接读 NFC-V 的 NDEF；iOS 用 `NFCTagReaderSession` 的 `.iso15693` 轮询选项
///   （锁屏后台触碰由系统处理，但 Type 5 的实机表现必须在目标机型上验证）；
/// - 本文件只负责"读到的文本 → BindTag"，不负责调后端、也不负责加锁。
library;

/// 从标签解析出的绑定材料。
///
/// ⚠️ `claimCode` 属于敏感数据：不要写日志、不要放进埋点。
/// 它**不是一次性使用**——设备已绑定期间失效，解绑后原码恢复可用（docs/pairing.md §3）。
class BindTag {
  const BindTag({required this.deviceId, required this.claimCode});

  final String deviceId;
  final String claimCode;

  @override
  String toString() => 'BindTag(deviceId: $deviceId)';
}

/// NFC 读取能力。用接口而不是直接依赖插件，便于替换实现与在测试中伪造。
abstract class NfcReader {
  /// 等待用户触碰标签。取消或读到的不是绑定标签时返回 null。
  Future<BindTag?> readBindTag();
}

/// 尚未接入插件时的占位实现。
class UnimplementedNfcReader implements NfcReader {
  const UnimplementedNfcReader();

  @override
  Future<BindTag?> readBindTag() async {
    throw UnsupportedError('NFC 读取尚未接入，见 docs/roadmap.md M1');
  }
}

/// 标签解析器。纯函数，可脱离插件单测。
class BindTagParser {
  const BindTagParser._();

  /// 与后端 deviceId 规则保持一致（见 backend/internal/protocol）。
  static final RegExp _deviceIdPattern =
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9_-]{5,63}$');

  /// 声明码是 16 位 Base32（后端用同一规则校验）。
  static final RegExp _claimCodePattern = RegExp(r'^[A-Z2-7]{16}$');

  /// 解析 URI。任何不合规输入返回 null，由调用方提示"标签无效"。
  static BindTag? fromUri(Uri uri) {
    if (uri.path != '/bind') {
      return null;
    }
    final deviceId = uri.queryParameters['d'];
    final rawCode = uri.queryParameters['c'];
    if (deviceId == null || rawCode == null) {
      return null;
    }
    if (!_deviceIdPattern.hasMatch(deviceId)) {
      return null;
    }
    final claimCode = rawCode.toUpperCase();
    if (!_claimCodePattern.hasMatch(claimCode)) {
      return null;
    }
    return BindTag(deviceId: deviceId, claimCode: claimCode);
  }

  /// 从原始文本（NFC 记录内容或剪贴板）解析。
  static BindTag? fromText(String text) {
    final uri = Uri.tryParse(text.trim());
    if (uri == null) {
      return null;
    }
    return fromUri(uri);
  }
}
