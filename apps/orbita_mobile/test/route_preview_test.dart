import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/geoapify_service.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/route_preview.dart';

const _key = 'fake_route_key_123456';
const _from = GeoPoint(55.0, 82.43), _to = GeoPoint(55.02, 82.45);

Map<String, dynamic> _response({
  String type = 'MultiLineString',
  Object? coordinates,
}) => {
  'type': 'FeatureCollection',
  'features': [
    {
      'type': 'Feature',
      'properties': {'distance': 3210, 'time': 420.5},
      'geometry': {
        'type': type,
        'coordinates':
            coordinates ??
            [
              [
                [82.43, 55.0],
                [82.44, 55.01],
                [82.45, 55.02],
              ],
            ],
      },
    },
  ],
};

GeoapifyRouteService _service(Object body) => GeoapifyRouteService(
  _key,
  transport: GeoapifyTransport(
    clientFactory: () => MockClient(
      (_) async => http.Response.bytes(utf8.encode(jsonEncode(body)), 200),
    ),
  ),
);

class _FakeRoutes implements RouteService {
  final calls = <(GeoPoint, GeoPoint)>[];
  final pending = <Completer<RoutePreview?>>[];
  int cancellations = 0;
  bool closed = false;

  @override
  Future<RoutePreview?> route(GeoPoint pickup, GeoPoint destination) {
    calls.add((pickup, destination));
    final result = Completer<RoutePreview?>();
    pending.add(result);
    return result.future;
  }

  @override
  void cancel() => cancellations++;
  @override
  void close() => closed = true;
}

