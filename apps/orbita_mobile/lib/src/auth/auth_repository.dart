import '../domain/contracts.dart';

enum AuthFailureKind {
  network,
  timeout,
  tls,
  invalidCredentials,
  rateLimited,
  server,
  http,
  sessionExpired,
  storage,
  unverified,
  unconfigured,
  cancelled,
}

/// Только безопасный код/HTTP-статус. Текст исключений SDK сюда не копируется.
class AuthFailure implements Exception {
  const AuthFailure(this.kind, {this.httpStatus});
  final AuthFailureKind kind;
  final int? httpStatus;
  String get message => switch (kind) {
    AuthFailureKind.network => 'Нет связи с сервером.',
    AuthFailureKind.timeout => 'Сервер не ответил за отведённое время.',
    AuthFailureKind.tls => 'Не удалось проверить защищённое соединение.',
    AuthFailureKind.invalidCredentials => 'Неверный email или пароль.',
    AuthFailureKind.rateLimited => 'Слишком много попыток. Повторите позже.',
    AuthFailureKind.server => 'Сервер временно недоступен.',
    AuthFailureKind.http =>
      'Сервер вернул HTTP-ошибку${httpStatus == null ? '' : ' $httpStatus'}.',
    AuthFailureKind.sessionExpired => 'Сессия истекла. Войдите заново.',
    AuthFailureKind.storage =>
      'Не удалось безопасно прочитать или сохранить сессию.',
    AuthFailureKind.unverified => 'Не удалось проверить актуальные полномочия.',
    AuthFailureKind.unconfigured =>
      'Тестовый сервер не настроен в этой сборке.',
    AuthFailureKind.cancelled => 'Проверка отменена.',
  };
  @override
  String toString() => 'AuthFailure(${kind.name})';
}

/// В интерфейс не передаются Access/Refresh Token или тело Auth-ответа.
class AuthSession {
  const AuthSession({required this.userId, required this.expiresAt});
  final String userId;
  final DateTime expiresAt;
  bool get expired => !expiresAt.isAfter(DateTime.now());
  bool get needsRefresh =>
      !expiresAt.isAfter(DateTime.now().add(const Duration(seconds: 30)));
}

enum AccessStatus {
  active,
  noRole,
  blocked,
  unknownRole,
  noProfile,
  inconsistent,
  invalidSession,
}

class ServerAccess {
  const ServerAccess({
    required this.userId,
    required this.status,
    this.role,
    this.version,
    this.displayName = '',
  });
  factory ServerAccess.fromJson(
    Map<String, dynamic> data,
    String expectedUserId,
  ) {
    if (data['user_id'] != expectedUserId) {
      throw const AuthFailure(AuthFailureKind.unverified);
    }
    final status = switch (data['status']) {
      'active' => AccessStatus.active,
      'no_role' => AccessStatus.noRole,
      'blocked' => AccessStatus.blocked,
      'unknown_role' => AccessStatus.unknownRole,
      'no_profile' => AccessStatus.noProfile,
      'invalid_session' => AccessStatus.invalidSession,
      _ => AccessStatus.inconsistent,
    };
    final role = switch (data['role']) {
      'passenger' => UserRole.passenger,
      'driver' => UserRole.driver,
      'admin' => UserRole.admin,
      _ => null,
    };
    final version = data['access_version'];
    return ServerAccess(
      userId: expectedUserId,
      status: status == AccessStatus.active && role == null
          ? AccessStatus.unknownRole
          : status == AccessStatus.active && (version is! int || version < 1)
          ? AccessStatus.inconsistent
          : status,
      role: role,
      version: version is int ? version : null,
      displayName: data['display_name'] is String
          ? data['display_name'] as String
          : '',
    );
  }
  final String userId, displayName;
  final AccessStatus status;
  final UserRole? role;
  final int? version;
  bool get active =>
      status == AccessStatus.active &&
      role != null &&
      version != null &&
      version! > 0;
}

abstract interface class AuthRepository {
  bool get configured;
  Future<AuthSession?> restore();
  Future<AuthSession> signIn(String email, String password);
  Future<AuthSession> refresh();
  Future<ServerAccess> fetchAccess();
  Future<void> signOut();
  void cancelPending();
  Future<void> dispose();
}

/// Неподключённая основа для модели интерфейса; никогда не создаёт HTTP-клиент.
class DisconnectedAuthRepository implements AuthRepository {
  @override
  bool get configured => false;
  @override
  Future<AuthSession?> restore() async => null;
  @override
  Future<AuthSession> signIn(String email, String password) async =>
      throw const AuthFailure(AuthFailureKind.unconfigured);
  @override
  Future<AuthSession> refresh() async =>
      throw const AuthFailure(AuthFailureKind.unconfigured);
  @override
  Future<ServerAccess> fetchAccess() async =>
      throw const AuthFailure(AuthFailureKind.unconfigured);
  @override
  Future<void> signOut() async {}
  @override
  void cancelPending() {}
  @override
  Future<void> dispose() async {}
}
