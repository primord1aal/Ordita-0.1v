import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/geoapify_service.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/map_tiles.dart';
import 'package:orbita_mobile/src/ui/driver_map.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'maps_test_fakes.dart';

class _Tiles extends GeoapifyTransport {
  final calls = <Uri>[];
  int cancels = 0;
  @override
  Future<Uint8List> get(
    Uri uri, {
    int maxBytes = 256 * 1024,
    Object? requestGroup,
  }) async {
    calls.add(uri);
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }

  @override
  void cancel({Object? requestGroup}) {
    cancels++;
    super.cancel(requestGroup: requestGroup);
  }
}

void main() {
  testWidgets('Водительская карта: closed/background/no-key = 0 HTTP', (
    tester,
  ) async {
    final settings = MapSettings(initialKey: fakeMapKey);
    final tiles = _Tiles();
    var sessions = 0;
    MapTileSession create(String key) {
      sessions++;
      return MapTileSession(
        key,
        transport: tiles,
        minimumInterval: Duration.zero,
      );
    }

    Future<void> show({bool enabled = false, bool foreground = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          home: Scaffold(
            body: DriverMap(
              mapSettings: settings,
              enabled: enabled,
              foreground: foreground,
              height: 180,
              tileSessionFactory: create,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await show();
    expect(tiles.calls.length, 0);
    expect(sessions, 0);
    await show(enabled: true, foreground: false);
    expect(tiles.calls.length, 0);
    expect(sessions, 0);
    await settings.clear();
    await show(enabled: true);
    expect(tiles.calls.length, 0);
    expect(sessions, 0);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets('role refresh pause preserves driver map state and camera', (
    tester,
  ) async {
    final settings = MapSettings(initialKey: fakeMapKey);
    final tiles = _Tiles();
    final session = MapTileSession(
      fakeMapKey,
      transport: tiles,
      minimumInterval: Duration.zero,
    );
    Future<void> show(bool active) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          home: Scaffold(
            body: DriverMap(
              mapSettings: settings,
              enabled: active,
              height: 256,
              tileSessionFactory: (_) => session,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show(true);
    final state = tester.state(find.byType(FlutterMap));
    final requests = tiles.calls.length;
    await show(false);
    expect(identical(tester.state(find.byType(FlutterMap)), state), isTrue);
    expect(tiles.calls.length, requests);
    await show(true);
    expect(identical(tester.state(find.byType(FlutterMap)), state), isTrue);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets('GPS доступен без тайлов только на рабочем экране', (
    tester,
  ) async {
    final settings = MapSettings();
    var locationRequests = 0;
    var sessions = 0;
    final locate = find.byTooltip('Моё местоположение');

    Future<void> show({bool foreground = true, bool locating = false}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(),
          home: Scaffold(
            body: DriverMap(
              mapSettings: settings,
              foreground: foreground,
              locating: locating,
              onLocate: () => locationRequests++,
              tileSessionFactory: (_) {
                sessions++;
                return FakeMapTiles();
              },
            ),
          ),
        ),
      );
    }

    await show();
    await tester.tap(locate);
    expect(locationRequests, 1);
    await show(locating: true);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    await show(foreground: false);
    expect(
      tester.widget<IconButton>(find.byType(IconButton)).onPressed,
      isNull,
    );
    expect(sessions, 0);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets('Принятая поездка показывает точки и не сбрасывает камеру', (
    tester,
  ) async {
    final settings = MapSettings(initialKey: fakeMapKey);
    final map = find.byType(FlutterMap);
    const pickup = GeoPoint(55.11, 82.52);
    const destination = GeoPoint(55.13, 82.54);

    Future<void> show({
      String? tripId,
      GeoPoint? location,
      bool foreground = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(),
          home: Scaffold(
            body: DriverMap(
              mapSettings: settings,
              height: 300,
              foreground: foreground,
              tripId: tripId,
              pickup: tripId == null ? null : AddressPlace('Подача', pickup),
              destination: tripId == null
                  ? null
                  : AddressPlace('Назначение', destination),
              focusPoint: location,
              tileSessionFactory: (_) => FakeMapTiles(),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
    }

    await show();
    final camera = tester.widget<FlutterMap>(map).mapController!;
    expect(
      camera.camera.center.latitude,
      closeTo(localMapCenter.latitude, .01),
    );
    await show(tripId: 'first');
    expect(find.byTooltip('Откуда: Подача'), findsOneWidget);
    expect(find.byTooltip('Куда: Назначение'), findsOneWidget);
    expect(camera.camera.center.latitude, closeTo(55.12, .01));

    const panned = LatLng(55.117, 82.529);
    camera.move(panned, 16);
    await show(tripId: 'first');
    await show(tripId: 'first', foreground: false);
    await show(tripId: 'first');
    expect(tester.widget<FlutterMap>(map).mapController, same(camera));
    expect(camera.camera.center, panned);

    await show(tripId: 'first', location: const GeoPoint(55.115, 82.528));
    expect(camera.camera.center, const LatLng(55.115, 82.528));
    await show();
    expect(find.byTooltip('Откуда: Подача'), findsNothing);
    expect(find.byTooltip('Куда: Назначение'), findsNothing);
    expect(tester.widget<FlutterMap>(map).mapController, same(camera));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });

  testWidgets(
    'Явное открытие, rebuild, reopen, тема и ключ: точный HTTP-счёт',
    (tester) async {
      tester.view.physicalSize = const Size(256, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = MapSettings(initialKey: fakeMapKey);
      final transports = <_Tiles>[];
      MapTileSession create(String key) {
        final transport = _Tiles();
        transports.add(transport);
        return MapTileSession(
          key,
          transport: transport,
          minimumInterval: Duration.zero,
        );
      }

      int count() =>
          transports.fold(0, (sum, value) => sum + value.calls.length);

      Future<void> show({
        bool active = true,
        bool foreground = true,
        Brightness brightness = Brightness.light,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            theme: orbitaTheme(brightness: brightness),
            home: Scaffold(
              body: SingleChildScrollView(
                child: DriverMap(
                  mapSettings: settings,
                  enabled: active,
                  foreground: foreground,
                  height: 256,
                  tileSessionFactory: create,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      }

      await show(active: false);
      expect(count(), 0);
      await show();
      expect(count(), 4);
      await show();
      expect(count(), 4);
      expect(transports.length, 1);
      await show(active: false);
      final cancellations = transports.single.cancels;
      expect(cancellations, greaterThanOrEqualTo(1));
      await show();
      expect(count(), 4);
      await show(foreground: false);
      expect(count(), 4);
      await tester.pump(const Duration(seconds: 2));
      expect(count(), 4);
      await show(brightness: Brightness.dark);
      expect(count(), 8);
      expect(transports.single.calls.last.path, contains('/dark-matter/'));
      await show(brightness: Brightness.dark);
      expect(count(), 8);
      await show();
      expect(count(), 8);
      await settings.save('another_artificial_key_0123456789');
      await tester.pumpAndSettle();
      expect(transports.length, 2);
      expect(count(), 12);
      expect(transports.last.calls.last.path, contains('/osm-carto/'));
      await settings.clear();
      await tester.pumpAndSettle();
      expect(count(), 12);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
}
