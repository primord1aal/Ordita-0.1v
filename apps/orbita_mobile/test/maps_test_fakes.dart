import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_map/flutter_map.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/geoapify_service.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/map_tiles.dart';
import 'package:orbita_mobile/src/maps/route_preview.dart';

const fakeMapKey = 'local_fake_map_key_0123456789';
const examplePlace = AddressPlace(
  'Учебная улица, 12, Чик',
  GeoPoint(55.003, 82.431),
);

class FakeAddressService implements AddressService {
  final queries = <String>[];
  final points = <GeoPoint>[];
  Completer<List<AddressPlace>>? pending;
  Completer<String?>? reversePending;
  MapFailure? failure;
  List<AddressPlace> results = [examplePlace];
  String? reverseLabel = 'Учебная точка, Чик';
  int cancels = 0;
  @override
  Future<List<AddressPlace>> search(String query) async {
    queries.add(query);
    if (pending != null) return pending!.future;
    if (failure != null) throw failure!;
    return results;
  }

  @override
  Future<String?> reverse(GeoPoint point) async {
    points.add(point);
    if (reversePending != null) return reversePending!.future;
    if (failure != null) throw failure!;
    return reverseLabel;
  }

  @override
  void cancel() {
    cancels++;
  }

  @override
  void close() {
    cancel();
  }
}

class FakeMapKeyStore implements MapKeyStore {
  String? saved;
  bool fail = false;
  @override
  Future<String?> read() async {
    if (fail) throw StateError('Fake storage failure');
    return saved;
  }

  @override
  Future<void> write(String value) async {
    if (fail) throw StateError('Fake storage failure');
    saved = value;
  }

  @override
  Future<void> delete() async {
    saved = null;
  }
}

class FakeMapTiles extends MapTileSession {
  FakeMapTiles() : super(fakeMapKey);
  @override
  Future<Uint8List> tile(TileCoordinates coordinate) async => base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
  );
}

class FailingMapTiles extends MapTileSession {
  FailingMapTiles() : super(fakeMapKey);
  @override
  Future<Uint8List> tile(TileCoordinates coordinate) async =>
      throw const MapFailure(MapFailureKind.limit);
}

class FakeRouteService implements RouteService {
  final calls = <(GeoPoint, GeoPoint)>[];
  @override
  Future<RoutePreview?> route(GeoPoint pickup, GeoPoint destination) async {
    calls.add((pickup, destination));
    return RoutePreview(
      lines: [
        [pickup, const GeoPoint(55.012, 82.44), destination],
      ],
      distanceMeters: 4200,
      durationSeconds: 540,
    );
  }

  @override
  void cancel() {}
  @override
  void close() {}
}