RoutePreview _route(double latitude) => RoutePreview(
  lines: [
    [GeoPoint(latitude, 82.43), _to],
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Geoapify drive uses exact two points and real road geometry', () async {
    final service = GeoapifyRouteService(
      _key,
      transport: GeoapifyTransport(
        clientFactory: () => MockClient((request) async {
          expect(request.url.scheme, 'https');
          expect(request.url.host, 'api.geoapify.com');
          expect(request.url.path, '/v1/routing');
          expect(
            request.url.queryParameters['waypoints'],
            '55.0,82.43|55.02,82.45',
          );
          expect(request.url.queryParameters['mode'], 'drive');
          expect(request.url.queryParameters['units'], 'metric');
          expect(request.url.queryParameters['format'], 'geojson');
          expect(request.url.queryParameters['apiKey'], _key);
          expect(request.url.queryParameters.containsKey('details'), isFalse);
          expect(request.headers.containsKey('authorization'), isFalse);
          expect(request.followRedirects, isFalse);
          return http.Response.bytes(utf8.encode(jsonEncode(_response())), 200);
        }),
      ),
    );
    addTearDown(service.close);
    final route = (await service.route(_from, _to))!;
    expect(route.points.length, 3);
    expect(route.points[1].latitude, 55.01);
    expect(route.points[1].longitude, 82.44);
    expect(route.distanceMeters, 3210);
    expect(route.durationSeconds, 420.5);
    expect(() => route.lines.single.add(_from), throwsUnsupportedError);
  });

  test('LineString and separate lines preserve provider geometry', () async {
    for (final (type, coordinates, lineCount) in [
      (
        'LineString',
        [
          [82.43, 55.0],
          [82.45, 55.02],
        ],
        1,
      ),
      (
        'MultiLineString',
        [
          [
            [82.43, 55.0],
            [82.44, 55.01],
          ],
          [
            [82.445, 55.015],
            [82.45, 55.02],
          ],
        ],
        2,
      ),
    ]) {
      final service = _service(_response(type: type, coordinates: coordinates));
      addTearDown(service.close);
      final route = (await service.route(_from, _to))!;
      expect(route.lines.length, lineCount);
      // Disjoint provider lines stay separate, with no invented connector.
      expect(route.lines.every((line) => line.length == 2), isTrue);
    }
  });

  test('No route is null, never a straight-line fallback', () async {
    final service = _service({'type': 'FeatureCollection', 'features': []});
    addTearDown(service.close);
    expect(await service.route(_from, _to), isNull);
  });

  test('Malformed, out-of-range and excessive geometry is rejected', () async {
    final invalid = [
      {},
      _response(type: 'Point'),
      _response(coordinates: []),
      _response(
        coordinates: [
          [
            [82.43, 55.0],
          ],
        ],
      ),
      _response(
        coordinates: [
          [
            [82.43, 55.0],
            [82.45, 999],
          ],
        ],
      ),
      _response(
        coordinates: [
          [
            [82.43, 55.0],
            ['raw', 55.02],
          ],
        ],
      ),
      _response(
        coordinates: [
          List.generate(10001, (_) => [82.43, 55.0]),
        ],
      ),
    ];
    for (final body in invalid) {
      final service = _service(body);
      addTearDown(service.close);
      await expectLater(
        service.route(_from, _to),
        throwsA(
          isA<MapFailure>().having(
            (e) => e.kind,
            'kind',
            MapFailureKind.invalid,
          ),
        ),
      );
    }
  });

  test('Invalid key and coordinates make no network request', () async {
    var calls = 0;
    GeoapifyRouteService makeService(String key) => GeoapifyRouteService(
      key,
      transport: GeoapifyTransport(
        clientFactory: () => MockClient((_) async {
          calls++;
          return http.Response('{}', 200);
        }),
      ),
    );
    final missing = makeService(''), valid = makeService(_key);
    addTearDown(missing.close);
    addTearDown(valid.close);
    await expectLater(missing.route(_from, _to), throwsA(isA<MapFailure>()));
    await expectLater(
      valid.route(const GeoPoint(999, 0), _to),
      throwsA(isA<MapFailure>()),
    );
    expect(calls, 0);
  });

  testWidgets(
    'A pair is debounced and identical coordinate values deduplicated',
    (tester) async {
      final settings = MapSettings(initialKey: _key), fake = _FakeRoutes();
      final controller = RoutePreviewController(
        settings,
        serviceFactory: (_) => fake,
      );
      addTearDown(controller.dispose);
      addTearDown(settings.dispose);
      controller.update(_from, null, enabled: true);
      await tester.pump(const Duration(seconds: 1));
      expect(fake.calls, isEmpty);
      controller.update(_from, _to, enabled: true);
      controller.update(
        const GeoPoint(55.0, 82.43),
        const GeoPoint(55.02, 82.45),
        enabled: true,
      );
      await tester.pump(const Duration(milliseconds: 349));
      expect(fake.calls, isEmpty);
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.calls.length, 1);
      fake.pending.single.complete(_route(55.0));
      await tester.pump(const Duration(milliseconds: 1));
      expect(controller.route, isNotNull);
      expect(controller.busy, isFalse);
      controller.update(_from, _to, enabled: true);
      await tester.pump(const Duration(seconds: 1));
      expect(fake.calls.length, 1);
    },
  );

  testWidgets('Changed endpoints and background reject late results', (
    tester,
  ) async {
    // Advance FakeAsync's clock: pump() alone does not fire Timer.zero.
    final settings = MapSettings(initialKey: _key), fake = _FakeRoutes();
    final controller = RoutePreviewController(
      settings,
      serviceFactory: (_) => fake,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    addTearDown(settings.dispose);
    controller.update(_from, _to, enabled: true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.update(const GeoPoint(55.01, 82.43), _to, enabled: true);
    await tester.pump(const Duration(milliseconds: 1));
    fake.pending.first.complete(_route(54));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.route, isNull);
    expect(controller.busy, isTrue);
    fake.pending[1].complete(_route(55.01));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.route!.points.first.latitude, 55.01);
    controller.update(_from, _to, enabled: true);
    await tester.pump(const Duration(milliseconds: 1));
    controller.update(_from, _to, enabled: false);
    expect(controller.route, isNull);
    expect(controller.busy, isFalse);
    fake.pending.last.complete(_route(53));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.route, isNull);
    expect(controller.message, isNull);
    expect(fake.cancellations, greaterThan(0));
  });

  testWidgets('Clearing or replacing key cancels old service and route', (
    tester,
  ) async {
    final settings = MapSettings(initialKey: _key);
    final services = <_FakeRoutes>[];
    final controller = RoutePreviewController(
      settings,
      serviceFactory: (_) {
        final fake = _FakeRoutes();
        services.add(fake);
        return fake;
      },
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    addTearDown(settings.dispose);
    controller.update(_from, _to, enabled: true);
    await tester.pump(const Duration(milliseconds: 1));
    await settings.clear();
    expect(services.first.closed, isTrue);
    services.first.pending.single.complete(_route(54));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.route, isNull);
    expect(services[1].calls, isEmpty);
    expect(controller.message, contains('Настройте карту'));
    await settings.save('another_fake_route_key');
    await tester.pump(const Duration(milliseconds: 1));
    expect(services[2].calls.length, 1);
    services[2].pending.single.complete(_route(55));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.route, isNotNull);
  });

  testWidgets('No-route failure stays honest and retry is explicit', (
    tester,
  ) async {
    final settings = MapSettings(initialKey: _key), fake = _FakeRoutes();
    final controller = RoutePreviewController(
      settings,
      serviceFactory: (_) => fake,
      debounce: Duration.zero,
    );
    addTearDown(controller.dispose);
    addTearDown(settings.dispose);
    controller.update(_from, _to, enabled: true);
    await tester.pump(const Duration(milliseconds: 1));
    fake.pending.single.complete(null);
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.route, isNull);
    expect(controller.message, contains('Маршрут по дорогам не найден'));
    controller.update(_from, _to, enabled: true);
    await tester.pump(const Duration(milliseconds: 1));
    expect(fake.calls.length, 1);
    controller.retry();
    expect(fake.calls.length, 2);
    fake.pending.last.completeError(const MapFailure(MapFailureKind.network));
    await tester.pump(const Duration(milliseconds: 1));
    expect(controller.message, contains('Проверьте связь'));
    expect(controller.busy, isFalse);
  });

  testWidgets(
    'Same endpoints and disposal never produce a route request/result',
    (tester) async {
      final settings = MapSettings(initialKey: _key), fake = _FakeRoutes();
      final controller = RoutePreviewController(
        settings,
        serviceFactory: (_) => fake,
        debounce: Duration.zero,
      );
      addTearDown(settings.dispose);
      controller.update(_from, const GeoPoint(55.0, 82.43), enabled: true);
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.calls, isEmpty);
      expect(controller.message, contains('совпадают'));
      controller.update(_from, _to, enabled: true);
      await tester.pump(const Duration(milliseconds: 1));
      controller.dispose();
      fake.pending.single.complete(_route(55));
      await tester.pump(const Duration(milliseconds: 1));
      expect(fake.closed, isTrue);
      expect(controller.route, isNull);
    },
  );
}
