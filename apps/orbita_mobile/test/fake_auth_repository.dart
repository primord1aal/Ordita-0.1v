import 'dart:async';

import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';

const userA = '00000000-0000-4000-8000-000000000101';
const userB = '00000000-0000-4000-8000-000000000102';
AuthSession testSession([String userId = userA]) => AuthSession(
  userId: userId,
  expiresAt: DateTime.now().add(const Duration(hours: 1)),
);
ServerAccess testAccess([
  UserRole role = UserRole.passenger,
  String userId = userA,
]) => ServerAccess(
  userId: userId,
  status: AccessStatus.active,
  role: role,
  version: 1,
);

/// Только искусственная реализация AuthRepository. Нет SDK, HTTP или паролей облака.
class FakeAuthRepository implements AuthRepository {
  @override
  bool configured = true;
  AuthSession? saved;
  AuthSession? loginSession;
  ServerAccess access = testAccess();
  AuthFailure? restoreError, loginError, refreshError, accessError, logoutError;
  Completer<AuthSession?>? restorePending;
  Completer<AuthSession>? loginPending;
  Completer<ServerAccess>? accessPending;
  int restores = 0,
      logins = 0,
      refreshes = 0,
      fetches = 0,
      logouts = 0,
      cancels = 0;
  bool disposed = false;
  @override
  Future<AuthSession?> restore() async {
    restores++;
    if (restoreError != null) throw restoreError!;
    return restorePending?.future ?? saved;
  }

  @override
  Future<AuthSession> signIn(String email, String password) async {
    logins++;
    if (loginError != null) throw loginError!;
    if (loginPending != null) return loginPending!.future;
    saved = loginSession ?? testSession();
    return saved!;
  }

  @override
  Future<AuthSession> refresh() async {
    refreshes++;
    if (refreshError != null) throw refreshError!;
    saved = testSession(saved?.userId ?? userA);
    return saved!;
  }

  @override
  Future<ServerAccess> fetchAccess() async {
    fetches++;
    if (accessError != null) throw accessError!;
    return accessPending?.future ?? access;
  }

  @override
  Future<void> signOut() async {
    logouts++;
    if (logoutError != null) throw logoutError!;
    saved = null;
  }

  @override
  void cancelPending() {
    cancels++;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}
