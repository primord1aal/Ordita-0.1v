import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'auth_repository.dart';

/// Полный ответ ограничен 12 секундами/1 МиБ, штатная TLS-проверка сохранена.
/// Закрытие реальных сокетов дополняет проверку поколений в контроллере.
class BoundedAuthHttpClient extends http.BaseClient {
  BoundedAuthHttpClient(this.expectedHost);
  final String expectedHost;
  final Set<http.Client> _pending = {};
  bool _closed = false;
  AuthFailure? lastFailure;
  int? lastStatus;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    lastFailure = null;
    lastStatus = null;
    final uri = request.url;
    if (_closed) throw const AuthFailure(AuthFailureKind.cancelled);
    if (uri.scheme != 'https' ||
        uri.host != expectedHost ||
        uri.hasPort ||
        uri.userInfo.isNotEmpty ||
        !(uri.path.startsWith('/auth/v1/') ||
            uri.path.startsWith('/rest/v1/'))) {
      lastFailure = const AuthFailure(AuthFailureKind.unverified);
      throw lastFailure!;
    }
    request.followRedirects = false;
    final client = IOClient(
      HttpClient()..connectionTimeout = const Duration(seconds: 12),
    );
    _pending.add(client);
    try {
      return await (() async {
        final response = await client.send(request);
        lastStatus = response.statusCode;
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > 1024 * 1024) {
            throw const AuthFailure(AuthFailureKind.unverified);
          }
          bytes.addAll(chunk);
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw const AuthFailure(AuthFailureKind.unverified);
        }
        return http.StreamedResponse(
          Stream.value(bytes),
          response.statusCode,
          headers: response.headers,
          contentLength: bytes.length,
          request: request,
          reasonPhrase: response.reasonPhrase,
          isRedirect: false,
          persistentConnection: false,
        );
      })().timeout(const Duration(seconds: 12));
    } on TimeoutException {
      lastFailure = const AuthFailure(AuthFailureKind.timeout);
      throw lastFailure!;
    } on TlsException {
      lastFailure = const AuthFailure(AuthFailureKind.tls);
      throw lastFailure!;
    } on SocketException {
      lastFailure = const AuthFailure(AuthFailureKind.network);
      throw lastFailure!;
    } on http.ClientException {
      lastFailure = const AuthFailure(AuthFailureKind.network);
      throw lastFailure!;
    } on AuthFailure catch (failure) {
      lastFailure = failure;
      rethrow;
    } finally {
      _pending.remove(client);
      client.close();
    }
  }

  void cancelPending() {
    for (final client in _pending.toList()) {
      client.close();
    }
    _pending.clear();
  }

  @override
  void close() {
    _closed = true;
    cancelPending();
  }
}
