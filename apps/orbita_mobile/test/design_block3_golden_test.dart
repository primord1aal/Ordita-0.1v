// Flutter widget-снимки с вымышленными аккаунтами и FakeAuthRepository.
// В обычном CI обязательны структурные проверки; PNG — в явном режиме.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/screens/account_pages.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'design_test_fonts.dart';
import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'responsive_test.dart' show checkHorizontalBounds;
import 'test_helpers.dart';

enum _Screen { login, offline, noRole, blocked, admin, profile, settings }

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);

  Future<FakeAuthRepository> mount(
    WidgetTester tester,
    _Screen screen,
    ThemeMode mode, {
    Size size = const Size(390, 844),
    double scale = 1,
    String name = 'Тестовый пассажир',
  }) async {
    SharedPreferences.setMockInitialValues({
      ThemeSettings.storageKey: mode.name,
    });
    setViewport(tester, size, scale);
    final settings = ThemeSettings();
    await settings.load();
    final repo = FakeAuthRepository();
    if (screen != _Screen.login) repo.saved = testSession();
    repo.access = ServerAccess(
      userId: userA,
      status: switch (screen) {
        _Screen.noRole => AccessStatus.noRole,
        _Screen.blocked => AccessStatus.blocked,
        _ => AccessStatus.active,
      },
      role: screen == _Screen.admin ? UserRole.admin : UserRole.passenger,
      version: 1,
      displayName: name,
    );
    if (screen == _Screen.offline) {
      repo.accessError = const AuthFailure(AuthFailureKind.network);
    }
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    });
    await tester.pumpWidget(
      OrbitaApp(
        device: FakeDevice(),
        authRepository: repo,
        themeSettings: settings,
      ),
    );
    await tester.pumpAndSettle();
    if (screen == _Screen.profile || screen == _Screen.settings) {
      await openProfile(tester);
    }
    if (screen == _Screen.settings) {
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
    }
    expect(tester.takeException(), isNull);
    return repo;
  }

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    for (final screen in _Screen.values) {
      testWidgets('Блок 3: ${screen.name}, ${mode.name}', (tester) async {
        await mount(tester, screen, mode);
        final scaffold = find.byType(Scaffold).last;
        expect(
          Theme.of(tester.element(scaffold)).brightness,
          mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
        );
        switch (screen) {
          case _Screen.login:
            expect(find.byKey(const Key('login-email')), findsOneWidget);
            expect(find.byKey(const Key('login-password')), findsOneWidget);
            expect(
              find.byKey(const Key('sign-in')).hitTestable(),
              findsOneWidget,
            );
            expect(
              tester.getTopLeft(find.text('С возвращением')).dy,
              greaterThan(200),
            );
          case _Screen.offline:
            expect(find.text('Не удалось подключиться'), findsOneWidget);
            expect(find.text('Нет связи с сервером.'), findsOneWidget);
            expect(
              find.byKey(const Key('auth-retry')).hitTestable(),
              findsOneWidget,
            );
          case _Screen.noRole:
            expect(find.text('Нужна роль'), findsOneWidget);
            expect(
              find.byKey(const Key('auth-retry')).hitTestable(),
              findsOneWidget,
            );
            expect(find.byType(PassengerScreen), findsNothing);
          case _Screen.blocked:
            expect(find.text('Доступ ограничен'), findsOneWidget);
            expect(
              find.byKey(const Key('auth-exit')).hitTestable(),
              findsOneWidget,
            );
            expect(find.byType(PassengerScreen), findsNothing);
          case _Screen.admin:
            expect(find.text('Администратор'), findsOneWidget);
            expect(find.byType(PassengerScreen), findsNothing);
            expect(find.byType(DriverScreen), findsNothing);
            expect(
              find.byKey(const Key('sign-out')).hitTestable(),
              findsOneWidget,
            );
          case _Screen.profile:
            expect(find.text('Тестовый пассажир'), findsOneWidget);
            expect(find.text('Аккаунт проверен'), findsOneWidget);
            expect(find.text('Поездки'), findsWidgets);
            expect(find.text('О приложении').hitTestable(), findsOneWidget);
          case _Screen.settings:
            expect(find.byType(SettingsScreen), findsOneWidget);
            for (final value in ThemeMode.values) {
              final tile = tester.widget<ListTile>(
                find.byKey(Key('theme-${value.name}')),
              );
              expect(tile.onTap, isNotNull);
              expect(tile.selected, value == mode);
            }
        }
        checkHorizontalBounds(tester);
        if (captureDesignGoldens) {
          await expectLater(
            scaffold,
            matchesGoldenFile('goldens/block3-${screen.name}-${mode.name}.png'),
          );
        }
        if (screen == _Screen.profile) {
          await tester.tap(
            find.descendant(
              of: find.byKey(const Key('profile-scroll')),
              matching: find.text('Поездки'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.text('Ваши поездки'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }

  for (final (size, scale, name) in [
    (const Size(320, 568), 3.2, 'Очень длинное вымышленное имя пассажира'),
    (const Size(844, 390), 2.0, '   '),
    (const Size(800, 1280), 1.0, 'Тестовый пассажир'),
  ]) {
    testWidgets('Профиль и настройки: $size, ×$scale', (tester) async {
      final repo = await mount(
        tester,
        _Screen.profile,
        ThemeMode.light,
        size: size,
        scale: scale,
        name: name,
      );
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('sign-out')));
      expect(find.byKey(const Key('sign-out')).hitTestable(), findsOneWidget);
      await scrollTo(tester, find.text('Настройки'), delta: -180);
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      for (final mode in [ThemeMode.dark, ThemeMode.system, ThemeMode.light]) {
        await scrollTo(
          tester,
          find.byKey(Key('theme-${mode.name}')),
          delta: mode == ThemeMode.light ? -180 : 180,
        );
        await tester.tap(find.byKey(Key('theme-${mode.name}')));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<ListTile>(find.byKey(Key('theme-${mode.name}')))
              .selected,
          isTrue,
        );
        checkHorizontalBounds(tester);
      }
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('sign-out')));
      await tester.tap(find.byKey(const Key('sign-out')));
      await tester.pumpAndSettle();
      expect(repo.logouts, 1);
      expect(find.byType(ProfileScreen), findsNothing);
      expect(find.byKey(const Key('login-email')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Вход: системные отступы, клавиатура и длинное сообщение', (
    tester,
  ) async {
    tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
    addTearDown(tester.view.resetPadding);
    final repo = await mount(
      tester,
      _Screen.login,
      ThemeMode.light,
      size: const Size(360, 740),
    );
    repo.loginError = const AuthFailure(AuthFailureKind.storage);
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();
    expect(
      find.text('Не удалось безопасно прочитать или сохранить сессию.'),
      findsOneWidget,
    );
    await tester.showKeyboard(find.byKey(const Key('login-password')));
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('sign-in')));
    final button = tester.getRect(find.byKey(const Key('sign-in')));
    expect(button.top, greaterThanOrEqualTo(24));
    expect(button.bottom, lessThanOrEqualTo(460));
    checkHorizontalBounds(tester);
    expect(tester.takeException(), isNull);
  });
}
