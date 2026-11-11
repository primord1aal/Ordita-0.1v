// Реальные Flutter-виджеты с искусственными адресами и локальными тестовыми тайлами.
// Карта на снимках — тестовая заглушка; сетевые запросы отсутствуют.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/map_tiles.dart';
import 'package:orbita_mobile/src/screens/map_picker_screen.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'maps_test_fakes.dart';
import 'test_helpers.dart';

class _DesignTiles extends MapTileSession {
  _DesignTiles(Brightness brightness)
    : _png = File('test/fixtures/map-stub-${brightness.name}.png')
          .readAsBytesSync(),
      super(fakeMapKey);
  final Uint8List _png;
  @override
  Future<Uint8List> tile(TileCoordinates coordinate) async => _png;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final fonts = Platform.environment['ORBITA_FLUTTER_FONT_DIR'];
    if (fonts == null) throw StateError('Укажите ORBITA_FLUTTER_FONT_DIR');
    final inter = FontLoader('Inter');
    for (final file in [
      'Inter-Regular.ttf',
      'Inter-Medium.ttf',
      'Inter-SemiBold.ttf',
      'Inter-Bold.ttf',
    ]) {
      inter.addFont(
        Future.value(
          ByteData.sublistView(File('assets/fonts/$file').readAsBytesSync()),
        ),
      );
    }
    await inter.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(
        Future.value(
          ByteData.sublistView(
            File('$fonts/MaterialIcons-Regular.otf').readAsBytesSync(),
          ),
        ),
      );
    await icons.load();
  });

  Future<void> mount(
    WidgetTester tester, {
    required ThemeMode mode,
    Size size = const Size(390, 844),
    double scale = 1,
  }) async {
    SharedPreferences.setMockInitialValues({
      ThemeSettings.storageKey: mode.name,
    });
    setViewport(tester, size, scale);
    final theme = ThemeSettings();
    await theme.load();
    final maps = MapSettings(initialKey: fakeMapKey);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      maps.dispose();
      theme.dispose();
    });
    await tester.pumpWidget(
      OrbitaApp(
        device: FakeDevice(),
        authRepository: FakeAuthRepository()..saved = testSession(),
        mapSettings: maps,
        themeSettings: theme,
        addressServiceFactory: (_) => FakeAddressService(),
        tileSessionFactory: (_) => _DesignTiles(
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('Пассажир ${mode.name}: карта — тестовая заглушка', (
      tester,
    ) async {
      await mount(tester, mode: mode);
      await expectLater(
        find.byType(Scaffold).first,
        matchesGoldenFile('goldens/block2-passenger-${mode.name}.png'),
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('360×740: карта — тестовая заглушка', (tester) async {
    await mount(tester, mode: ThemeMode.light, size: const Size(360, 740));
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/block2-passenger-360.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Два адреса: карта — тестовая заглушка', (tester) async {
    await mount(tester, mode: ThemeMode.light);
    await scrollTo(tester, find.byKey(const Key('destination')));
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/block2-addresses.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Поиск: карта — тестовая заглушка', (tester) async {
    await mount(tester, mode: ThemeMode.light);
    await scrollTo(tester, find.byKey(const Key('pickup')));
    await tester.enterText(find.byKey(const Key('pickup')), 'Чик, улица');
    await tester.pump(const Duration(milliseconds: 500));
    tester.testTextInput.hide();
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    expect(find.text(examplePlace.label), findsOneWidget);
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/block2-search.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Выбор точки: карта — тестовая заглушка', (tester) async {
    await mount(tester, mode: ThemeMode.light);
    await scrollTo(tester, find.byKey(const Key('destination-on-map')));
    await tester.tap(find.byKey(const Key('destination-on-map')));
    await tester.pumpAndSettle();
    expect(find.byType(MapPickerScreen), findsOneWidget);
    await expectLater(
      find.byType(Scaffold).last,
      matchesGoldenFile('goldens/block2-map-picker.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Планшет: карта — тестовая заглушка', (tester) async {
    await mount(tester, mode: ThemeMode.light, size: const Size(800, 1280));
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/block2-tablet.png'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Шрифт ×3.2: карта — тестовая заглушка', (tester) async {
    await mount(tester, mode: ThemeMode.light, scale: 3.2);
    await expectLater(
      find.byType(Scaffold).first,
      matchesGoldenFile('goldens/block2-text-3.2.png'),
    );
    expect(tester.takeException(), isNull);
  });
}
