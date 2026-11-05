import 'package:supabase_flutter/supabase_flutter.dart';

import '../services/session_store.dart';
import 'auth_repository.dart';

/// Совместим с LocalStorage SDK 2.18.3. Используется явно репозиторием,
/// без фонового recoverSession Supabase.initialize и без SharedPreferences.
class SecureAuthStorage extends LocalStorage {
  SecureAuthStorage(this.store);
  final SessionStore store;
  Future<void> _tail = Future.value();
  Future<T> _ordered<T>(Future<T> Function() action) {
    final operation = _tail.then((_) => action());
    _tail = operation.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return operation.catchError(
      (Object _) => throw const AuthFailure(AuthFailureKind.storage),
    );
  }

  @override
  Future<void> initialize() async {}
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<String?> accessToken() => _ordered(store.read);
  @override
  Future<void> persistSession(String persistSessionString) =>
      _ordered(() => store.write(persistSessionString));
  @override
  Future<void> removePersistedSession() => _ordered(store.clear);
}
