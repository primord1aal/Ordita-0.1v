import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbita_mobile/src/maps/geoapify_service.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/orders/order_models.dart';

void main() {
  test('managed maps configure automatically and send authenticated proxy request without provider key', () async {
    final settings = MapSettings.managed(
      (source) async => (
        uri: Uri.https('test.supabase.co', '/functions/v1/orbita-maps', {
          'path': source.path,
          ...Map.of(source.queryParameters)..remove('apiKey'),
        }),
        headers: {'Authorization': 'Bearer synthetic-user-session'},
      ),
    );
    expect(settings.configured, isTrue);
    expect(settings.store, isNull);
    final transport = GeoapifyTransport(
      proxy: (source) async => (
        uri: Uri.https('test.supabase.co', '/functions/v1/orbita-maps', {
          'path': source.path,
        }),
        headers: {'Authorization': 'Bearer synthetic-user-session'},
      ),
      clientFactory: () => MockClient((request) async {
        expect(request.url.host, 'test.supabase.co');
        expect(request.url.queryParameters.containsKey('apiKey'), isFalse);
        expect(
          request.headers['Authorization'],
          'Bearer synthetic-user-session',
        );
        return http.Response(jsonEncode({'results': []}), 200);
      }),
    );
    final service = GeoapifyAddressService(
      settings.clientKey,
      transport: transport,
    );
    expect(await service.search('Пушкина 20'), isEmpty);
    service.close();
    settings.dispose();
  });
  for (final status in [401, 403, 429, 503]) {
    test('map HTTP $status is classified safely and can be retried', () async {
      final transport = GeoapifyTransport(
        clientFactory: () => MockClient(
          (_) async => http.Response('private upstream error', status),
        ),
      );
      final service = GeoapifyAddressService(
        'synthetic-map-key-1234',
        transport: transport,
      );
      await expectLater(
        service.search('Титова 22'),
        throwsA(
          isA<MapFailure>().having(
            (f) => f.kind,
            'kind',
            status == 429
                ? MapFailureKind.limit
                : status == 503
                ? MapFailureKind.unavailable
                : MapFailureKind.configuration,
          ),
        ),
      );
      service.close();
    });
  }
  test('missing RPC is distinguished from transient network errors', () {
    expect(
      OrderFailure.fromServerMessage('PGRST202').kind,
      OrderFailureKind.serverNotReady,
    );
    expect(
      OrderFailure.fromServerMessage('42883').kind,
      OrderFailureKind.serverNotReady,
    );
    expect(
      OrderFailure.fromServerMessage('private upstream error').kind,
      OrderFailureKind.unavailable,
    );
  });
}
