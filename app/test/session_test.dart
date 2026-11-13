import 'dart:convert';

import 'package:bkl_app/core/api/api_client.dart';
import 'package:bkl_app/core/session.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class AuthApi extends ApiClient {
  @override
  Future<Map<String, dynamic>> authenticate(String email, String password,
          {bool register = false}) async =>
      {
        'token': 'new-token',
        'expiresAt':
            DateTime.now().add(const Duration(hours: 1)).toIso8601String(),
      };
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  ProviderContainer container({Future<void> Function(String)? check}) {
    final result = ProviderContainer(overrides: [
      sessionApiProvider.overrideWithValue(AuthApi()),
      sessionCheckProvider.overrideWithValue(check ?? (_) async {}),
    ]);
    addTearDown(result.dispose);
    return result;
  }

  String saved(DateTime expiry) => jsonEncode({
        'token': 'saved-token',
        'expiresAt': expiry.toIso8601String(),
      });

  test('登录保存会话，退出清除持久化令牌', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final ref = container();
    expect(await ref.read(sessionProvider.future), isNull);
    final session = ref.read(sessionProvider.notifier);
    await session.login('test@example.com', 'password');
    expect(ref.read(sessionProvider).value, 'new-token');
    expect(await ref.read(sessionStorageProvider).read(key: 'session'),
        contains('new-token'));
    await session.logout();
    expect(ref.read(sessionProvider).value, isNull);
    expect(await ref.read(sessionStorageProvider).read(key: 'session'), isNull);
  });

  test('重启后校验并恢复未过期会话', () async {
    FlutterSecureStorage.setMockInitialValues({
      'session': saved(DateTime.now().add(const Duration(hours: 1))),
    });
    String? checked;
    final ref = container(check: (token) async {
      checked = token;
    });
    expect(await ref.read(sessionProvider.future), 'saved-token');
    expect(checked, 'saved-token');
  });

  test('已过期会话不能进入应用', () async {
    FlutterSecureStorage.setMockInitialValues({
      'session': saved(DateTime.now().subtract(const Duration(seconds: 1))),
    });
    final ref = container(check: (_) async => fail('过期令牌不应发请求'));
    expect(await ref.read(sessionProvider.future), isNull);
    expect(await ref.read(sessionStorageProvider).read(key: 'session'), isNull);
  });

  test('服务端拒绝会话时清理令牌', () async {
    FlutterSecureStorage.setMockInitialValues({
      'session': saved(DateTime.now().add(const Duration(hours: 1))),
    });
    final ref = container(
        check: (_) async => throw ApiException('请先登录', statusCode: 401));
    expect(await ref.read(sessionProvider.future), isNull);
    expect(await ref.read(sessionStorageProvider).read(key: 'session'), isNull);
  });

  test('网络失败保留会话但禁止进入业务页', () async {
    FlutterSecureStorage.setMockInitialValues({
      'session': saved(DateTime.now().add(const Duration(hours: 1))),
    });
    final ref = container(check: (_) async => throw ApiException('网络超时'));
    await expectLater(
        ref.read(sessionProvider.future), throwsA(isA<ApiException>()));
    expect(ref.read(sessionProvider).hasError, isTrue);
    expect(
        await ref.read(sessionStorageProvider).read(key: 'session'), isNotNull);
  });
}
