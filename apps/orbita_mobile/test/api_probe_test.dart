import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/backend/api_probe.dart';

import 'backend_configuration_test.dart' show fixtureConfig, fixtureKey;

class FakeProbeTransport implements ProbeTransport {
  ProbeResponse response = const ProbeResponse(
    200,
    '{"name":"GoTrue","version":"fixture"}',
  );
  Future<ProbeResponse> Function()? handler;
  final List<Uri> calls = [];
  int closes = 0;
  @override
  Future<ProbeResponse> get(Uri uri, String publicKey) async {
    calls.add(uri);
    expect(publicKey, fixtureKey);
    return handler == null ? response : handler!();
  }

  @override
  void close() => closes++;
}

void main() {
  test('Без конфигурации HTTP-транспорт не нужен', () async {
    final probe = UnconfiguredApiProbe();
    expect(probe.configured, isFalse);
    expect((await probe.check()).state, ProbeState.unconfigured);
  });

  test('GET направляется только на health точного тестового домена', () async {
    final transport = FakeProbeTransport();
    final probe = HealthApiProbe(
      configuration: fixtureConfig,
      transport: transport,
    );
    final result = await probe.check();
    expect(result.state, ProbeState.ready);
    expect(result.httpStatus, 200);
    expect(transport.calls, [fixtureConfig.healthUri]);
    expect(transport.closes, 1);
  });

  test(
    'Фактический адрес сверяется до HTTP, несовпадение запрещает запрос',
    () async {
      final transport = FakeProbeTransport();
      final probe = HealthApiProbe(
        configuration: fixtureConfig,
        transport: transport,
        requestUri: Uri.https(
          'bbbbbbbbbbbbbbbbbbbb.supabase.co',
          '/auth/v1/health',
        ),
      );
      expect(probe.domainMatches, isFalse);
      expect((await probe.check()).state, ProbeState.domainMismatch);
      expect(transport.calls, isEmpty);
    },
  );

  test('Неожиданный ответ сохраняет наблюдаемый HTTP-код', () async {
    final transport = FakeProbeTransport()
      ..response = const ProbeResponse(200, '<html>fixture</html>');
    final probe = HealthApiProbe(
      configuration: fixtureConfig,
      transport: transport,
    );
    final result = await probe.check();
    expect(result.state, ProbeState.unexpected);
    expect(result.httpStatus, 200);
    expect(result.requestUri, fixtureConfig.healthUri);
  });

  test(
    'Отчёт транспорта о другом адресе не выдаётся за корректный ответ',
    () async {
      final transport = FakeProbeTransport()
        ..response = ProbeResponse(
          200,
          '{"name":"GoTrue","version":"fixture"}',
          requestUri: Uri.https('other.invalid', '/auth/v1/health'),
        );
      final probe = HealthApiProbe(
        configuration: fixtureConfig,
        transport: transport,
      );
      final result = await probe.check();
      expect(result.state, ProbeState.domainMismatch);
      expect(result.httpStatus, 200);
      expect(result.success, isFalse);
    },
  );

  for (final (status, expected) in [
    (401, ProbeState.unauthorized),
    (403, ProbeState.unauthorized),
    (429, ProbeState.rateLimited),
    (302, ProbeState.redirect),
    (503, ProbeState.serverError),
    (404, ProbeState.httpError),
    (408, ProbeState.httpError),
  ]) {
    test(
      'HTTP $status не выдаётся за успешную связь со службой входа',
      () async {
        final transport = FakeProbeTransport()
          ..response = ProbeResponse(status, 'fixture');
        final probe = HealthApiProbe(
          configuration: fixtureConfig,
          transport: transport,
        );
        final result = await probe.check();
        expect(result.state, expected);
        expect(result.success, isFalse);
        expect(transport.calls.length, 1);
      },
    );
  }

  for (final (index, body) in [
    '<html>fixture</html>',
    '{}',
    '{"name":"other","version":"fixture"}',
  ].indexed) {
    test('Неожиданный HTTP 200 не выдаётся за здоровье Auth: $index', () async {
      final transport = FakeProbeTransport()
        ..response = ProbeResponse(200, body);
      final probe = HealthApiProbe(
        configuration: fixtureConfig,
        transport: transport,
      );
      expect((await probe.check()).state, ProbeState.unexpected);
    });
  }

  for (final (error, expected) in [
    (const SocketException('fixture'), ProbeState.networkError),
    (const HandshakeException('fixture'), ProbeState.tlsError),
  ]) {
    test(
      'Ошибка ${expected.name} обработана без отключения проверки сертификата',
      () async {
        final transport = FakeProbeTransport()
          ..handler = () async => throw error;
        final probe = HealthApiProbe(
          configuration: fixtureConfig,
          transport: transport,
        );
        final result = await probe.check();
        expect(result.state, expected);
        expect(result.message, isNot(contains('fixture')));
      },
    );
  }

  test('Таймаут закрывает транспорт, следующая проверка возможна', () async {
    final done = Completer<ProbeResponse>();
    final transport = FakeProbeTransport()..handler = () => done.future;
    final probe = HealthApiProbe(
      configuration: fixtureConfig,
      transport: transport,
      timeout: const Duration(milliseconds: 10),
    );
    expect((await probe.check()).state, ProbeState.timeout);
    expect(transport.closes, 1);
    transport.handler = null;
    expect((await probe.check()).state, ProbeState.ready);
    done.complete(transport.response);
  });

  test('Повторное нажатие не отправляет параллельный запрос', () async {
    final done = Completer<ProbeResponse>();
    final transport = FakeProbeTransport()..handler = () => done.future;
    final probe = HealthApiProbe(
      configuration: fixtureConfig,
      transport: transport,
    );
    final first = probe.check();
    expect((await probe.check()).state, ProbeState.cancelled);
    expect(transport.calls.length, 1);
    probe.dispose();
    done.complete(transport.response);
    expect((await first).state, ProbeState.cancelled);
    expect((await probe.check()).state, ProbeState.cancelled);
    expect(transport.calls.length, 1);
  });
}
