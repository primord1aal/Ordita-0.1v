import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Адаптер будущей сессии SDK. На этапе 2 реальные данные не записываются.
class SecureSessionStore {
  const SecureSessionStore([this._storage = const FlutterSecureStorage()]);
  static const _sessionKey = 'orbita.session.v1';
  final FlutterSecureStorage _storage;
  Future<String?> read() => _storage.read(key: _sessionKey);
  Future<void> write(String session) =>
      _storage.write(key: _sessionKey, value: session);
  Future<void> clear() => _storage.delete(key: _sessionKey);
}
