import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart' as sdk;

import '../backend/test_backend_configuration.dart';
import '../orders/driver_push_registration.dart';
import '../services/session_store.dart';
import 'auth_repository.dart';
import '../orders/dispatch_controller.dart';
import '../orders/trip_history.dart';
import '../orders/order_models.dart';
import 'bounded_http_client.dart';
import 'secure_auth_storage.dart';

class SupabaseAuthRepository
    implements AuthRepository, DispatchApi, DriverPushApi, TripHistoryApi {
  SupabaseAuthRepository(this.configuration)
    : storage = SecureAuthStorage(
        SecureSessionStore(projectRef: configuration.projectRef),
      ) {
    if (!configuration.isValid) {
      throw const AuthFailure(AuthFailureKind.unconfigured);
    }
  }
  final TestBackendConfiguration configuration;
  final SecureAuthStorage storage;
  sdk.SupabaseClient? _client;
  BoundedAuthHttpClient? _http;
  StreamSubscription<sdk.AuthState>? _events;
  int _generation = 0;
  bool _disposed = false;
  @override
  bool get configured => configuration.isValid;
  sdk.SupabaseClient get _sdk {
    if (_disposed) throw const AuthFailure(AuthFailureKind.cancelled);
    if (_client == null) {
      _http = BoundedAuthHttpClient(configuration.healthUri.host);
      _client = sdk.SupabaseClient(
        configuration.url.replaceAll(RegExp(r'/$'), ''),
        configuration.publishableKey,
        httpClient: _http,
        authOptions: const sdk.AuthClientOptions(autoRefreshToken: false),
      );
      // Нет вывода сырых Auth-ошибок и автоматической записи событий на диск.
      _events = _client!.auth.onAuthStateChange.listen(
        (_) {},
        onError: (Object _, StackTrace _) {},
      );
    }
    return _client!;
  }

  void _current(int generation) {
    if (_disposed || generation != _generation) {
      throw const AuthFailure(AuthFailureKind.cancelled);
    }
  }

  AuthSession _view(sdk.Session session) {
    if (session.expiresAt == null || session.user.id.isEmpty) {
      throw const AuthFailure(AuthFailureKind.unverified);
    }
    return AuthSession(
      userId: session.user.id,
      expiresAt: DateTime.fromMillisecondsSinceEpoch(session.expiresAt! * 1000),
    );
  }

  Future<AuthSession> _persist(sdk.Session? session, int generation) async {
    _current(generation);
    if (session == null) {
      throw const AuthFailure(AuthFailureKind.sessionExpired);
    }
    final view = _view(session);
    await storage.persistSession(jsonEncode(session.toJson()));
    _current(generation);
    return view;
  }

  Future<T> _operation<T>(Future<T> Function(int generation) action) async {
    final generation = _generation;
    try {
      final result = await action(generation);
      _current(generation);
      return result;
    } catch (error) {
      _current(generation);
      final failure = _safeFailure(error);
      // Только подтверждённо недействительный refresh удаляет сохранённую сессию.
      if (error is sdk.AuthException &&
          const {
            'refresh_token_not_found',
            'refresh_token_already_used',
            'session_not_found',
            'user_not_found',
          }.contains(error.code)) {
        await storage.removePersistedSession();
      }
      throw failure;
    }
  }

  @override
  Future<AuthSession?> restore() => _operation((generation) async {
    final saved = await storage.accessToken();
    _current(generation);
    if (saved == null) return null;
    try {
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, dynamic>) throw const FormatException();
      final session = sdk.Session.fromJson(decoded);
      if (session == null) throw const FormatException();
      if (session.isExpired) {
        // В GoTrue 2.27.3 recoverSession при autoRefreshToken=false НЕ
        // обновляет истёкший токен. Используем явный публичный refreshSession.
        final token = session.refreshToken;
        if (token == null) {
          throw const AuthFailure(AuthFailureKind.sessionExpired);
        }
        return await _persist(
          (await _sdk.auth.refreshSession(token)).session,
          generation,
        );
      }
      await _sdk.auth.recoverSession(saved);
      _current(generation);
      return _view(session);
    } on FormatException {
      throw const AuthFailure(AuthFailureKind.storage);
    }
  });
  @override
  Future<AuthSession> signIn(String email, String password) =>
      _operation((generation) async {
        final response = await _sdk.auth.signInWithPassword(
          email: email.trim(),
          password: password,
        );
        return _persist(response.session, generation);
      });
  @override
  Future<AuthSession> refresh() => _operation((generation) async {
    if (_sdk.auth.currentSession == null) {
      final saved = await storage.accessToken();
      _current(generation);
      if (saved == null) {
        throw const AuthFailure(AuthFailureKind.sessionExpired);
      }
      final decoded = jsonDecode(saved);
      if (decoded is! Map<String, dynamic>) {
        throw const AuthFailure(AuthFailureKind.storage);
      }
      final session = sdk.Session.fromJson(decoded);
      final token = session?.refreshToken;
      if (token == null) {
        throw const AuthFailure(AuthFailureKind.sessionExpired);
      }
      return _persist(
        (await _sdk.auth.refreshSession(token)).session,
        generation,
      );
    }
    return _persist((await _sdk.auth.refreshSession()).session, generation);
  });
  @override
  Future<ServerAccess> fetchAccess() => _operation((generation) async {
    final userId = _sdk.auth.currentSession?.user.id;
    if (userId == null) throw const AuthFailure(AuthFailureKind.sessionExpired);
    final result = await _sdk.rpc('orbita_get_access');
    _current(generation);
    // REST SDK может обновить JWT; сохраняем актуальную сессию явно.
    await _persist(_sdk.auth.currentSession, generation);
    if (result is! Map<String, dynamic>) {
      throw const AuthFailure(AuthFailureKind.unverified);
    }
    return ServerAccess.fromJson(result, userId);
  });
  Future<({Uri uri, Map<String, String> headers})> mapRequest(
    Uri source,
  ) async {
    final session = _sdk.auth.currentSession;
    if (session == null || session.isExpired) {
      throw const OrderFailure(OrderFailureKind.sessionRequired);
    }
    return (
      uri: Uri.https(
        configuration.healthUri.host,
        '/functions/v1/orbita-maps',
        {
          'path': source.path,
          ...Map.of(source.queryParameters)..remove('apiKey'),
        },
      ),
      headers: {
        'Authorization': 'Bearer ${session.accessToken}',
        'apikey': configuration.publishableKey,
      },
    );
  }

  @override
  SessionStore orderIntentStore(String userId) => SecureSessionStore(
    projectRef: '${configuration.projectRef}.order-intent.$userId',
  );

  @override
  Future<Object?> dispatch(String action, Map<String, Object?> payload) async {
    final generation = _generation;
    if (_sdk.auth.currentSession == null) {
      throw const OrderFailure(OrderFailureKind.sessionRequired);
    }
    try {
      final result = await _sdk.rpc(
        'orbita_dispatch',
        params: {'p_action': action, 'p_payload': payload},
      );
      _current(generation);
      await _persist(_sdk.auth.currentSession, generation);
      return result;
    } on sdk.PostgrestException catch (error) {
      throw OrderFailure.fromServerMessage(
        const {'PGRST202', '42883'}.contains(error.code)
            ? error.code
            : error.message,
      );
    }
  }

  @override
  Future<Object?> loadTripHistory({
    required bool driver,
    HistoryTrip? before,
  }) async {
    final generation = _generation;
    if (_sdk.auth.currentSession == null) {
      throw const OrderFailure(OrderFailureKind.sessionRequired);
    }
    try {
      final result = await _sdk.rpc(
        'orbita_order_history',
        params: {
          'p_role': driver ? 'driver' : 'passenger',
          if (before != null) 'p_before_at': before.createdAt.toIso8601String(),
          if (before != null) 'p_before_id': before.id,
        },
      );
      _current(generation);
      await _persist(_sdk.auth.currentSession, generation);
      return result;
    } on sdk.PostgrestException catch (error) {
      throw OrderFailure.fromServerMessage(
        const {'PGRST202', '42883'}.contains(error.code)
            ? error.code
            : error.message,
      );
    }
  }

  bool _hasBoundPushDevice = false;

  @override
  Future<bool> bindDriverPushDevice(String? token) async {
    final generation = _generation;
    if (_sdk.auth.currentSession == null) return false;
    final result = await _sdk.rpc(
      'orbita_driver_push_device',
      params: {'p_token': token},
    );
    _current(generation);
    if (result == true) _hasBoundPushDevice = token != null;
    return result == true;
  }

  @override
  Future<bool> startDriverHeartbeat() async {
    final session = _sdk.auth.currentSession;
    if (session == null || session.isExpired) return false;
    return await DriverPushRegistration.platformChannel.invokeMethod<bool>(
          'startHeartbeat',
          {
            'projectUrl': configuration.url,
            'publishableKey': configuration.publishableKey,
            'accessToken': session.accessToken,
          },
        ) ??
        false;
  }

  @override
  void cancelPending() {
    _generation++;
    _http?.cancelPending();
  }

  @override
  Future<void> signOut() async {
    if (_hasBoundPushDevice) {
      _hasBoundPushDevice = false;
      try {
        await bindDriverPushDevice(null).timeout(const Duration(seconds: 2));
      } catch (_) {
        // Sign-out still revokes the session and its device binding.
      }
    }
    cancelPending();
    final old = _client;
    final transport = _http;
    _client = null;
    _http = null;
    final subscription = _events;
    _events = null;
    try {
      await storage.removePersistedSession();
      // Локальная сессия уже удалена. Отзыв текущего refresh на сервере —
      // ограниченная попытка, без обещания выхода всех устройств при отсутствии сети.
      try {
        await old?.auth
            .signOut(scope: sdk.SignOutScope.local)
            .timeout(const Duration(seconds: 10));
      } catch (_) {}
    } finally {
      transport?.close();
      await subscription?.cancel();
      await old?.dispose();
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    cancelPending();
    _http?.close();
    await _events?.cancel();
    await _client?.dispose();
  }

  AuthFailure _safeFailure(Object error) {
    if (error is AuthFailure) return error;
    // GoTrue оборачивает ошибки транспорта; используем собственный безопасный
    // признак, а не разбираем сырое сообщение SDK с возможным телом ответа.
    if (_http?.lastFailure != null) return _http!.lastFailure!;
    if (error is TimeoutException) {
      return const AuthFailure(AuthFailureKind.timeout);
    }
    if (error is TlsException) return const AuthFailure(AuthFailureKind.tls);
    if (error is SocketException || error is http.ClientException) {
      return const AuthFailure(AuthFailureKind.network);
    }
    if (error is sdk.AuthException) {
      final status = int.tryParse(error.statusCode ?? '');
      if (error.code == 'invalid_credentials') {
        return const AuthFailure(AuthFailureKind.invalidCredentials);
      }
      if (status == 429) return const AuthFailure(AuthFailureKind.rateLimited);
      if (const {
        'refresh_token_not_found',
        'refresh_token_already_used',
        'session_not_found',
        'session_expired',
        'user_not_found',
      }.contains(error.code)) {
        return const AuthFailure(AuthFailureKind.sessionExpired);
      }
      if (error is sdk.AuthRetryableFetchException && status == null) {
        return const AuthFailure(AuthFailureKind.network);
      }
      if (status != null && status >= 500) {
        return AuthFailure(AuthFailureKind.server, httpStatus: status);
      }
      return AuthFailure(AuthFailureKind.http, httpStatus: status);
    }
    if (error is sdk.PostgrestException) {
      final status = _http?.lastStatus;
      if (status == 429) return const AuthFailure(AuthFailureKind.rateLimited);
      if (status != null && status >= 500) {
        return AuthFailure(AuthFailureKind.server, httpStatus: status);
      }
      if (const {'PGRST301', 'PGRST302', 'PGRST303'}.contains(error.code)) {
        return const AuthFailure(AuthFailureKind.sessionExpired);
      }
      return const AuthFailure(AuthFailureKind.unverified);
    }
    return const AuthFailure(AuthFailureKind.unverified);
  }
}

AuthRepository createAuthRepository() {
  const configuration = TestBackendConfiguration.fromEnvironment();
  return configuration.isValid
      ? SupabaseAuthRepository(configuration)
      : DisconnectedAuthRepository();
}
