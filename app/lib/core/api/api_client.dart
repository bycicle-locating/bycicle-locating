import 'package:dio/dio.dart';

import '../env.dart';

/// 后端业务错误。UI 直接把 [message] 展示给用户即可。
class ApiException implements Exception {
  ApiException(this.message, {this.code, this.statusCode});

  final String message;
  final String? code;
  final int? statusCode;

  @override
  String toString() => 'ApiException(code=$code, status=$statusCode): $message';
}

/// 设备视图，字段与后端 deviceDTO 对齐（backend/internal/api/router.go）。
class DeviceView {
  const DeviceView({
    required this.id,
    required this.model,
    required this.state,
    required this.bound,
    this.label,
    this.firmware,
    this.lastSeenAt,
  });

  final String id;
  final String model;
  final String state;
  final bool bound;
  final String? label;
  final String? firmware;
  final DateTime? lastSeenAt;

  /// 非空即表示有车主。
  bool get isClaimed => state == 'CLAIMED';

  factory DeviceView.fromJson(Map<String, dynamic> json) {
    final lastSeen = json['lastSeenAt'] as String?;
    return DeviceView(
      id: json['id'] as String,
      model: (json['model'] as String?) ?? '',
      state: (json['state'] as String?) ?? '',
      bound: (json['bound'] as bool?) ?? false,
      label: json['label'] as String?,
      firmware: json['firmware'] as String?,
      lastSeenAt:
          lastSeen == null ? null : DateTime.tryParse(lastSeen)?.toLocal(),
    );
  }
}

/// 后端 HTTP 客户端。
///
/// 约束：
/// - 只有 `features/*/data` 与 provider 可以持有它，widget 不得直接调用；
/// - 所有错误统一转成 [ApiException]，UI 不需要认识 DioException。
class ApiClient {
  ApiClient({Dio? dio, String baseUrl = Env.apiBaseUrl, String? devUser})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                headers: {
                  'Content-Type': 'application/json',
                  // TODO(M1): 换成 Authorization: Bearer <JWT>，并加 401 自动刷新。
                  if (devUser != null) 'X-Dev-User': devUser,
                },
              ),
            );

  final Dio _dio;

  /// 用 NFC 读到的声明码绑定设备。
  ///
  /// 403 表示标签无效或已被使用，409 表示已被绑定——两者都不应暴露车主信息。
  Future<DeviceView> bindDevice({
    required String deviceId,
    required String claimCode,
    String? label,
  }) async {
    try {
      final res = await _dio.post<Map<String, dynamic>>(
        '/v1/devices:bind',
        data: {
          'deviceId': deviceId,
          'claimCode': claimCode,
          if (label != null && label.isNotEmpty) 'label': label,
        },
      );
      final data = res.data;
      if (data == null) {
        throw ApiException('服务器返回空响应');
      }
      return DeviceView.fromJson(data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// 读取设备详情（仅车主可读）。
  Future<DeviceView> fetchDevice(String deviceId) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>('/v1/devices/$deviceId');
      final data = res.data;
      if (data == null) {
        throw ApiException('服务器返回空响应');
      }
      return DeviceView.fromJson(data);
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  /// 解绑。只能由车主发起——App 不提供"设备侧长按"这条路径。
  Future<void> unbindDevice(String deviceId) async {
    try {
      await _dio.delete<void>('/v1/devices/$deviceId/binding');
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  ApiException _toApiException(DioException e) {
    final res = e.response;
    final data = res?.data;
    if (data is Map<String, dynamic>) {
      final message = data['message'] as String?;
      if (message != null) {
        return ApiException(message,
            code: data['error'] as String?, statusCode: res?.statusCode);
      }
    }
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return ApiException('网络超时，请稍后重试', statusCode: res?.statusCode);
      case DioExceptionType.connectionError:
        return ApiException('无法连接服务器，请检查网络', statusCode: res?.statusCode);
      default:
        return ApiException(e.message ?? '请求失败', statusCode: res?.statusCode);
    }
  }
}
