import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';
import 'package:orbita_mobile/src/orders/order_models.dart';

import 'dispatch_controller_test.dart' show FakeApi, passenger;

import 'package:orbita_mobile/src/ui/adaptive_navigation.dart';
import 'package:orbita_mobile/src/ui/shift_control.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'fake_device.dart';
import 'test_helpers.dart';

void main() {
  testWidgets(
    'normal build hides diagnostics and rejects diagnostic route/native entry',
    (tester) async {
      final device = FakeDevice()..launchRequested = true;
      await tester.pumpWidget(OrbitaApp(device: device));
      await tester.pumpAndSettle();
      expect(device.openCallback, isNull);
      expect(find.text('Проверка устройства'), findsNothing);
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.pushNamed('/device-check');
      await tester.pumpAndSettle();
      expect(find.text('Этот раздел недоступен.'), findsOneWidget);
      expect(find.byKey(const Key('location-card')), findsNothing);
      navigator.pop();
      await tester.pumpAndSettle();
      navigator.pushNamed('/map-settings');
      await tester.pumpAndSettle();
      expect(find.text('Этот раздел недоступен.'), findsOneWidget);
      expect(find.text('API-ключ Geoapify'), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'ordinary account settings contain theme and permissions without technical tools',
    (tester) async {
      await openPreview(tester, 'Пассажир', diagnosticsEnabled: false);
      await openProfile(tester);
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('theme-system')), findsOneWidget);
      await tester.ensureVisible(find.byKey(const Key('permission-settings')));
      expect(find.byKey(const Key('permission-settings')), findsOneWidget);
      await tester.ensureVisible(find.text('О приложении'));
      await tester.tap(find.text('О приложении'));
      await tester.pumpAndSettle();
      expect(find.text('Проверка устройства'), findsNothing);
      expect(find.byKey(const Key('driver-demo-entry')), findsNothing);
      expect(find.text('Настройка карт'), findsNothing);
      expect(find.text('Лицензии'), findsOneWidget);
    },
  );

  testWidgets(
    'confirmed online track stays neutral and thumb/text centers align',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(18),
              child: ShiftControl(
                confirmedOnline: true,
                available: true,
                requestChange: (_) async {},
              ),
            ),
          ),
        ),
      );
      final track = tester.widget<Container>(
        find.byKey(const Key('shift-track')),
      );
      final palette = OrbitaPalette.of(
        tester.element(find.byKey(const Key('shift-track'))),
      );
      expect(
        (track.decoration! as BoxDecoration).color,
        palette.surfaceVariant,
      );
      final thumb = tester.getRect(find.byKey(const Key('shift-thumb')));
      final bounds = tester.getRect(find.byKey(const Key('shift-track')));
      expect((thumb.center.dy - bounds.center.dy).abs(), lessThan(1));
      expect(thumb.width, greaterThanOrEqualTo(48));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'server failure explains disabled order without scrolling ordinary phone form',
    (tester) async {
      setViewport(tester, const Size(360, 740), 1);
      final api = FakeApi()
        ..handler = ((action, payload) async {
          throw const OrderFailure(OrderFailureKind.serverNotReady);
        });
      final c = DispatchController(api: api, userId: passenger, driver: false);
      final maps = MapSettings();
      c.setEnabled(true);
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          home: Scaffold(
            body: PassengerScreen(mapSettings: maps, dispatch: c),
            bottomNavigationBar: const SizedBox(height: 80),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('create-order'));
      expect(button.hitTestable(), findsOneWidget);
      expect(tester.getRect(button).bottom, lessThanOrEqualTo(660));
      expect(find.byKey(const Key('order-error')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      maps.dispose();
    },
  );

  for (final size in [
    const Size(360, 740),
    const Size(390, 844),
    const Size(800, 1280),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'fixed navigation and keyboard restore ${size.width}x${size.height} font$scale',
        (tester) async {
          setViewport(tester, size, scale);
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.resetPadding);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
          addTearDown(tester.view.resetViewPadding);
          await openPreview(tester, 'Пассажир', diagnosticsEnabled: false);
          final nav = find.byType(AdaptiveNavigation);
          final map = find.byKey(const Key('passenger-map'));
          final beforeMap = tester.getRect(map);
          final beforeNav = tester.getRect(nav);
          expect(beforeNav.bottom, lessThanOrEqualTo(size.height));
          expect(beforeNav.bottom, greaterThan(size.height - 30));
          final destination = find.byKey(const Key('destination'));
          await tester.ensureVisible(destination);
          await tester.tap(destination);
          tester.view.viewInsets = const FakeViewPadding(bottom: 280);
          addTearDown(tester.view.resetViewInsets);
          await tester.pumpAndSettle();
          expect(tester.getRect(map), beforeMap);
          expect(
            tester.getRect(destination).bottom,
            lessThanOrEqualTo(size.height - 280),
          );
          expect(find.byKey(const Key('nav-0')).hitTestable(), findsNothing);
          tester.view.resetViewInsets();
          await tester.tap(find.byTooltip('Свернуть поиск'));
          await tester.pumpAndSettle();
          expect(tester.getRect(map), beforeMap);
          expect(tester.getRect(nav), beforeNav);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
