import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/backend/api_probe.dart';

// Настоящий HTTP, но только на loopback внутри сетевой изоляции CI.
void main() {
  Future<(HttpServer, Uri)> server() async {
    final http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => http.close(force: true));
    return (http, Uri.parse('http://127.0.0.1:${http.port}/auth/v1/health'));
  }

  test(
    'Транспорт делает только GET с публичным ключом без токена сессии',
    () async {
      final (http, uri) = await server();
      final received = Completer<void>();
      http.listen((request) async {
        expect(request.method, 'GET');
        expect(request.headers.value('apikey'), 'artificial-public-key');
        expect(request.headers.value('authorization'), isNull);
        request.response.write('{"name":"GoTrue","version":"fixture"}');
        await request.response.close();
        received.complete();
      });
      final transport = IoProbeTransport();
      final response = await transport.get(uri, 'artificial-public-key');
      expect(response.status, 200);
      await received.future;
    },
  );

  test('Перенаправление не получает повторный запрос или ключ', () async {
    final (http, uri) = await server();
    var requests = 0;
    http.listen((request) async {
      requests++;
      request.response
        ..statusCode = 302
        ..headers.set('location', '/redirected');
      await request.response.close();
    });
    final transport = IoProbeTransport();
    expect((await transport.get(uri, 'artificial-public-key')).status, 302);
    expect(requests, 1);
  });

  test('Размер ответа ограничен', () async {
    final (http, uri) = await server();
    http.listen((request) async {
      request.response.write('x' * 9000);
      await request.response.close();
    });
    final transport = IoProbeTransport();
    await expectLater(
      transport.get(uri, 'artificial-public-key'),
      throwsFormatException,
    );
  });
}
