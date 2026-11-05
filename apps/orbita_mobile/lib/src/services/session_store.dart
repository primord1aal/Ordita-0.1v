import 'package:flutter_secure_storage/flutter_secure_storage.dart';

abstract interface class SessionStore {
  Future<String?> read();
  Future<void> write(String session);
  Future<void> clear();
}

/// Android Keystore через flutter_secure_storage; ключ разделён по окружениям.
class SecureSessionStore implements SessionStore {
  const SecureSessionStore({
    required this.projectRef,
    this._storage = const FlutterSecureStorage(),
  });
  final String projectRef;
  String get _sessionKey => 'orbita.auth.session.v1.$projectRef';
  final FlutterSecureStorage _storage;
  @override
  Future<String?> read() => _storage.read(key: _sessionKey);
  @override
  Future<void> write(String session) =>
      _storage.write(key: _sessionKey, value: session);
  @override
  Future<void> clear() => _storage.delete(key: _sessionKey);
}
