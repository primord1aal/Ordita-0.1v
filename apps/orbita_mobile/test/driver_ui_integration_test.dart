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
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';
import 'package:orbita_mobile/src/screens/driver_screen.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart'
    show PreviewShell;
import 'package:orbita_mobile/src/ui/driver_demo_access.dart';
import 'package:orbita_mobile/src/ui/driver_map.dart';
import 'package:orbita_mobile/src/ui/theme.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:orbita_mobile/src/ui/orbita_map.dart';
import 'package:orbita_mobile/src/ui/orbita_brand.dart';
import 'package:orbita_mobile/src/ui/components.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_test_fonts.dart';
import 'dispatch_controller_test.dart'
    as dispatch_fakes
    show FakeApi, driver, envelope, trip;
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
      diagnosticsEnabled: true,
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
  await scrollTo(tester, find.byKey(const Key('driver-tools')), delta: -180);
  await tester.longPress(find.byKey(const Key('driver-tools')));
  await tester.pumpAndSettle();
  tester
      .widget<DropdownButtonFormField<DriverDemoScenario>>(
        find.byKey(const Key('driver-demo-scenario')),
      )
      .onChanged!(scenario);
  await tester.pumpAndSettle();
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

  testWidgets('Водитель получает GPS после выдачи разрешения в настройках', (
    tester,
  ) async {
    final device = FakeDevice()
      ..state = const DeviceState(
        foregroundLocationRequested: true,
        locationPermanentlyDenied: true,
      )
      ..locationHandler = () async => DeviceLocationFix(
        latitude: 55.01,
        longitude: 82.44,
        accuracyMeters: 10,
        capturedAt: DateTime.now().toUtc(),
      );
    final maps = MapSettings(initialKey: fakeMapKey);
    final dispatch = DispatchController(
      api: dispatch_fakes.FakeApi()
        ..handler = (_, _) async => dispatch_fakes.envelope(isDriver: true),
      userId: dispatch_fakes.driver,
      driver: true,
    )..setEnabled(true);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      dispatch.dispose();
      maps.dispose();
    });

    Future<void> show({bool foreground = true}) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(),
          home: Scaffold(
            body: DriverScreen(
              mapSettings: maps,
              device: device,
              dispatch: dispatch,
              foreground: foreground,
              tileSessionFactory: (_) => FakeMapTiles(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    await show();
    final warning = find.textContaining('Доступ к местоположению запрещён');
    expect(warning, findsOneWidget);
    final settings = find.text('Открыть настройки');
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    expect(device.calls, contains('settings'));
    expect(device.calls, isNot(contains('currentLocation')));

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await show(foreground: false);
    device.state = const DeviceState(
      location: 'precise',
      foregroundLocationRequested: true,
      locationEnabled: true,
    );
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await show();

    expect(
      device.calls.where((call) => call == 'currentLocation'),
      hasLength(1),
    );
    expect(device.calls, isNot(contains('foreground')));
    expect(warning, findsNothing);
    expect(settings, findsNothing);
    final position = tester
        .widget<OrbitaMap>(find.byType(OrbitaMap))
        .userPosition;
    expect(position?.latitude, 55.01);
    expect(position?.longitude, 82.44);
    expect(tester.takeException(), isNull);
    dispatch.setEnabled(false);
  });

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
      expect(find.text('Вне смены'), findsOneWidget);
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
      expect(find.text('Подключаем…'), findsOneWidget);
      final pending = Completer<ServerAccess>();
      repo.accessPending = pending;
      await tester.pump(const Duration(seconds: 30));
      await tester.pump();
      expect(find.byType(DriverDemoDeniedScreen), findsOneWidget);
      repo.accessPending = null;
      pending.complete(testAccess(UserRole.driver));
      await tester.pumpAndSettle();
      expect(find.text('Не на линии'), findsOneWidget);
      expect(find.text('Подключаем…'), findsNothing);
      repo.access = testAccess(UserRole.passenger);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.byType(DriverDiagnosticView), findsNothing);
      expect(find.byType(PassengerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Демо: отказ не создаёт поездку', (tester) async {
    final repo = await _mount(tester);
    await _openDemo(tester);
    await _scenario(tester, DriverDemoScenario.offer);
    await scrollTo(tester, find.byKey(const Key('demo-offer-decline')));
    await tester.tap(find.byKey(const Key('demo-offer-decline')));
    await tester.pump();
    expect(find.textContaining('Предложение отклонено'), findsOneWidget);
    expect(find.byKey(const Key('demo-journey-action')), findsNothing);
    expect(repo.fetches, 1);
    expect(repo.logins, 0);
    expect(repo.logouts, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Демо: истечение 25 секунд закрывает принятие', (tester) async {
    final repo = await _mount(tester);
    await _openDemo(tester);
    await _scenario(tester, DriverDemoScenario.offer);
    // Граница самого предложения; перепроверка доступа на 30-й секунде
    // независимо покрывается соседним сценарием отзыва.
    await tester.pump(const Duration(seconds: 25));
    expect(
      find.textContaining('Время ответа истекло'),
      findsOneWidget,
      reason: tester
          .widgetList<Text>(find.byType(Text))
          .map((w) => w.data)
          .join(' | '),
    );
    expect(find.byKey(const Key('demo-offer-accept')), findsNothing);
    expect(find.byKey(const Key('demo-journey-action')), findsNothing);
    expect(repo.logins, 0);
    expect(repo.logouts, 0);
    expect(repo.fetches, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('На узком тёмном экране GPS доступен при крупном тексте', (
    tester,
  ) async {
    await _mount(
      tester,
      dark: true,
      tiles: true,
      size: const Size(320, 568),
      scale: 4,
    );
    expect(tester.getSize(find.byType(OrbitaLogo)).width, 32);

    final gps = find.byTooltip('Моё местоположение');
    await scrollTo(tester, gps);
    expect(gps.hitTestable(), findsOneWidget);
    expect(tester.getSize(gps), const Size(48, 48));
    expect(find.byType(MapAttribution), findsOneWidget);
    checkHorizontalBounds(tester);
    expect(tester.takeException(), isNull);
  });

  for (final (file, status, label) in [
    ('glass-driver-waiting', null, 'Ожидаем заказ'),
    ('glass-driver-offer', 'created', 'Новый заказ'),
    ('glass-driver-pickup', 'to_pickup', 'К пассажиру'),
    ('glass-driver-riding', 'riding', 'В поездке'),
  ]) {
    testWidgets('Стеклянный рабочий экран водителя: $file', (tester) async {
      setViewport(tester, const Size(390, 844), 1);
      final settings = MapSettings(initialKey: fakeMapKey);
      addTearDown(settings.dispose);
      final order = status == null
          ? null
          : dispatch_fakes.trip({
              'request_id': '00000000-0000-4000-8000-000000000004',
              'pickup': {
                'address': 'Чик, Учебная улица, 12',
                'latitude': 55.006,
                'longitude': 82.437,
              },
              'destination': {
                'address': 'Чик, Садовая улица, 5',
                'latitude': 55.007,
                'longitude': 82.444,
              },
            }, status: status);
      final api = dispatch_fakes.FakeApi()
        ..handler = (_, _) async => {
          ...dispatch_fakes.envelope(isDriver: true, order: order),
          if (status == 'created')
            'offer': {
              'id': '00000000-0000-4000-8000-000000000005',
              'order_id': order!['id'],
              'expires_at': '2026-11-20T16:00:19Z',
            },
        };
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          home: PreviewShell(
            role: PreviewRole.driver,
            device: FakeDevice()
              ..state = readyState()
              ..locationHandler = () async => DeviceLocationFix(
                latitude: 55.005,
                longitude: 82.44,
                accuracyMeters: 10,
                capturedAt: DateTime.now().toUtc(),
              ),
            mapSettings: settings,
            dispatchApi: api,
            userId: dispatch_fakes.driver,
            tileSessionFactory: (_) => _DesignTiles(false),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 350));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      final map = tester.getRect(find.byType(DriverMap));
      final panel = tester.getRect(find.byKey(const Key('work-panel')));
      expect(find.text(label).hitTestable(), findsOneWidget);
      expect(map.bottom, closeTo(panel.top, .5));
      expect(
        panel.bottom,
        closeTo(
          tester.getRect(find.byKey(const Key('navigation-horizontal'))).top,
          .5,
        ),
      );
      if (status == 'created') {
        expect(find.text('19 с'), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Отказаться')).dy,
          closeTo(tester.getTopLeft(find.text('Принять')).dy, 1),
        );
      }
      if (captureDesignGoldens) {
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/$file.png'),
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final (reducedMotion, deadlineSecond, scale) in [
    (false, 19, 1.0),
    (true, 19, 1.0),
    (false, 1, 1.0),
    (false, 19, 3.2),
  ]) {
    testWidgets(
      'Ожидание → новый заказ, reduce motion=$reducedMotion, $deadlineSecond с, ×$scale',
      (tester) async {
        setViewport(
          tester,
          scale == 1 ? const Size(390, 844) : const Size(320, 568),
          scale,
        );
        final maps = MapSettings(initialKey: fakeMapKey);
        final api = dispatch_fakes.FakeApi();
        final dispatcher = DispatchController(
          api: api,
          userId: dispatch_fakes.driver,
          driver: true,
        );
        addTearDown(maps.dispose);
        addTearDown(dispatcher.dispose);
        final draft = dispatch_fakes.trip({
          'request_id': '00000000-0000-4000-8000-000000000004',
          'pickup': {
            'address': 'Чик, Учебная улица, 12',
            'latitude': 55.006,
            'longitude': 82.437,
          },
          'destination': {
            'address': 'Чик, Садовая улица, 5',
            'latitude': 55.007,
            'longitude': 82.444,
          },
        });
        var offered = false;
        api.handler = (_, _) async => {
          ...dispatch_fakes.envelope(
            isDriver: true,
            order: offered ? draft : null,
          ),
          if (offered)
            'offer': {
              'id': '00000000-0000-4000-8000-000000000005',
              'order_id': draft['id'],
              'expires_at':
                  '2026-11-20T16:00:${deadlineSecond.toString().padLeft(2, '0')}Z',
            },
        };
        dispatcher.setEnabled(true);
        await tester.pumpWidget(
          MaterialApp(
            theme: orbitaTheme(brightness: Brightness.light),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(disableAnimations: reducedMotion),
              child: child!,
            ),
            home: Scaffold(
              body: DriverScreen(
                dispatch: dispatcher,
                mapSettings: maps,
                tileSessionFactory: (_) => _DesignTiles(false),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 120)),
        );
        await tester.pumpAndSettle();
        final panel = find.byKey(const Key('work-panel'));
        final initial = tester.getSize(panel).height;
        final map = tester.state(find.byType(OrbitaMap));
        expect(find.text('Ожидаем заказ').hitTestable(), findsOneWidget);
        offered = true;
        await dispatcher.refresh();
        await tester.pump();
        final start = tester.getSize(panel).height;
        await tester.pump(const Duration(milliseconds: 50));
        final middle = tester.getSize(panel).height;
        if (scale == 1) {
          expect(
            find.byKey(const Key('accept-offer')).hitTestable(),
            findsOneWidget,
          );
        }
        if (!reducedMotion &&
            deadlineSecond == 19 &&
            scale == 1 &&
            captureDesignGoldens) {
          await tester.pump(const Duration(milliseconds: 65));
          await expectLater(
            find.byType(Scaffold),
            matchesGoldenFile('goldens/glass-driver-offer-transition.png'),
          );
        }
        await tester.pump(const Duration(milliseconds: 250));
        final end = tester.getSize(panel).height;
        if (scale > 1) {
          final accept = find.byKey(const Key('accept-offer'));
          await Scrollable.ensureVisible(tester.element(accept));
          await tester.pumpAndSettle();
          expect(accept.hitTestable(), findsOneWidget);
          checkHorizontalBounds(tester);
        } else {
          expect(end, greaterThan(initial));
          if (reducedMotion || deadlineSecond <= 2) {
            expect(start, end);
            expect(middle, end);
          } else {
            expect(start, closeTo(initial, 1));
            expect(middle, greaterThan(initial));
            expect(middle, lessThan(end));
          }
        }
        expect(identical(map, tester.state(find.byType(OrbitaMap))), isTrue);
        expect(tester.takeException(), isNull);
        dispatcher.setEnabled(false);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

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

  // Семь групп геометрических инвариантов из CSS, пять итоговых кадров.
  for (final spec in [
    ('off-light', false, null, 1.0),
    ('off-dark', true, null, 1.0),
    ('online', true, DriverDemoScenario.online, 1.0),
    ('offer', true, DriverDemoScenario.offer, 1.0),
    ('attribution', false, null, 3.2),
  ]) {
    testWidgets('Исправленный концепт: ${spec.$1}', (tester) async {
      tester.view.padding = const FakeViewPadding(top: 28, bottom: 23);
      tester.view.viewPadding = const FakeViewPadding(top: 28, bottom: 23);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      await _mount(
        tester,
        role: spec.$4 == 1 ? UserRole.driver : UserRole.passenger,
        dark: spec.$2,
        tiles: true,
        scale: spec.$4,
      );
      if (spec.$3 != null) {
        await _openDemo(tester);
        await _scenario(tester, spec.$3!);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pumpAndSettle();
      }
      if (spec.$4 == 1) {
        final real = spec.$3 == null;
        final nav = tester.getRect(
          find.byKey(const Key('navigation-horizontal')),
        );
        if (real) {
          expect(find.byType(BrandHeader), findsNothing);
          final brand = tester.getRect(find.byKey(const Key('map-brand')));
          final shift = tester.getRect(find.byKey(const Key('shift-track')));
          final map = tester.getRect(find.byType(DriverMap));
          final panel = tester.getRect(find.byKey(const Key('work-panel')));
          expect(brand.top, shift.top);
          expect(brand.right, lessThan(shift.left));
          expect(
            map.contains(brand.center) && map.contains(shift.center),
            isTrue,
          );
          expect(panel.top, closeTo(map.bottom, 1));
          expect(panel.bottom, closeTo(nav.top, 1));
          expect(map.height, greaterThan(panel.height * 2));
          final credits = tester.getRect(find.byType(MapAttribution));
          expect(credits.bottom, lessThanOrEqualTo(panel.top));
        } else {
          expect(
            tester.getSize(find.byType(BrandHeader)).height,
            closeTo(74, .5),
          );
          expect(tester.getSize(find.byType(OrbitaLogo)).width, 42);
          final panel = tester.getRect(find.byKey(const Key('current-order')));
          expect(panel.bottom, closeTo(nav.top, 1));
        }
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position
              .maxScrollExtent,
          lessThanOrEqualTo(1),
        );
        // 4: GPS48 доступен в реальном интерфейсе, отключён в demo; 5: nav73 + inset23.
        final gps = find.byTooltip('Моё местоположение');
        expect(tester.getSize(gps), const Size(48, 48));
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(of: gps, matching: find.byType(IconButton)).first,
              )
              .onPressed,
          spec.$3 == null ? isNotNull : isNull,
        );
        expect(find.byTooltip('Приблизить карту'), findsNothing);
        expect(nav.height, closeTo(73 + 23, 1));
        expect(find.byIcon(Icons.map_outlined), findsOneWidget);
        if (spec.$3 == DriverDemoScenario.offer) {
          // 6: заголовок/таймер в строку, адреса сгруппированы, кнопки52 и 1:1.2.
          expect(
            tester.getTopLeft(find.text('Новый заказ')).dy,
            closeTo(tester.getTopLeft(find.text('25 с')).dy, 1),
          );
          final accept = tester.getRect(
            find.byKey(const Key('demo-offer-accept')),
          );
          final decline = tester.getRect(
            find.byKey(const Key('demo-offer-decline')),
          );
          expect(accept.top, decline.top);
          expect(accept.height, greaterThanOrEqualTo(52));
          expect(accept.width / decline.width, closeTo(1.2, .02));
        }
        for (final text in [
          'ДЕМО',
          'Диагностический сценарий',
          'Карта — тестовая заглушка',
          'Вымышленные адреса',
          'Линия не подключена',
        ]) {
          expect(find.textContaining(text), findsNothing);
        }
      } else {
        // 7: весь блок ссылок виден над меню; адреса доступны прокруткой.
        await tester.scrollUntilVisible(
          find.byType(MapAttribution),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.byType(MapAttribution)),
          alignment: .1,
        );
        await tester.pumpAndSettle();
        final navTop = tester
            .getRect(find.byKey(const Key('navigation-compact')))
            .top;
        for (final label in [
          '© OpenStreetMap',
          '© OpenMapTiles',
          '© CARTO',
          'Powered by Geoapify',
        ]) {
          final rect = tester.getRect(find.text(label));
          expect(rect.top, greaterThanOrEqualTo(28));
          expect(rect.bottom, lessThanOrEqualTo(navTop));
        }
      }
      checkHorizontalBounds(tester);
      if (captureDesignGoldens) {
        await expectLater(
          find.byType(Scaffold).last,
          matchesGoldenFile('goldens/block4fix-${spec.$1}.png'),
        );
      }
      if (spec.$4 != 1) {
        await scrollTo(tester, find.byKey(const Key('destination')));
        expect(find.byType(TextField), findsNWidgets(2));
      }
      expect(tester.takeException(), isNull);
    });
  }
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
        expect(find.textContaining('ДЕМО'), findsNothing);
      } else {
        expect(find.byType(DriverScreen), findsOneWidget);
        expect(tester.getSize(find.byType(OrbitaLogo)).width, 32);
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
