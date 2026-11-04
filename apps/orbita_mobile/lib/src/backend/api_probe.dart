import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'test_backend_configuration.dart';

enum ProbeState {
  ready,
  unconfigured,
  timeout,
  tlsError,
  networkError,
  unauthorized,
  rateLimited,
  redirect,
  serverError,
  unexpected,
  cancelled,
}

class ProbeResult {
  const ProbeResult({
    required this.state,
    required this.elapsed,
    required this.checkedAt,
    this.httpStatus,
  });
  final ProbeState state;
  final Duration elapsed;
  final DateTime checkedAt;
  final int? httpStatus;
  bool get success => state == ProbeState.ready;

  String get message => switch (state) {
    ProbeState.ready => 'Служба входа ответила из Android.',
    ProbeState.unconfigured => 'Тестовый проект не настроен в сборке.',
    ProbeState.timeout => 'Сервер не ответил за отведённое время.',
    ProbeState.tlsError => 'Не удалось проверить защищённое соединение.',
    ProbeState.networkError => 'Нет связи с сервером.',
    ProbeState.unauthorized => 'Сервер отклонил клиентскую конфигурацию.',
    ProbeState.rateLimited => 'Слишком много запросов. Повторите позже.',
    ProbeState.redirect =>
      'Сервер предложил другой адрес. Проверка остановлена.',
    ProbeState.serverError => 'Служба входа временно недоступна.',
    ProbeState.unexpected => 'Получен неожиданный ответ. Проверка остановлена.',
    ProbeState.cancelled => 'Проверка отменена.',
  };
}

class ProbeResponse {
  const ProbeResponse(this.status, this.body);
  final int status;
  final String body;
}

abstract interface class ProbeTransport {
  Future<ProbeResponse> get(Uri uri, String publicKey);
  void close();
}

/// Только GET health. Без паролей, токенов сессии, редиректов и вывода ответа.
class IoProbeTransport implements ProbeTransport {
  HttpClient? _client;
  @override
  Future<ProbeResponse> get(Uri uri, String publicKey) async {
    if (_client != null) throw StateError('Проверка уже выполняется.');
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _client = client;
    try {
      final request = await client.getUrl(uri);
      request
        ..followRedirects = false
        ..headers.set('apikey', publicKey)
        ..headers.set(HttpHeaders.acceptHeader, 'application/json');
      final response = await request.close();
      final data = <int>[];
      await for (final chunk in response) {
        if (data.length + chunk.length > 8192) {
          throw const FormatException('Ответ превышает предел диагностики.');
        }
        data.addAll(chunk);
      }
      return ProbeResponse(response.statusCode, utf8.decode(data));
    } finally {
      client.close(force: true);
      if (identical(_client, client)) _client = null;
    }
  }

  @override
  void close() {
    _client?.close(force: true);
    _client = null;
  }
}

abstract interface class ApiProbe {
  bool get configured;
  Future<ProbeResult> check();
  void dispose();
}

/// Без конфигурации транспорт даже не создаётся.
class UnconfiguredApiProbe implements ApiProbe {
  @override
  bool get configured => false;
  @override
  Future<ProbeResult> check() async => ProbeResult(
    state: ProbeState.unconfigured,
    elapsed: Duration.zero,
    checkedAt: DateTime.now(),
  );
  @override
  void dispose() {}
}

class HealthApiProbe implements ApiProbe {
  HealthApiProbe({
    required this.configuration,
    required this.transport,
    this.timeout = const Duration(seconds: 15),
  }) {
    if (!configuration.isValid) {
      throw ArgumentError('Тестовая конфигурация не подтверждена.');
    }
  }
  final TestBackendConfiguration configuration;
  final ProbeTransport transport;
  final Duration timeout;
  bool _busy = false, _disposed = false;
  @override
  bool get configured => true;

  @override
  Future<ProbeResult> check() async {
    final watch = Stopwatch()..start();
    ProbeResult result(ProbeState state, [int? httpStatus]) => ProbeResult(
      state: state,
      elapsed: watch.elapsed,
      checkedAt: DateTime.now(),
      httpStatus: httpStatus,
    );
    if (_disposed || _busy) return result(ProbeState.cancelled);
    _busy = true;
    try {
      final response = await transport
          .get(configuration.healthUri, configuration.publishableKey)
          .timeout(timeout);
      if (_disposed) return result(ProbeState.cancelled);
      final code = response.status;
      if (code == 401 || code == 403) {
        return result(ProbeState.unauthorized, code);
      }
      if (code == 429) return result(ProbeState.rateLimited, code);
      if (code >= 300 && code < 400) return result(ProbeState.redirect, code);
      if (code >= 500) return result(ProbeState.serverError, code);
      if (code != 200) return result(ProbeState.unexpected, code);
      final body = jsonDecode(response.body);
      if (body is! Map<String, dynamic> ||
          body['name'] != 'GoTrue' ||
          body['version'] is! String) {
        return result(ProbeState.unexpected, code);
      }
      return result(ProbeState.ready, code);
    } on TimeoutException {
      return result(ProbeState.timeout);
    } on HandshakeException {
      return result(ProbeState.tlsError);
    } on SocketException {
      return result(ProbeState.networkError);
    } on HttpException {
      return result(ProbeState.networkError);
    } on FormatException {
      return result(ProbeState.unexpected);
    } catch (_) {
      return result(_disposed ? ProbeState.cancelled : ProbeState.unexpected);
    } finally {
      watch.stop();
      transport.close();
      _busy = false;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    transport.close();
  }
}

ApiProbe createApiProbe() {
  const config = TestBackendConfiguration.fromEnvironment();
  if (!config.isValid) return UnconfiguredApiProbe();
  return HealthApiProbe(configuration: config, transport: IoProbeTransport());
}
