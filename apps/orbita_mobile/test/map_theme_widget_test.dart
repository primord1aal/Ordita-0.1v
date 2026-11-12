import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/map_tiles.dart';
import 'package:orbita_mobile/src/ui/orbita_map.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'maps_test_fakes.dart';

void main() {
  testWidgets('Подробный светлый слой остаётся читаемым в обеих темах', (
    tester,
  ) async {
    final session = FakeMapTiles();
    addTearDown(session.close);
    addTearDown(
      tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
    );

    Future<void> show(ThemeMode mode) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          darkTheme: orbitaTheme(brightness: Brightness.dark),
          themeMode: mode,
          home: Scaffold(body: OrbitaMap(session: session)),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    }

    await show(ThemeMode.light);
    expect(session.style, MapTileStyle.osmCarto);
    await show(ThemeMode.dark);
    expect(session.style, MapTileStyle.osmCarto);

    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.light;
    await show(ThemeMode.system);
    expect(session.style, MapTileStyle.osmCarto);
    tester.binding.platformDispatcher.platformBrightnessTestValue =
        Brightness.dark;
    await tester.pumpAndSettle();
    expect(session.style, MapTileStyle.osmCarto);
    expect(tester.takeException(), isNull);
  });
}
