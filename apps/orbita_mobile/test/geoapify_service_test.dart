import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/geoapify_service.dart';

import 'maps_test_fakes.dart';

void main() {
  test('Русский адрес, ограниченная выдача и местное предпочтение; нет Auth-заголовка', () async {
    final client = MockClient((request) async {
      expect(request.url.scheme, 'https');
      expect(request.url.host, 'api.geoapify.com');
      expect(request.url.path, '/v1/geocode/autocomplete');
      expect(request.url.queryParameters['text'], 'Чик, улица Ленина');
      expect(request.url.queryParameters['lang'], 'ru');
      expect(request.url.queryParameters['limit'], '5');
      expect(request.url.queryParameters['filter'], 'countrycode:ru');
      expect(
        request.url.queryParameters['bias'],
        startsWith('proximity:82.43,55.0'),
      );
      expect(request.headers.containsKey('authorization'), isFalse);
      expect(request.followRedirects, isFalse);
      return http.Response(
        jsonEncode({
          'results': [
            {'formatted': 'Учебная улица, Чик', 'lat': 55.0, 'lon': 82.43},
          ],
        }),
        200,
        headers: {'content-type': 'application/json; charset=utf-8'},
      );
    });
    final service = GeoapifyAddressService(
      fakeMapKey,
      transport: GeoapifyTransport(clientFactory: () => client),
    );
    addTearDown(service.close);
    final result = await service.search('  Чик, улица Ленина  ');
    expect(result.single.point.latitude, 55.0);
    expect(result.single.label, 'Учебная улица, Чик');
  });
  test(
    'Обратный поиск получает выбранные координаты и русский адрес',
    () async {
      final service = GeoapifyAddressService(
        fakeMapKey,
        transport: GeoapifyTransport(
          clientFactory: () => MockClient((request) async {
            expect(request.url.path, '/v1/geocode/reverse');
            expect(request.url.queryParameters['lat'], '55.01');
            expect(request.url.queryParameters['lon'], '82.44');
            return http.Response(
              jsonEncode({
                'results': [
                  {'formatted': 'Адрес выбранной точки'},
                ],
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        ),
      );
      addTearDown(service.close);
      expect(
        await service.reverse(const GeoPoint(55.01, 82.44)),
        'Адрес выбранной точки',
      );
    },
  );
  test(
    'Пустая выдача остаётся пустой, некорректные координаты не принимаются',
    () async {
      var response = <String, dynamic>{'results': []};
      final service = GeoapifyAddressService(
        fakeMapKey,
        transport: GeoapifyTransport(
          clientFactory: () => MockClient(
            (_) async =>
                http.Response.bytes(utf8.encode(jsonEncode(response)), 200),
          ),
        ),
      );
      addTearDown(service.close);
      expect(await service.search('Ничего'), isEmpty);
      response = {
        'results': [
          {'formatted': 'Неправильная точка', 'lat': 999, 'lon': 82},
        ],
      };
      await expectLater(
        service.search('Ошибка'),
        throwsA(
          isA<MapFailure>().having(
            (e) => e.kind,
            'kind',
            MapFailureKind.invalid,
          ),
        ),
      );
    },
  );
  for (final (code, kind) in [
    (401, MapFailureKind.configuration),
    (403, MapFailureKind.configuration),
    (429, MapFailureKind.limit),
    (503, MapFailureKind.unavailable),
    (302, MapFailureKind.unavailable),
  ]) {
    test(
      'HTTP $code безопасно различим, нет повторов и сырого текста',
      () async {
        var calls = 0;
        final service = GeoapifyAddressService(
          fakeMapKey,
          transport: GeoapifyTransport(
            clientFactory: () => MockClient((_) async {
              calls++;
              return http.Response(
                'raw provider body with $fakeMapKey',
                code,
                headers: {'location': 'https://example.invalid/'},
              );
            }),
          ),
        );
        addTearDown(service.close);
        try {
          await service.search('Чик');
          fail('Expected failure');
        } on MapFailure catch (error) {
          expect(error.kind, kind);
          expect(error.toString(), isNot(contains(fakeMapKey)));
          expect(error.toString(), isNot(contains('raw provider')));
        }
        expect(calls, 1);
      },
    );
  }
  test('Неверный JSON и слишком большой ответ отклоняются', () async {
    var body = 'not json';
    final service = GeoapifyAddressService(
      fakeMapKey,
      transport: GeoapifyTransport(
        clientFactory: () => MockClient((_) async => http.Response(body, 200)),
      ),
    );
    addTearDown(service.close);
    await expectLater(
      service.search('Чик'),
      throwsA(
        isA<MapFailure>().having((e) => e.kind, 'kind', MapFailureKind.invalid),
      ),
    );
    body = 'x' * (256 * 1024 + 1);
    await expectLater(
      service.search('Чик'),
      throwsA(
        isA<MapFailure>().having((e) => e.kind, 'kind', MapFailureKind.invalid),
      ),
    );
  });
  test(
    'Тайм-аут ограничен; поздний ответ не становится успешным результатом',
    () async {
      final pending = Completer<http.Response>();
      final service = GeoapifyAddressService(
        fakeMapKey,
        transport: GeoapifyTransport(
          timeout: const Duration(milliseconds: 20),
          clientFactory: () => MockClient((_) => pending.future),
        ),
      );
      addTearDown(service.close);
      await expectLater(
        service.search('Чик'),
        throwsA(
          isA<MapFailure>().having(
            (e) => e.kind,
            'kind',
            MapFailureKind.timeout,
          ),
        ),
      );
      pending.complete(http.Response('{"results":[]}', 200));
      await Future<void>.delayed(Duration.zero);
    },
  );
  test(
    'Другие серверы, URL с логином и нестандартным портом запрещены до HTTP',
    () async {
      var clients = 0;
      final transport = GeoapifyTransport(
        clientFactory: () {
          clients++;
          return MockClient((_) async => http.Response('', 200));
        },
      );
      addTearDown(transport.close);
      for (final uri in [
        'http://api.geoapify.com/v1/geocode/autocomplete',
        'https://example.invalid/v1/geocode/autocomplete',
        'https://user@api.geoapify.com/v1/geocode/autocomplete',
        'https://api.geoapify.com:444/v1/geocode/autocomplete',
        'https://api.geoapify.com/v1/other',
      ]) {
        await expectLater(
          transport.get(Uri.parse(uri)),
          throwsA(isA<MapFailure>()),
        );
      }
      expect(clients, 0);
    },
  );
}
