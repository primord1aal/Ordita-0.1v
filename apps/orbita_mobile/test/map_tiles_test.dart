import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
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
