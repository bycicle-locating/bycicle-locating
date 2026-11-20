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

/// `/location` 和 `/track` 共用的遥测点。
class DeviceTrackPoint {
  const DeviceTrackPoint({
    required this.deviceId,
    required this.seq,
    required this.ts,
    required this.lat,
    required this.lon,
    required this.speedMps,
    required this.courseDeg,
    required this.fix,
    this.altM,
    this.hdop,
  });

  final String deviceId;
  final int seq;
  final DateTime ts;
  final double lat;
  final double lon;
  final double speedMps;
  final double courseDeg;
  final int fix;
  final double? altM;
  final double? hdop;

  factory DeviceTrackPoint.fromJson(Map<String, dynamic> json) {
    try {
      final point = DeviceTrackPoint(
        deviceId: json['deviceId'] as String,
        seq: json['seq'] as int,
        ts: DateTime.parse(json['ts'] as String).toUtc(),
        lat: (json['lat'] as num).toDouble(),
        lon: (json['lon'] as num).toDouble(),
        speedMps: (json['speedMps'] as num).toDouble(),
        courseDeg: (json['courseDeg'] as num).toDouble(),
        fix: json['fix'] as int,
        altM: (json['altM'] as num?)?.toDouble(),
        hdop: (json['hdop'] as num?)?.toDouble(),
      );
      if (!point.lat.isFinite ||
          !point.lon.isFinite ||
          point.lat.abs() > 90 ||
          point.lon.abs() > 180 ||
          !point.speedMps.isFinite ||
          !point.courseDeg.isFinite) {
        throw _invalidTelemetryResponse();
      }
      return point;
    } on TypeError {
      throw _invalidTelemetryResponse();
    } on FormatException {
      throw _invalidTelemetryResponse();
    }
  }
}

ApiException _invalidTelemetryResponse() =>
    ApiException('服务器返回无效的遥测数据', code: 'unexpected_response');

DeviceTrackPoint _pointForDevice(Object? value, String deviceId) {
  if (value is! Map<String, dynamic>) throw _invalidTelemetryResponse();
  final point = DeviceTrackPoint.fromJson(value);
  if (point.deviceId != deviceId) throw _invalidTelemetryResponse();
  return point;
}

/// 后端 HTTP 客户端。
///
/// 约束：
/// - 只有 `features/*/data` 与 provider 可以持有它，widget 不得直接调用；
/// - 所有错误统一转成 [ApiException]，UI 不需要认识 DioException。
class ApiClient {
  ApiClient(
      {Dio? dio,
      String baseUrl = Env.apiBaseUrl,
      this.token,
      this.onUnauthorized})
      : _dio = dio ??
            Dio(
              BaseOptions(
                baseUrl: baseUrl,
                connectTimeout: const Duration(seconds: 10),
                receiveTimeout: const Duration(seconds: 15),
                followRedirects: false,
                headers: {
                  'Content-Type': 'application/json',
                  if (token != null) 'Authorization': 'Bearer $token',
                },
              ),
            );

  final Dio _dio;
  final String? token;
  final void Function()? onUnauthorized;

  Future<Map<String, dynamic>> authenticate(String email, String password,
      {bool register = false}) async {
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        register ? '/v1/auth/register' : '/v1/auth/login',
        data: {'email': email, 'password': password},
      );
      return response.data ?? (throw ApiException('服务器返回空响应'));
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<void> checkSession() async {
    try {
      await _dio.get<Map<String, dynamic>>('/v1/users/me');
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

  Future<List<DeviceView>> fetchDevices() async {
    try {
      final response =
          await _dio.get<Map<String, dynamic>>('/v1/users/me/devices');
      return (response.data!['devices'] as List)
          .map((item) => DeviceView.fromJson(item as Map<String, dynamic>))
          .toList();
    } on DioException catch (e) {
      throw _toApiException(e);
    }
  }

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

  Future<DeviceTrackPoint?> fetchLocation(String deviceId,
      {CancelToken? cancelToken}) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/devices/${Uri.encodeComponent(deviceId)}/location',
        cancelToken: cancelToken,
      );
      return _pointForDevice(response.data, deviceId);
    } on DioException catch (e) {
      final error = _toApiException(e);
      if (error.statusCode == 404 && error.code == 'not_found') return null;
      throw error;
    }
  }

  Future<List<DeviceTrackPoint>> fetchTrack(String deviceId,
      {DateTime? since, int limit = 500, CancelToken? cancelToken}) async {
    try {
      final response = await _dio.get<Object?>(
        '/v1/devices/${Uri.encodeComponent(deviceId)}/track',
        queryParameters: {
          if (since != null) 'since': since.toUtc().toIso8601String(),
          'limit': limit.clamp(1, 500),
        },
        cancelToken: cancelToken,
      );
      final data = response.data;
      if (data is! Map<String, dynamic> || data['points'] is! List) {
        throw _invalidTelemetryResponse();
      }
      return List<DeviceTrackPoint>.unmodifiable((data['points'] as List)
          .map((point) => _pointForDevice(point, deviceId)));
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
    final status = res?.statusCode;
    if (status != null && status >= 300 && status < 400) {
      return ApiException('服务入口不可用，请稍后重试',
          code: 'service_unavailable', statusCode: status);
    }
    final data = res?.data;
    if ((status == 401 || status == 403) && data is! Map<String, dynamic>) {
      return ApiException('服务响应异常，请稍后重试',
          code: 'unexpected_response', statusCode: status);
    }
    if (status == 401 && token != null && data is Map<String, dynamic>) {
      onUnauthorized?.call();
    }
    if (data is Map<String, dynamic>) {
      final message = data['message'];
      final code = data['error'];
      if (message is String) {
        return ApiException(message,
            code: code is String ? code : null, statusCode: status);
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
