import 'dart:convert';
import 'dart:typed_data';

import 'package:bkl_app/core/api/api_client.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

const _deviceId = 'BKL-2026-990001';
const _point = {
  'deviceId': _deviceId,
  'seq': 42,
  'ts': '2026-11-20T07:10:00Z',
  'lat': 31.23,
  'lon': 121.47,
  'speedMps': 5,
  'courseDeg': 90,
  'fix': 3,
  'altM': 12.5,
};

class _Adapter implements HttpClientAdapter {
  _Adapter(this.respond);

  final ResponseBody Function(RequestOptions) respond;

  @override
  Future<ResponseBody> fetch(RequestOptions options,
          Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async =>
      respond(options);

  @override
  void close({bool force = false}) {}
}

ApiClient _client(ResponseBody Function(RequestOptions) respond) {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.test'))
    ..httpClientAdapter = _Adapter(respond);
  addTearDown(dio.close);
  return ApiClient(dio: dio);
}

ResponseBody _json(Object data, [int status = 200]) =>
    ResponseBody.fromString(jsonEncode(data), status, headers: {
      'content-type': ['application/json'],
    });

void main() {
  test('读取最新位置并保留 WGS-84、UTC 与原始 m/s', () async {
    final api = _client((request) {
      expect(request.path, '/v1/devices/$_deviceId/location');
      return _json(_point);
    });
    final point = (await api.fetchLocation(_deviceId))!;
    expect(point.deviceId, _deviceId);
    expect(point.seq, 42);
    expect(point.ts, DateTime.utc(2026, 11, 20, 7, 10));
    expect(point.lat, 31.23);
    expect(point.lon, 121.47);
    expect(point.speedMps, 5);
    expect(point.courseDeg, 90);
    expect(point.altM, 12.5);
    expect(point.hdop, isNull);
    expect(point.fix, 3);
  });

  test('轨迹时间参数转 UTC，按服务端点序返回', () async {
    final api = _client((request) {
      expect(request.path, '/v1/devices/$_deviceId/track');
      expect(request.queryParameters, {
        'since': '2026-11-20T07:00:00.000Z',
        'limit': 500,
      });
      return _json({
        'points': [
          {..._point, 'seq': 41, 'ts': '2026-11-20T07:11:00Z'},
          _point,
        ],
      });
    });
    final track = await api.fetchTrack(_deviceId,
        since: DateTime.parse('2026-11-20T15:00:00+08:00'), limit: 1000);
    expect(track.map((point) => point.seq), [41, 42]);
  });

  test('只有定位接口明确返回无数据时，才显示空位置', () async {
    final empty = _client(
        (_) => _json({'error': 'not_found', 'message': '设备暂无可查看的位置'}, 404));
    expect(await empty.fetchLocation(_deviceId), isNull);
    final missingRoute =
        _client((_) => ResponseBody.fromString('404 page not found', 404));
    await expectLater(missingRoute.fetchLocation(_deviceId),
        throwsA(isA<ApiException>().having((e) => e.statusCode, '状态码', 404)));
  });

  test('权限错误和设备不符的响应统一为 ApiException', () async {
    final denied = _client(
        (_) => _json({'error': 'forbidden', 'message': '无权查看该设备'}, 403));
    await expectLater(denied.fetchTrack(_deviceId),
        throwsA(isA<ApiException>().having((e) => e.code, '错误码', 'forbidden')));
    final wrongDevice =
        _client((_) => _json({..._point, 'deviceId': 'BKL-2026-999999'}));
    await expectLater(
        wrongDevice.fetchLocation(_deviceId),
        throwsA(isA<ApiException>()
            .having((e) => e.code, '错误码', 'unexpected_response')));
  });
}
