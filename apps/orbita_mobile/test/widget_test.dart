import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/screens/device_check_screen.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart';
import 'package:orbita_mobile/src/ui/components.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'fake_device.dart';
import 'test_helpers.dart';

void main() {
  testWidgets(
    'Старт сразу показывает вход без запроса разрешений и выбора роли',
    (tester) async {
      final device = FakeDevice();
      await tester.pumpWidget(OrbitaApp(device: device));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('login-email')), findsOneWidget);
      expect(find.text('Выберите интерфейс'), findsNothing);
      expect(device.calls, isEmpty);
      expect(find.text('Проверка устройства'), findsNothing);
    },
  );

  testWidgets(
    'Пассажир: два адреса, выключенный заказ, сохранение ввода во вкладках',
    (tester) async {
      await openPreview(tester, 'Пассажир');
      expect(find.byType(TextField), findsNWidgets(2));
      await scrollTo(tester, find.byKey(const Key('pickup')));
      await tester.enterText(find.byKey(const Key('pickup')), 'Учебная точка');
      tester.testTextInput.hide();
      await tester.pumpAndSettle();
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
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
      await tester.tap(find.byKey(const Key('nav-1')));
      await tester.pumpAndSettle();
      expect(find.text('Ваши поездки'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nav-0')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('pickup')), delta: -180);
      expect(find.text('Учебная точка'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('Выберите интерфейс'), findsNothing);
      expect(find.byType(PassengerScreen), findsOneWidget);
    },
  );

  testWidgets(
    'Водитель: карта главная, линия в шапке недоступна, настроек в шапке нет',
    (tester) async {
      setViewport(tester, const Size(390, 844), 1);
      await openPreview(tester, 'Водитель');
      expect(find.text('Рабочий день'), findsNothing);
      expect(find.byType(SwitchListTile), findsNothing);
      expect(find.text('Не на линии'), findsOneWidget);
      expect(find.text('На линии'), findsNothing);
      final slider = tester.widget<Semantics>(
        find.byKey(const Key('shift-control')),
      );
      expect(slider.properties.enabled, isFalse);
      expect(slider.properties.onTap, isNull);
      expect(find.byTooltip('Проверка устройства'), findsNothing);
      expect(find.byIcon(Icons.settings_outlined), findsNothing);
      final map = tester.getRect(find.byKey(const Key('driver-map')));
      final card = tester.getRect(find.byKey(const Key('current-order')));
      expect(map.height, greaterThan(card.height * 2));
      expect(card.top, greaterThanOrEqualTo(map.bottom));
      expect(find.text('Активных поездок нет'), findsOneWidget);
    },
  );

  testWidgets(
    'Все проверки доступны из профиля; системные настройки вызываются явно',
    (tester) async {
      final device = FakeDevice();
      await openPreview(tester, 'Водитель', device: device);
      await openProfile(tester);
      expect(find.byType(ProfileScreen), findsOneWidget);
      await tester.tap(find.text('О приложении'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Настройки приложения'));
      await tester.tap(find.text('Настройки приложения'));
      await tester.pumpAndSettle();
      expect(device.calls, ['settings']);
      await scrollTo(tester, find.text('Проверка устройства'));
      await tester.tap(find.text('Проверка устройства'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('location-card')), findsOneWidget);
      expect(find.byKey(const Key('notifications-card')), findsOneWidget);
      expect(find.byKey(const Key('service-card')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      expect(device.calls, isNot(contains('stop')));
    },
  );

  testWidgets(
    'Разрешённые уведомления: главное действие — тест, лишнего запроса нет',
    (tester) async {
      final device = FakeDevice()..state = readyState();
      await openPreview(tester, 'Пассажир', device: device);
      await openCheck(tester, 'Проверка устройства');
      expect(find.text('Разрешить уведомления'), findsNothing);
      final test = find.byKey(const Key('notification-test'));
      await scrollTo(tester, test);
      await tester.tap(test);
      await tester.pumpAndSettle();
      expect(device.calls, contains('notification'));
      expect(device.calls, isNot(contains('notifications')));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'После получения разрешения кнопка меняется по свежему состоянию платформы',
    (tester) async {
      final device = FakeDevice();
      device.actionHandler = (action) async {
        if (action == 'notifications') device.state = readyState();
      };
      await openPreview(tester, 'Пассажир', device: device);
      await openCheck(tester, 'Проверка устройства');
      await scrollTo(tester, find.byKey(const Key('notification-permission')));
      await tester.tap(find.byKey(const Key('notification-permission')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('notification-permission')), findsNothing);
      expect(find.byKey(const Key('notification-test')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Отдельные шаги разрешений сохраняются, фоновый запрос не вызывается заранее',
    (tester) async {
      final device = FakeDevice();
      device.actionHandler = (action) async {
        if (action == 'foreground') {
          device.state = readyState(background: false);
        }
      };
      await openPreview(tester, 'Водитель', device: device);
      await openCheck(tester, 'Проверка устройства');
      await scrollTo(tester, find.byKey(const Key('location-permissions')));
      await tester.tap(find.byKey(const Key('location-permissions')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('background-permission')));
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: find.byKey(const Key('background-permission')),
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      await scrollTo(
        tester,
        find.byKey(const Key('foreground-permission')),
        delta: -180,
      );
      await tester.tap(find.byKey(const Key('foreground-permission')));
      await tester.pumpAndSettle();
      expect(device.calls, contains('foreground'));
      expect(device.calls, isNot(contains('background')));
      await scrollTo(tester, find.byKey(const Key('background-permission')));
      await tester.tap(find.byKey(const Key('background-permission')));
      await tester.pumpAndSettle();
      expect(device.calls, contains('background'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Служба: показ фактических GPS-данных, запуск и остановка не потеряны',
    (tester) async {
      final device = FakeDevice()..state = readyState(background: false);
      device.actionHandler = (action) async {
        device.state = readyState(
          running: action == 'start',
          background: false,
        );
      };
      await openPreview(tester, 'Водитель', device: device);
      await openCheck(tester, 'Проверка устройства');
      await scrollTo(tester, find.byKey(const Key('start-diagnostic')));
      await tester.tap(find.byKey(const Key('start-diagnostic')));
      await tester.pumpAndSettle();
      expect(find.text('Работает'), findsOneWidget);
      expect(find.text('64'), findsOneWidget);
      expect(device.calls, isNot(contains('background')));
      await scrollTo(tester, find.byKey(const Key('stop-diagnostic')));
      await tester.tap(find.byKey(const Key('stop-diagnostic')));
      await tester.pumpAndSettle();
      expect(find.text('Остановлена'), findsOneWidget);
      expect(device.calls, contains('stop'));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Отказ чтения виден отдельно от карточек и не блокирует повтор', (
    tester,
  ) async {
    final device = FakeDevice()..failRead = true;
    await openPreview(tester, 'Водитель', device: device);
    await openCheck(tester, 'Проверка устройства');
    expect(
      find.text('Не удалось обновить состояние устройства.'),
      findsOneWidget,
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('Нет данных'), findsNWidgets(4));
    expect(find.text('Остановлена'), findsNothing);
    expect(find.text('Отключены'), findsNothing);
    device.failRead = false;
    device.state = readyState();
    await tester.tap(find.text('Повторить проверку'));
    await tester.pumpAndSettle();
    expect(
      find.text('Не удалось обновить состояние устройства.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Локальное уведомление по-прежнему открывает проверку при старте',
    (tester) async {
      final device = FakeDevice()..launchRequested = true;
      await tester.pumpWidget(OrbitaApp(device: device));
      await tester.pumpAndSettle();
      expect(find.byType(DeviceCheckScreen), findsOneWidget);
      expect(device.calls, isNot(contains('start')));
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'Выход с подтверждённой линии требует полного жеста и не меняет статус сам',
    (tester) async {
      final requested = <bool>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(),
          home: Scaffold(
            body: ShiftControl(
              confirmedOnline: true,
              available: true,
              requestChange: (online) async => requested.add(online),
            ),
          ),
        ),
      );
      final travel =
          tester.getSize(find.byKey(const Key('shift-track'))).width - 64;
      await tester.drag(
        find.byKey(const Key('shift-thumb')),
        Offset(-travel * 0.5, 0),
      );
      expect(requested, isEmpty);
      await tester.drag(
        find.byKey(const Key('shift-thumb')),
        Offset(-travel * 0.95, 0),
      );
      await tester.pumpAndSettle();
      expect(requested, [false]);
      expect(find.text('На линии'), findsOneWidget);
    },
  );
}
