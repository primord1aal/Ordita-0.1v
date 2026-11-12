// Настоящие Flutter-виджеты, вымышленные аккаунты и локальные PNG-тайлы.
// Карта — тестовая заглушка. Сеть и настоящие серверные команды отсутствуют.
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/map_tiles.dart';
import 'package:orbita_mobile/src/screens/driver_screen.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';
import 'package:orbita_mobile/src/ui/driver_demo_access.dart';
import 'package:orbita_mobile/src/ui/theme.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_test_fonts.dart';
import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'maps_test_fakes.dart';
import 'responsive_test.dart' show checkHorizontalBounds;
import 'test_helpers.dart';

class _DesignTiles extends MapTileSession {
  _DesignTiles(bool dark)
    : _png = File('test/fixtures/map-stub-${dark ? 'dark' : 'light'}.png')
          .readAsBytesSync(),
      super(fakeMapKey);
  final Uint8List _png;
  @override
  Future<Uint8List> tile(TileCoordinates coordinate) async => _png;
}

Future<FakeAuthRepository> _mount(
  WidgetTester tester, {
  UserRole role = UserRole.driver,
  AccessStatus status = AccessStatus.active,
  bool signedIn = true,
  bool dark = false,
  bool tiles = false,
  Size size = const Size(390, 844),
  double scale = 1,
}) async {
  setViewport(tester, size, scale);
  SharedPreferences.setMockInitialValues({
    ThemeSettings.storageKey: dark ? 'dark' : 'light',
  });
  final theme = ThemeSettings();
  await theme.load();
  final maps = MapSettings(initialKey: tiles ? fakeMapKey : '');
  final repo = FakeAuthRepository()
    ..saved = signedIn ? testSession() : null
    ..access = testAccess(role);
  if (status != AccessStatus.active) {
    repo.access = ServerAccess(userId: userA, status: status);
  }
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    maps.dispose();
    theme.dispose();
  });
  await tester.pumpWidget(
    OrbitaApp(
      device: FakeDevice(),
      authRepository: repo,
      themeSettings: theme,
      mapSettings: maps,
      tileSessionFactory: (_) => _DesignTiles(dark),
    ),
  );
  await tester.pumpAndSettle();
  if (tiles) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }
  return repo;
}

Future<void> _openDemo(WidgetTester tester) async {
  await openProfile(tester);
  await scrollTo(tester, find.text('О приложении'));
  await tester.tap(find.text('О приложении'));
  await tester.pumpAndSettle();
  await scrollTo(tester, find.byKey(const Key('driver-demo-entry')));
  await tester.tap(find.byKey(const Key('driver-demo-entry')));
  await tester.pumpAndSettle();
  expect(find.byType(DriverDiagnosticView), findsOneWidget);
}

Future<void> _scenario(WidgetTester tester, DriverDemoScenario scenario) async {
  tester
      .widget<DropdownButtonFormField<DriverDemoScenario>>(
        find.byKey(const Key('driver-demo-scenario')),
      )
      .onChanged!(scenario);
  await tester.pump();
}

