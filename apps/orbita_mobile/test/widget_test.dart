import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';
import 'package:orbita_mobile/src/screens/device_check_screen.dart';

import 'fake_device.dart';

Future<void> openEntry(WidgetTester tester, String label) async {
  await tester.pumpAndSettle();
  await tester.scrollUntilVisible(find.text(label), 150);
  await tester.pumpAndSettle();
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Старт явно предлагает просмотр, без запроса разрешений', (
    tester,
  ) async {
    final device = FakeDevice();
    await tester.pumpWidget(OrbitaApp(device: device));
    await tester.pumpAndSettle();
    expect(find.text('Пассажир'), findsOneWidget);
    expect(find.text('Водитель'), findsOneWidget);
    expect(find.textContaining('Это не вход'), findsOneWidget);
    expect(device.calls, isEmpty);
  });
  testWidgets('Пассажир видит два адреса и не может отправить заказ', (
    tester,
  ) async {
    await tester.pumpWidget(OrbitaApp(device: FakeDevice()));
    await openEntry(tester, 'Пассажир');
    expect(find.byType(TextField), findsNWidgets(2));
    await tester.enterText(find.byKey(const Key('pickup')), 'Тестовая точка');
    tester.testTextInput.hide();
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.widgetWithText(FilledButton, 'Заказать такси'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    final order = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Заказать такси'),
    );
    expect(order.onPressed, isNull);
    await tester.tap(find.text('Поездки'));
    await tester.pumpAndSettle();
    expect(find.text('Ваши поездки'), findsOneWidget);
    await tester.tap(find.text('Заказ'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('pickup')),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Тестовая точка'), findsOneWidget);
    await tester.tap(find.byTooltip('Назад'));
    await tester.pumpAndSettle();
    expect(find.text('Знакомство с приложением'), findsOneWidget);
  });
  testWidgets('Водительский интерфейс не включает реальные назначения', (
    tester,
  ) async {
    await tester.pumpWidget(OrbitaApp(device: FakeDevice()));
    await openEntry(tester, 'Водитель');
    expect(find.text('Рабочий день'), findsOneWidget);
    expect(
      tester.widget<SwitchListTile>(find.byType(SwitchListTile)).onChanged,
      isNull,
    );
    expect(find.byKey(const Key('pickup')), findsNothing);
    await tester.tap(find.text('Профиль'));
    await tester.pumpAndSettle();
    expect(find.text('Профиль водителя'), findsOneWidget);
  });
  testWidgets('Уведомление открывает диагностику при холодном запуске', (
    tester,
  ) async {
    final device = FakeDevice()..launchRequested = true;
    await tester.pumpWidget(OrbitaApp(device: device));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceCheckScreen), findsOneWidget);
    expect(device.calls, isNot(contains('start')));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Диагностика не просит геопозицию автоматически', (tester) async {
    final device = FakeDevice();
    await tester.pumpWidget(OrbitaApp(device: device));
    await openEntry(tester, 'Проверка телефона');
    expect(device.calls, ['read']);
    final start = find.widgetWithText(
      FilledButton,
      'Запустить проверку в фоне',
    );
    await tester.scrollUntilVisible(start, 200);
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Отказ платформы показан по-русски без падения', (tester) async {
    final device = FakeDevice()..failRead = true;
    await tester.pumpWidget(OrbitaApp(device: device));
    await openEntry(tester, 'Проверка телефона');
    expect(find.textContaining('Не удалось прочитать'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('Только при использовании разрешает явный запуск проверки', (
    tester,
  ) async {
    final device = FakeDevice()
      ..state = const DeviceState(
        sdk: 34,
        notifications: true,
        location: 'approximate',
        locationEnabled: true,
      );
    await tester.pumpWidget(OrbitaApp(device: device));
    await openEntry(tester, 'Проверка телефона');
    final start = find.widgetWithText(
      FilledButton,
      'Запустить проверку в фоне',
    );
    await tester.scrollUntilVisible(start, 200);
    await tester.pumpAndSettle();
    await tester.tap(start);
    await tester.pumpAndSettle();
    expect(device.calls, contains('start'));
    expect(device.calls, isNot(contains('background')));
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'Малый экран и крупный шрифт сохраняют навигацию без переполнения',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      tester.platformDispatcher.textScaleFactorTestValue = 1.5;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await tester.pumpWidget(OrbitaApp(device: FakeDevice()));
      await openEntry(tester, 'Водитель');
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Профиль'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
