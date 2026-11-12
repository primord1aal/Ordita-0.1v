import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/ui/orbita_map.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'maps_test_fakes.dart';
import 'design_test_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);
  for (final scale in [1.0, 3.2]) {
    testWidgets(
      'Атрибуция ×$scale: все ссылки видимы и не перекрывают controls',
      (tester) async {
        tester.view.physicalSize = const Size(320, 568);
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = scale;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        final session = FakeMapTiles();
        addTearDown(session.close);
        await tester.pumpWidget(
          MaterialApp(
            theme: orbitaTheme(brightness: Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: OrbitaMap(session: session, height: 180),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final attribution = tester.widget<MapAttribution>(
          find.byType(MapAttribution),
        );
        expect(attribution.compact, scale == 3.2);
        final controls = tester.getRect(find.byTooltip('Приблизить карту'));
        for (final label in [
          '© OpenStreetMap',
          '© OpenMapTiles',
          '© CARTO',
          'Powered by Geoapify',
        ]) {
          final text = find.text(label);
          expect(text, findsOneWidget);
          final button = find.ancestor(
            of: text,
            matching: find.byType(TextButton),
          );
          expect(tester.widget<TextButton>(button).onPressed, isNotNull);
          final rect = tester.getRect(button);
          expect(rect.left, greaterThanOrEqualTo(0));
          expect(rect.right, lessThanOrEqualTo(320));
          expect(rect.overlaps(controls), isFalse);
          if (scale == 3.2) {
            expect(rect.top, greaterThanOrEqualTo(180));
            expect(rect.height, greaterThanOrEqualTo(48));
          }
        }
        expect(
          MediaQuery.textScalerOf(tester.element(find.byType(MapAttribution)))
              .scale(11),
          closeTo(11 * scale, 0.01),
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
