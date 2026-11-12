import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
  Future<Uint8List> get(Uri uri, {int maxBytes = 256 * 1024}) async {
    calls.add(uri);
    return base64Decode(
      'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=',
    );
  }

  @override
  void cancel() {
    cancels++;
    super.cancel();
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
      await show();
      expect(count(), 8);
      await settings.save('another_artificial_key_0123456789');
      await tester.pumpAndSettle();
      expect(transports.length, 2);
      expect(count(), 12);
      await settings.clear();
      await tester.pumpAndSettle();
      expect(count(), 12);
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    },
  );
}
