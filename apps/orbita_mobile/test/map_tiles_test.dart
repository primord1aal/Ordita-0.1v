import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/geoapify_service.dart';
import 'package:orbita_mobile/src/maps/map_tiles.dart';

import 'maps_test_fakes.dart';

class FakeTileTransport extends GeoapifyTransport {
  final calls = <Uri>[];
  Completer<Uint8List>? pending;
  MapFailure? failure;
  @override
  Future<Uint8List> get(Uri uri, {int maxBytes = 256 * 1024}) async {
    calls.add(uri);
    if (failure != null) throw failure!;
    return pending?.future ?? Uint8List.fromList([1, 2, 3]);
  }
}

void main() {
  test('Транспорт допускает только два утверждённых стиля Geoapify', () async {
    final transport = GeoapifyTransport(
      clientFactory: () => MockClient((_) async => http.Response('tile', 200)),
    );
    addTearDown(transport.close);
    for (final style in ['positron', 'dark-matter']) {
      final bytes = await transport.get(
        Uri.https('maps.geoapify.com', '/v1/tile/$style/8/10/10.png', {
          'apiKey': fakeMapKey,
        }),
      );
      expect(bytes, isNotEmpty);
    }
    await expectLater(
      transport.get(
        Uri.https('maps.geoapify.com', '/v1/tile/unknown/8/10/10.png', {
          'apiKey': fakeMapKey,
        }),
      ),
      throwsA(
        isA<MapFailure>().having(
          (error) => error.kind,
          'kind',
          MapFailureKind.configuration,
        ),
      ),
    );
  });

  test('Тема меняет URL и не смешивает кэш одинаковых координат', () async {
    final transport = FakeTileTransport();
    final session = MapTileSession(
      fakeMapKey,
      transport: transport,
      minimumInterval: Duration.zero,
    );
    addTearDown(session.close);
    const coordinate = TileCoordinates(10, 10, 8);
    session.setStyle(MapTileStyle.positron);
    await session.tile(coordinate);
    await session.tile(coordinate);
    session.setStyle(MapTileStyle.positron);
    expect(transport.calls.length, 1);
    expect(transport.calls.single.path, '/v1/tile/positron/8/10/10.png');
    session.setStyle(MapTileStyle.darkMatter);
    await session.tile(coordinate);
    expect(transport.calls.length, 2);
    expect(transport.calls.last.path, '/v1/tile/dark-matter/8/10/10.png');
    session.setStyle(MapTileStyle.positron);
    await session.tile(coordinate);
    expect(transport.calls.length, 2);
    expect(session.style, MapTileStyle.positron);
  });

  test(
    'Общий RAM-кэш различает ключи и стили, но не владеет запросами',
    () async {
      final cache = MapTileCache();
      final firstTransport = FakeTileTransport();
      final secondTransport = FakeTileTransport();
      final otherKeyTransport = FakeTileTransport();
      final first = MapTileSession(
        fakeMapKey,
        cache: cache,
        transport: firstTransport,
        minimumInterval: Duration.zero,
      );
      final second = MapTileSession(
        fakeMapKey,
        cache: cache,
        transport: secondTransport,
        minimumInterval: Duration.zero,
      );
      final other = MapTileSession(
        'another_artificial_key_0123456789',
        cache: cache,
        transport: otherKeyTransport,
        minimumInterval: Duration.zero,
      );
      addTearDown(first.close);
      addTearDown(second.close);
      addTearDown(other.close);
      const coordinate = TileCoordinates(10, 10, 8);
      await first.tile(coordinate);
      await second.tile(coordinate);
      expect(firstTransport.calls.length, 1);
      expect(secondTransport.calls.length, 0);
      first.close();
      await second.tile(coordinate);
      expect(secondTransport.calls.length, 0);
      second.setStyle(MapTileStyle.positron);
      await second.tile(coordinate);
      expect(secondTransport.calls.length, 1);
      other.setStyle(MapTileStyle.positron);
      await other.tile(coordinate);
      expect(otherKeyTransport.calls.length, 1);
      expect(cache.toString(), 'OrbitaTileCache');
      expect(cache.toString(), isNot(contains(fakeMapKey)));
    },
  );

  test(
    'Отмена и закрытие одного владельца не отменяют запрос другого',
    () async {
      final cache = MapTileCache();
      final a = FakeTileTransport()..pending = Completer<Uint8List>();
      final b = FakeTileTransport()..pending = Completer<Uint8List>();
      final first = MapTileSession(
        fakeMapKey,
        cache: cache,
        transport: a,
        minimumInterval: Duration.zero,
      );
      final second = MapTileSession(
        fakeMapKey,
        cache: cache,
        transport: b,
        minimumInterval: Duration.zero,
      );
      addTearDown(second.close);
      final old = first.tile(const TileCoordinates(1, 1, 4));
      final rejected = expectLater(old, throwsA(isA<MapFailure>()));
      final live = second.tile(const TileCoordinates(2, 1, 4));
      first.close();
      a.pending!.complete(Uint8List.fromList([1]));
      b.pending!.complete(Uint8List.fromList([2]));
      await rejected;
      expect(await live, orderedEquals([2]));
      await second.tile(const TileCoordinates(2, 1, 4));
      expect(a.calls.length, 1);
      expect(b.calls.length, 1);
    },
  );

  test('Без ключа сессия не вызывает HTTP-транспорт', () async {
    final transport = FakeTileTransport();
    final session = MapTileSession('', transport: transport);
    addTearDown(session.close);
    await expectLater(
      session.tile(const TileCoordinates(1, 1, 4)),
      throwsA(isA<MapFailure>()),
    );
    expect(transport.calls, isEmpty);
  });

  test('Смена темы отменяет старый ответ до записи в кэш', () async {
    final transport = FakeTileTransport()..pending = Completer<Uint8List>();
    final session = MapTileSession(
      fakeMapKey,
      transport: transport,
      minimumInterval: Duration.zero,
    );
    addTearDown(session.close);
    const coordinate = TileCoordinates(10, 10, 8);
    final old = session.tile(coordinate);
    final rejection = expectLater(
      old,
      throwsA(
        isA<MapFailure>().having(
          (error) => error.kind,
          'kind',
          MapFailureKind.cancelled,
        ),
      ),
    );
    session.setStyle(MapTileStyle.positron);
    transport.pending!.complete(Uint8List.fromList([1]));
    await rejection;
    transport.pending = null;
    await session.tile(coordinate);
    expect(transport.calls.length, 2);
    expect(transport.calls.last.path, '/v1/tile/positron/8/10/10.png');
  });

  test('Ошибка квоты не повторяется при перестроении слоя карты', () async {
    final transport = FakeTileTransport()
      ..failure = const MapFailure(MapFailureKind.limit);
    final session = MapTileSession(
      fakeMapKey,
      transport: transport,
      minimumInterval: Duration.zero,
    );
    addTearDown(session.close);
    await expectLater(
      session.tile(const TileCoordinates(1, 1, 4)),
      throwsA(isA<MapFailure>()),
    );
    await expectLater(
      session.tile(const TileCoordinates(2, 1, 4)),
      throwsA(isA<MapFailure>()),
    );
    expect(transport.calls.length, 1);
    transport.failure = null;
    session.retry();
    await session.tile(const TileCoordinates(2, 1, 4));
    expect(transport.calls.length, 2);
  });
  test(
    'Одинаковый фрагмент загружается один раз и читается из RAM-кэша',
    () async {
      final transport = FakeTileTransport()..pending = Completer<Uint8List>();
      final session = MapTileSession(
        fakeMapKey,
        transport: transport,
        minimumInterval: Duration.zero,
      );
      addTearDown(session.close);
      const coordinate = TileCoordinates(10, 10, 8);
      final first = session.tile(coordinate), second = session.tile(coordinate);
      transport.pending!.complete(Uint8List.fromList([1, 2, 3]));
      expect(await first, orderedEquals(await second));
      expect(await session.tile(coordinate), orderedEquals([1, 2, 3]));
      expect(transport.calls.length, 1);
      expect(transport.calls.single.host, 'maps.geoapify.com');
    },
  );
  test(
    'После отмены поздний фрагмент не становится успешно загруженным',
    () async {
      final transport = FakeTileTransport()..pending = Completer<Uint8List>();
      final session = MapTileSession(
        fakeMapKey,
        transport: transport,
        minimumInterval: Duration.zero,
      );
      addTearDown(session.close);
      final response = session.tile(const TileCoordinates(1, 1, 4));
      final rejected = expectLater(
        response,
        throwsA(
          isA<MapFailure>().having(
            (e) => e.kind,
            'kind',
            MapFailureKind.cancelled,
          ),
        ),
      );
      session.cancel();
      transport.pending!.complete(Uint8List.fromList([1]));
      await rejected;
      transport.pending = null;
      await session.tile(const TileCoordinates(1, 1, 4));
      expect(transport.calls.length, 2);
    },
  );
  test('Одновременно не больше четырёх HTTP-загрузок', () async {
    final transport = FakeTileTransport()..pending = Completer<Uint8List>();
    final session = MapTileSession(
      fakeMapKey,
      transport: transport,
      minimumInterval: Duration.zero,
    );
    addTearDown(session.close);
    final futures = [
      for (var i = 0; i < 8; i++) session.tile(TileCoordinates(i, 1, 4)),
    ];
    await Future<void>.delayed(Duration.zero);
    expect(transport.calls.length, 4);
    transport.pending!.complete(Uint8List.fromList([1, 2]));
    await Future.wait(futures);
    expect(transport.calls.length, 8);
  });
  test('Кэш ограничен 96 фрагментами, старые вытесняются', () async {
    final transport = FakeTileTransport();
    final session = MapTileSession(
      fakeMapKey,
      transport: transport,
      minimumInterval: Duration.zero,
    );
    addTearDown(session.close);
    for (var i = 0; i < 97; i++) {
      await session.tile(TileCoordinates(i, 1, 8));
    }
    await session.tile(const TileCoordinates(96, 1, 8));
    expect(transport.calls.length, 97);
    await session.tile(const TileCoordinates(0, 1, 8));
    expect(transport.calls.length, 98);
  });
  test('Диагностическое имя изображения не содержит ключ или URI', () {
    final session = MapTileSession(fakeMapKey);
    addTearDown(session.close);
    final image = OrbitaTileProvider(session)
        .getImage(const TileCoordinates(1, 1, 4), TileLayer());
    expect(image.toString(), 'OrbitaMapTile');
    expect(image.toString(), isNot(contains(fakeMapKey)));
    expect(image.toString(), isNot(contains('https:')));
  });
}
