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
import 'responsive_test.dart' show checkHorizontalBounds, checkNavigation;
import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);
  final cases = [
    for (final size in [
      const Size(320, 568),
      const Size(360, 740),
      const Size(390, 844),
      const Size(800, 1280),
    ])
      for (final scale in [1.0, 1.3, 2.0, 3.2]) (size, scale),
    (const Size(740, 360), 3.2),
    (const Size(1280, 800), 2.0),
  ];
  for (final (size, scale) in cases) {
    testWidgets('Матрица блока4: $size, ×$scale', (tester) async {
      setViewport(tester, size, scale);
      tester.view.padding = const FakeViewPadding(top: 24, bottom: 20);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewInsets);
      final mode = scale == 1.3 || scale == 3.2
          ? ThemeMode.dark
          : ThemeMode.light;
      SharedPreferences.setMockInitialValues({
        ThemeSettings.storageKey: mode.name,
      });

      Future<void> scene({
        UserRole role = UserRole.passenger,
        AccessStatus status = AccessStatus.active,
        bool signedIn = true,
        bool offline = false,
      }) async {
        await tester.pumpWidget(const SizedBox());
        final repo = FakeAuthRepository()
          ..saved = signedIn ? testSession() : null
          ..access = ServerAccess(
            userId: userA,
            status: status,
            role: role,
            version: 1,
            displayName: 'Тестовый пассажир с длинным вымышленным именем',
          );
        if (offline) {
          repo.accessError = const AuthFailure(AuthFailureKind.network);
        }
        await tester.pumpWidget(
          OrbitaApp(
            key: UniqueKey(),
            device: FakeDevice(),
            authRepository: repo,
          ),
        );
        await tester.pumpAndSettle();
        checkHorizontalBounds(tester);
      }

      Future<void> reachable(Key key) async {
        final finder = find.byKey(key);
        await scrollTo(tester, finder);
        expect(finder.hitTestable(), findsOneWidget);
        final rect = tester.getRect(finder);
        expect(rect.width, greaterThanOrEqualTo(48));
        expect(rect.height, greaterThanOrEqualTo(48));
        checkHorizontalBounds(tester);
      }

      await scene(signedIn: false);
      await tester.showKeyboard(find.byKey(const Key('login-password')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 180);
      await tester.pumpAndSettle();
      await reachable(const Key('sign-in'));
      expect(
        tester.getRect(find.byKey(const Key('sign-in'))).bottom,
        lessThanOrEqualTo(size.height - 180),
      );
      tester.view.resetViewInsets();
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();

      await scene();
      await scrollTo(tester, find.byKey(const Key('destination')));
      expect(find.byType(TextField), findsNWidgets(2));
      await checkNavigation(tester);
      await reachable(const Key('create-order'));
      final order = find.descendant(
        of: find.byKey(const Key('create-order')),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(order).onPressed, isNull);

      await scene(role: UserRole.driver);
      expect(find.byType(DriverScreen), findsOneWidget);
      expect(find.byKey(const Key('driver-demo-entry')), findsNothing);
      expect(find.text('Линия не подключена'), findsOneWidget);
      await checkNavigation(tester);
      await reachable(const Key('shift-control'));

      await scene();
      await openProfile(tester);
      expect(find.byType(ProfileScreen), findsOneWidget);
      await reachable(const Key('sign-out'));
      await scrollTo(tester, find.text('Настройки'), delta: -180);
      await tester.tap(find.text('Настройки'));
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      for (final theme in ThemeMode.values) {
        final finder = find.byKey(Key('theme-${theme.name}'));
        await scrollTo(tester, finder);
        expect(finder.hitTestable(), findsOneWidget);
        expect(tester.widget<ListTile>(finder).onTap, isNotNull);
        checkHorizontalBounds(tester);
      }

      for (final state in [AccessStatus.noRole, AccessStatus.blocked]) {
        await scene(status: state);
        expect(find.byType(PassengerScreen), findsNothing);
        await reachable(
          Key(state == AccessStatus.blocked ? 'auth-exit' : 'auth-retry'),
        );
      }
      await scene(offline: true);
      expect(find.text('Нет связи с сервером.'), findsOneWidget);
      await reachable(const Key('auth-retry'));
      await scene(role: UserRole.admin);
      expect(find.byType(DriverScreen), findsNothing);
      await reachable(const Key('sign-out'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
