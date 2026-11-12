// Layout previews use fake tiles/addresses/route, with no external requests.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';

import '../test/fake_auth_repository.dart';
import '../test/fake_device.dart';
import '../test/maps_test_fakes.dart';
import '../test/test_helpers.dart';

void main() {
  final output = Directory(Platform.environment['ORBITA_UI_CAPTURE_DIR']!);
  setUpAll(() async {
    for (final entry in {
      'Inter': [
        'assets/fonts/Inter-Regular.ttf',
        'assets/fonts/Inter-SemiBold.ttf',
        'assets/fonts/Inter-Bold.ttf',
      ],
      'MaterialIcons': [
        '/workspace/flutter-sdk/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
      ],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final path in entry.value) {
        loader.addFont(
          Future.value(ByteData.sublistView(File(path).readAsBytesSync())),
        );
      }
      await loader.load();
    }
    output.createSync(recursive: true);
  });
  for (final scene in ['addresses', 'search-keyboard', 'picker', 'route']) {
    testWidgets('Map sheet preview $scene', (tester) async {
      setViewport(tester, const Size(360, 800), 1.3);
      final boundaryKey = GlobalKey();
      final settings = MapSettings(initialKey: fakeMapKey);
      final theme = ThemeSettings();
      tester.binding.platformDispatcher.platformBrightnessTestValue =
          Brightness.light;
      addTearDown(
        tester.binding.platformDispatcher.clearPlatformBrightnessTestValue,
      );
      final service = FakeAddressService()
        ..reverseLabel = 'Чик, улица Пушкина, 24';
      final keyboard = scene == 'search-keyboard';
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundaryKey,
          child: Stack(
            textDirection: TextDirection.ltr,
            children: [
              OrbitaApp(
                device: FakeDevice(),
                authRepository: FakeAuthRepository()..saved = testSession(),
                themeSettings: theme,
                mapSettings: settings,
                addressServiceFactory: (_) => service,
                routeServiceFactory: (_) => FakeRouteService(),
                tileSessionFactory: (_) => FakeMapTiles(),
              ),
              if (keyboard)
                const Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: 300,
                  child: ColoredBox(
                    color: Color(0xffd8d9d3),
                    child: Center(
                      child: Text(
                        'Системная клавиатура',
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontFamily: 'Inter',
                          fontSize: 16,
                          color: Color(0xff5e6859),
                          decoration: TextDecoration.none,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (scene == 'search-keyboard') {
        await tester.enterText(
          find.byKey(const Key('destination')),
          'Чик, Пушкина',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 300);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
      }
      if (scene == 'picker') {
        await tester.tap(find.byKey(const Key('pickup-on-map')));
        await tester.pumpAndSettle();
      }
      if (scene == 'route') {
        for (final item in [
          (
            'pickup',
            const AddressPlace(
              'Чик, Комсомольская улица, 19',
              GeoPoint(55, 82.43),
            ),
          ),
          (
            'destination',
            const AddressPlace(
              'Прокудское, улица Ленина, 5',
              GeoPoint(55.025, 82.46),
            ),
          ),
        ]) {
          service.results = [item.$2];
          await tester.enterText(
            find.byKey(Key(item.$1)),
            'Поиск ${item.$2.label}',
          );
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pumpAndSettle();
          await scrollTo(tester, find.text(item.$2.label));
          await tester.tap(find.text(item.$2.label));
          await tester.pumpAndSettle();
        }
        await tester.pump(const Duration(milliseconds: 400));
        await tester.pumpAndSettle();
      }
      await tester.runAsync(() async {
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        File('${output.path}/$scene.png')
            .writeAsBytesSync(bytes!.buffer.asUint8List());
        image.dispose();
      });
      tester.view.resetViewInsets();
      await tester.pumpWidget(const SizedBox());
      theme.dispose();
      settings.dispose();
      expect(tester.takeException(), isNull);
    });
  }
}
