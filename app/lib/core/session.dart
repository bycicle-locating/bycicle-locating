import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api/api_client.dart';

final sessionStorageProvider = Provider((ref) => const FlutterSecureStorage());
final sessionApiProvider = Provider((ref) => ApiClient());
final sessionCheckProvider = Provider<Future<void> Function(String)>((ref) {
  return (token) => ApiClient(token: token).checkSession();
});
final sessionProvider =
    AsyncNotifierProvider<SessionController, String?>(SessionController.new);

class SessionController extends AsyncNotifier<String?> {
  Timer? _expiry;
  int _generation = 0;
  Future<void> _storageOperation = Future.value();

  Future<void> _store(Future<void> Function() operation) {
    final next = _storageOperation.then((_) => operation());
    _storageOperation = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<String?> build() async {
    ref.onDispose(() => _expiry?.cancel());
    final value = await ref.read(sessionStorageProvider).read(key: 'session');
    if (value == null) return null;
    try {
      final data = jsonDecode(value) as Map<String, dynamic>;
      final expires = DateTime.parse(data['expiresAt'] as String);
      if (!expires.isAfter(DateTime.now())) {
        await ref.read(sessionStorageProvider).delete(key: 'session');
        return null;
      }
      final token = data['token'] as String;
      await ref.read(sessionCheckProvider)(token);
      _schedule(expires);
      return token;
    } on ApiException catch (e) {
      if (e.statusCode != 401) rethrow;
      await ref.read(sessionStorageProvider).delete(key: 'session');
      return null;
    } on FormatException {
      await ref.read(sessionStorageProvider).delete(key: 'session');
      return null;
    }
  }

  void _schedule(DateTime expires) {
    _expiry?.cancel();
    _expiry = Timer(expires.difference(DateTime.now()), () {
      unawaited(logout());
    });
  }

  Future<void> login(String email, String password,
      {bool register = false}) async {
    final generation = ++_generation;
    final data = await ref
        .read(sessionApiProvider)
        .authenticate(email, password, register: register);
    final token = data['token'] as String;
    final expires = DateTime.parse(data['expiresAt'] as String);
    if (generation != _generation) return;
    final storage = ref.read(sessionStorageProvider);
    await _store(() => storage.write(
        key: 'session',
        value: jsonEncode({
          'token': token,
          'expiresAt': expires.toUtc().toIso8601String(),
        })));
    if (generation != _generation) return;
    _schedule(expires);
    state = AsyncData(token);
  }

  Future<void> logout() async {
    ++_generation;
    _expiry?.cancel();
    state = const AsyncData(null);
    final storage = ref.read(sessionStorageProvider);
    await _store(() => storage.delete(key: 'session'));
  }
}