Future<void> _slide(WidgetTester tester) async {
  final thumb = find.byKey(const Key('shift-thumb'));
  final travel =
      tester.getSize(find.byKey(const Key('shift-track'))).width - 64;
  await tester.drag(thumb, Offset(travel * 0.95, 0));
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);

  for (final (role, status, signedIn) in [
    (UserRole.driver, AccessStatus.active, true),
    (UserRole.passenger, AccessStatus.active, true),
    (UserRole.admin, AccessStatus.active, true),
    (UserRole.driver, AccessStatus.active, false),
    (UserRole.driver, AccessStatus.noRole, true),
    (UserRole.driver, AccessStatus.blocked, true),
  ]) {
    testWidgets('Прямой demo route закрыт: $role/$status/session=$signedIn', (
      tester,
    ) async {
      await _mount(tester, role: role, status: status, signedIn: signedIn);
      expect(find.byKey(const Key('driver-demo-entry')), findsNothing);
      unawaited(
        Navigator.of(tester.element(find.byType(Scaffold).first))
            .pushNamed('/driver-demo'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(DriverDemoDeniedScreen), findsOneWidget);
      expect(find.byType(DriverDiagnosticView), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Прямой diagnostic widget без доверенного допуска закрыт', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(theme: orbitaTheme(), home: const DriverDiagnosticView()),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DriverDemoDeniedScreen), findsOneWidget);
    expect(find.byKey(const Key('driver-demo-scenario')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Локальные demo-события не вызывают сервер и не меняют рабочую линию',
    (tester) async {
      final repo = await _mount(tester);
      await _openDemo(tester);
      await _slide(tester);
      expect(find.text('На линии'), findsOneWidget);
      await _scenario(tester, DriverDemoScenario.offer);
      expect(find.text('25 с'), findsOneWidget);
      await scrollTo(tester, find.byKey(const Key('demo-offer-accept')));
      await tester.tap(find.byKey(const Key('demo-offer-accept')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Заказ принят'), findsOneWidget);
      for (var i = 0; i < 4; i++) {
        await scrollTo(tester, find.byKey(const Key('demo-journey-action')));
        await tester.tap(find.byKey(const Key('demo-journey-action')));
        await tester.pumpAndSettle();
      }
      expect(repo.fetches, 1);
      expect(repo.logins, 0);
      expect(repo.logouts, 0);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('К заказу'));
      await tester.pumpAndSettle();
      expect(find.text('Линия не подключена'), findsOneWidget);
      expect(find.text('На линии'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Перепроверка и потеря роли закрывают действительную demo-проводку',
    (tester) async {
      final repo = await _mount(tester);
      await _openDemo(tester);
      await _scenario(tester, DriverDemoScenario.pending);
      await _slide(tester);
      expect(find.text('Подтверждаем…'), findsOneWidget);
      final pending = Completer<ServerAccess>();
      repo.accessPending = pending;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.byType(DriverDemoDeniedScreen), findsOneWidget);
      repo.accessPending = null;
      pending.complete(testAccess(UserRole.driver));
      await tester.pumpAndSettle();
      expect(find.text('Не на линии'), findsOneWidget);
      expect(find.text('Подтверждаем…'), findsNothing);
      repo.access = testAccess(UserRole.passenger);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.byType(DriverDiagnosticView), findsNothing);
      expect(find.byType(PassengerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Демо: отказ и истечение 25 секунд не создают поездку', (
    tester,
  ) async {
    final repo = await _mount(tester);
    await _openDemo(tester);
    await _scenario(tester, DriverDemoScenario.offer);
    await scrollTo(tester, find.byKey(const Key('demo-offer-decline')));
    await tester.tap(find.byKey(const Key('demo-offer-decline')));
    await tester.pump();
    expect(find.textContaining('Предложение отклонено'), findsOneWidget);
    await _scenario(tester, DriverDemoScenario.offer);
    await tester.pump(const Duration(seconds: 26));
    expect(find.textContaining('Время ответа истекло'), findsOneWidget);
    expect(find.byKey(const Key('demo-offer-accept')), findsNothing);
    expect(find.byKey(const Key('demo-journey-action')), findsNothing);
    expect(repo.logins, 0);
    expect(repo.logouts, 0);
    expect(repo.fetches, 1);
    expect(tester.takeException(), isNull);
  });

  final shots = [
    ('driver-off-light', false, null, const Size(390, 844), 1.0),
    ('driver-off-dark', true, null, const Size(390, 844), 1.0),
    (
      'demo-online',
      false,
      DriverDemoScenario.online,
      const Size(390, 844),
      1.0,
    ),
    (
      'demo-pending',
      false,
      DriverDemoScenario.pending,
      const Size(390, 844),
      1.0,
    ),
    ('demo-error', false, DriverDemoScenario.error, const Size(390, 844), 1.0),
    (
      'demo-offer-25s',
      true,
      DriverDemoScenario.offer,
      const Size(390, 844),
      1.0,
    ),
    ('navigation-3.2', false, null, const Size(320, 568), 3.2),
    ('attribution-3.2', false, null, const Size(390, 844), 3.2),
    ('driver-tablet', false, null, const Size(800, 1280), 1.0),
  ];
  for (final (name, dark, scenario, size, scale) in shots) {
    testWidgets('Снимок блока4: $name', (tester) async {
      await _mount(tester, dark: dark, size: size, scale: scale, tiles: true);
      if (scenario != null) {
        await _openDemo(tester);
        await _scenario(tester, scenario);
        if (scenario == DriverDemoScenario.pending ||
            scenario == DriverDemoScenario.error) {
          await _slide(tester);
          await tester.pump(const Duration(milliseconds: 100));
        }
        if (scenario == DriverDemoScenario.offer) {
          await scrollTo(tester, find.byKey(const Key('current-order')));
          expect(find.text('25 с'), findsOneWidget);
        }
        expect(find.textContaining('ДЕМО'), findsWidgets);
      } else {
        expect(find.byType(DriverScreen), findsOneWidget);
        if (name == 'attribution-3.2') {
          await scrollTo(tester, find.text('Powered by Geoapify'));
        }
      }
      checkHorizontalBounds(tester);
      if (captureDesignGoldens) {
        await expectLater(
          find.byType(Scaffold).last,
          matchesGoldenFile('goldens/block4-$name.png'),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
