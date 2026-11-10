// Модельные снимки: искусственные HTTP/тайлы/аккаунт, не реальная картография.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';

import '../test/fake_auth_repository.dart';
import '../test/fake_device.dart';
import '../test/maps_test_fakes.dart';
import '../test/test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final fonts = Platform.environment['ORBITA_FLUTTER_FONT_DIR']!;
  final output = Directory(
    Platform.environment['ORBITA_UI_CAPTURE_DIR'] ?? 'build/map-ui-captures',
  );
  final width = double.parse(
    Platform.environment['ORBITA_CAPTURE_WIDTH'] ?? '360',
  );
  final height = double.parse(
    Platform.environment['ORBITA_CAPTURE_HEIGHT'] ?? '800',
  );
  setUpAll(() async {
    for (final entry in {
      'Roboto': ['Roboto-Regular.ttf', 'Roboto-Bold.ttf'],
      'MaterialIcons': ['MaterialIcons-Regular.otf'],
    }.entries) {
      final loader = FontLoader(entry.key);
      for (final file in entry.value) {
        loader.addFont(
          Future.value(
            ByteData.sublistView(File('$fonts/$file').readAsBytesSync()),
          ),
        );
      }
      await loader.load();
    }
    output.createSync(recursive: true);
  });
  for (final section in ['addresses', 'suggestions', 'picker', 'map-setup']) {
    for (final scale in [1.0, 3.2]) {
      testWidgets('Карта: $section $width×$height / $scale', (tester) async {
        setViewport(tester, Size(width, height), scale);
        final boundaryKey = GlobalKey();
        final settings = MapSettings(initialKey: fakeMapKey);
        await tester.pumpWidget(
          RepaintBoundary(
            key: boundaryKey,
            child: OrbitaApp(
              device: FakeDevice(),
              authRepository: FakeAuthRepository()..saved = testSession(),
              mapSettings: settings,
              addressServiceFactory: (_) => FakeAddressService(),
              tileSessionFactory: (_) => FakeMapTiles(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (section == 'suggestions') {
          await scrollTo(tester, find.byKey(const Key('pickup')));
          await tester.enterText(find.byKey(const Key('pickup')), 'Чик, улица');
          await tester.pump(const Duration(milliseconds: 500));
          tester.testTextInput.hide();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pumpAndSettle();
        }
        if (section == 'picker') {
          await scrollTo(tester, find.byKey(const Key('destination-on-map')));
          await tester.tap(find.byKey(const Key('destination-on-map')));
          await tester.pumpAndSettle();
        }
        if (section == 'map-setup') {
          Navigator.of(tester.element(find.byType(PassengerScreen)))
              .pushNamed('/map-settings');
          await tester.pumpAndSettle();
        }
        await tester.runAsync(() async {
          final boundary =
              boundaryKey.currentContext!.findRenderObject()!
                  as RenderRepaintBoundary;
          final image = await boundary.toImage(pixelRatio: 1.5);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          File(
            '${output.path}/${width.toInt()}x${height.toInt()}-$section-$scale.png',
          ).writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
        expect(tester.takeException(), isNull);
      });
    }
  }
}
