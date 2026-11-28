import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/screens/account_pages.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_test_fonts.dart';
import 'test_helpers.dart';
import 'fake_device.dart';

class _SettingsDevice extends FakeDevice implements OfferNotificationSettings {
  int openings = 0;
  @override
  Future<void> openOfferNotificationSettings() async {
    openings++;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);
  testWidgets('Системная тема в настройках, диагностика отдельно в профиле', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-system')));
    tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
      Brightness.dark,
    );
    expect(
      tester.widget<ListTile>(find.byKey(const Key('theme-system'))).selected,
      isTrue,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        ThemeSettings.storageKey,
      ),
      'system',
    );
    expect(find.text('О приложении'), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('О приложении'));
    await tester.pumpAndSettle();
    expect(find.text('Настройки приложения'), findsOneWidget);
    await tester.tap(find.text('Проверка устройства'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('location-card')), findsOneWidget);
    expect(find.byKey(const Key('notifications-card')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Профиль водителя открывает действующие настройки Android', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final device = _SettingsDevice();
    setViewport(tester, const Size(390, 844), 1);
    await openPreview(tester, 'Водитель', device: device);
    await openProfile(tester);
    expect(find.text('История поездок'), findsNothing);
    await tester.tap(find.text('Мой автомобиль'));
    await tester.pumpAndSettle();
    expect(
      find.text('Подтверждённых данных об автомобиле пока нет.'),
      findsOneWidget,
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    if (captureDesignGoldens) {
      await expectLater(
        find.byType(Scaffold).last,
        matchesGoldenFile('goldens/glass-driver-settings.png'),
      );
    }
    await tester.tap(find.text('Звук и вибрация заказов'));
    await tester.pumpAndSettle();
    expect(device.openings, 1);
  });

  testWidgets('Лицензия Inter доступна из профиля', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    await tester.tap(find.text('О приложении'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.text('Лицензии'));
    await tester.tap(find.text('Лицензии'));
    await tester.pumpAndSettle();
    expect(find.text('Inter'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Тема меняется из профиля и сохраняется после перезапуска', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('theme-dark')));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
      Brightness.dark,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        ThemeSettings.storageKey,
      ),
      'dark',
    );
    await tester.pumpWidget(const SizedBox());
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    await tester.tap(find.text('Настройки'));
    await tester.pumpAndSettle();
    expect(find.text('Тёмная'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(SettingsScreen))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });
}
