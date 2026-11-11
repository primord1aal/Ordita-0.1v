import 'package:flutter/material.dart';

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/screens/map_picker_screen.dart';

import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'maps_test_fakes.dart';
import 'responsive_test.dart' show checkHorizontalBounds;
import 'test_helpers.dart';

Future<void> mountMapAccount(
  WidgetTester tester, {
  FakeAuthRepository? auth,
  FakeAddressService? service,
}) async {
  final settings = MapSettings(initialKey: fakeMapKey);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
  });
  await tester.pumpWidget(
    OrbitaApp(
      device: FakeDevice(),
      authRepository: auth ?? (FakeAuthRepository()..saved = testSession()),
      mapSettings: settings,
      addressServiceFactory: (_) => service ?? FakeAddressService(),
      tileSessionFactory: (_) => FakeMapTiles(),
    ),
  );
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('passenger-scroll')), findsOneWidget);
}

void main() {
  testWidgets(
    'В фоне открытый выбор точки скрывает координаты и восстанавливается без сброса',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        await mountMapAccount(tester);
        await scrollTo(tester, find.byKey(const Key('pickup-on-map')));
        await tester.tap(find.byKey(const Key('pickup-on-map')));
        await tester.pumpAndSettle();
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        await tester.pump();
        await tester.pump();
        final tree = tester
            .getSemantics(find.byType(MapPickerScreen))
            .toStringDeep();
        expect(tree, isNot(contains('Точка под прицелом')));
        expect(find.byKey(const Key('map-background-cover')), findsOneWidget);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(find.byType(MapPickerScreen), findsOneWidget);
        expect(find.byKey(const Key('map-background-cover')), findsNothing);
        expect(
          find.textContaining('Точка под прицелом: 55.00000, 82.43000'),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets(
    'Ошибка карты на маленьком экране с крупным шрифтом не перекрывает форму',
    (tester) async {
      setViewport(tester, const Size(320, 568), 3.2);
      final settings = MapSettings(initialKey: fakeMapKey);
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        settings.dispose();
      });
      await tester.pumpWidget(
        OrbitaApp(
          device: FakeDevice(),
          authRepository: FakeAuthRepository()..saved = testSession(),
          mapSettings: settings,
          addressServiceFactory: (_) => FakeAddressService(),
          tileSessionFactory: (_) => FailingMapTiles(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Лимит сервиса карт.'), findsOneWidget);
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('pickup')));
      await tester.enterText(find.byKey(const Key('pickup')), 'Ручной адрес');
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pickup')))
            .controller!
            .text,
        'Ручной адрес',
      );
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Нажатие на карту выбирает новое место, не стартовый центр', (
    tester,
  ) async {
    final service = FakeAddressService();
    await mountMapAccount(tester, service: service);
    await scrollTo(tester, find.byKey(const Key('destination-on-map')));
    await tester.tap(find.byKey(const Key('destination-on-map')));
    await tester.pumpAndSettle();
    final map = tester.getRect(find.byType(FlutterMap).last);
    await tester.tapAt(map.center + const Offset(30, 30));
    // flutter_map ждёт окно второго нажатия перед onTap (double-tap zoom).
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('confirm-map-point')));
    await tester.tap(find.byKey(const Key('confirm-map-point')));
    await tester.pumpAndSettle();
    expect(service.points.single.longitude, greaterThan(82.43));
    expect(service.points.single.latitude, lessThan(55.0));
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('destination')))
          .controller!
          .text,
      service.reverseLabel,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'Back из выбора карты оставляет прежний адрес без reverse-запроса',
    (tester) async {
      final service = FakeAddressService();
      await mountMapAccount(tester, service: service);
      await scrollTo(tester, find.byKey(const Key('pickup')));
      await tester.enterText(
        find.byKey(const Key('pickup')),
        'Ручной исходный адрес',
      );
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pickup-on-map')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('pickup')))
            .controller!
            .text,
        'Ручной исходный адрес',
      );
      expect(service.points, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('Открытая карта переживает перепроверку; выбор временно закрыт', (
    tester,
  ) async {
    final auth = FakeAuthRepository()..saved = testSession();
    await mountMapAccount(tester, auth: auth);
    await scrollTo(tester, find.byKey(const Key('pickup-on-map')));
    await tester.tap(find.byKey(const Key('pickup-on-map')));
    await tester.pumpAndSettle();
    final pending = Completer<ServerAccess>();
    auth.accessPending = pending;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    try {
      expect(find.byType(MapPickerScreen), findsOneWidget);
      final button = find.descendant(
        of: find.byKey(const Key('confirm-map-point')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(tester.takeException(), isNull);
    } finally {
      auth.accessPending = null;
      pending.complete(testAccess());
      await tester.pumpAndSettle();
    }
    expect(find.byType(MapPickerScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Ровно два адреса, подсказка в нужном поле и заказ отключён', (
    tester,
  ) async {
    await mountMapAccount(tester);
    await scrollTo(tester, find.byKey(const Key('pickup')));
    await tester.enterText(find.byKey(const Key('pickup')), 'Чик, улица');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text(examplePlace.label));
    await tester.tap(find.text(examplePlace.label));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pickup')))
          .controller!
          .text,
      examplePlace.label,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('destination')))
          .controller!
          .text,
      isEmpty,
    );
    expect(find.byType(TextField), findsNWidgets(2));
    await scrollTo(tester, find.byKey(const Key('create-order')));
    expect(
      tester
          .widget<FilledButton>(
            find.descendant(
              of: find.byKey(const Key('create-order')),
              matching: find.byType(FilledButton),
            ),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Периодическая проверка и вкладки сохраняют выбранный адрес', (
    tester,
  ) async {
    await mountMapAccount(tester);
    await scrollTo(tester, find.byKey(const Key('pickup')));
    await tester.enterText(find.byKey(const Key('pickup')), 'Чик, улица');
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text(examplePlace.label));
    await tester.tap(find.text(examplePlace.label));
    await tester.pumpAndSettle();
    await openProfile(tester);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('Профиль пассажира'), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-0')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('pickup')), delta: -180);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('pickup')))
          .controller!
          .text,
      examplePlace.label,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Потеря роли закрывает открытый выбор точки', (tester) async {
    final auth = FakeAuthRepository()..saved = testSession();
    await mountMapAccount(tester, auth: auth);
    await scrollTo(tester, find.byKey(const Key('pickup-on-map')));
    await tester.tap(find.byKey(const Key('pickup-on-map')));
    await tester.pumpAndSettle();
    expect(find.byType(MapPickerScreen), findsOneWidget);
    auth.access = const ServerAccess(
      userId: userA,
      status: AccessStatus.blocked,
    );
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byType(MapPickerScreen), findsNothing);
    expect(find.byKey(const Key('login-email')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(800, 1280),
    const Size(1280, 800),
  ]) {
    for (final scale in [1.0, 3.2]) {
      testWidgets('Выбор точки $size, шрифт $scale', (tester) async {
        setViewport(tester, size, scale);
        await mountMapAccount(tester);
        await scrollTo(tester, find.byKey(const Key('destination-on-map')));
        await tester.tap(find.byKey(const Key('destination-on-map')));
        await tester.pumpAndSettle();
        checkHorizontalBounds(tester);
        await scrollTo(tester, find.byKey(const Key('confirm-map-point')));
        await tester.tap(find.byKey(const Key('confirm-map-point')));
        await tester.pumpAndSettle();
        expect(find.byType(MapPickerScreen), findsNothing);
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('destination')))
              .controller!
              .text,
          'Учебная точка, Чик',
        );
        expect(
          tester
              .widget<TextField>(find.byKey(const Key('pickup')))
              .controller!
              .text,
          isEmpty,
        );
        checkHorizontalBounds(tester);
      });
    }
  }
}
