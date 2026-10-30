/// NFC 绑定标签的读取与解析。契约见 docs/pairing.md §2–§3。
///
/// 标签内容是 NDEF URI：`https://<domain>/bind?d=<deviceId>&c=<claimCode>`。
/// 本文件只负责"读到的文本 → BindTag"，不负责调后端、也不负责加锁。
library;

/// 从标签解析出的绑定材料。
///
/// ⚠️ `claimCode` 是一次性声明码，属于敏感数据：不要写日志、不要放进埋点。
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
