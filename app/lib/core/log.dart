import 'package:flutter/foundation.dart';

/// 统一日志出口。
///
/// 业务代码禁止直接 `print`（`analysis_options.yaml` 已启用 `avoid_print`）。
/// Release 包默认不输出，避免把设备 ID、坐标等写进系统日志。
void logInfo(String message, [Object? data]) {
  if (kDebugMode) {
    debugPrint('[INFO] $message${data == null ? '' : ' $data'}');
  }
}

void logWarn(String message, [Object? data]) {
  if (kDebugMode) {
    debugPrint('[WARN] $message${data == null ? '' : ' $data'}');
  }
}

void logError(String message, {Object? error, StackTrace? stackTrace}) {
  if (kDebugMode) {
    debugPrint('[ERROR] $message${error == null ? '' : ' $error'}');
    if (stackTrace != null) {
      debugPrint(stackTrace.toString());
    }
  }
}
