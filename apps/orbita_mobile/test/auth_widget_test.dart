import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart';

import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'test_helpers.dart';
import 'responsive_test.dart' show checkHorizontalBounds;

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  for (final role in UserRole.values) {
    testWidgets(
      'Серверная роль ${role.name} открывает только допустимый экран',
      (tester) async {
        final repo = FakeAuthRepository()
          ..saved = testSession()
          ..access = testAccess(role);
        await tester.pumpWidget(
          OrbitaApp(device: FakeDevice(), authRepository: repo),
        );
        await tester.pumpAndSettle();
        expect(
          find.byType(PassengerScreen),
          role == UserRole.passenger ? findsOneWidget : findsNothing,
        );
        expect(
          find.byType(DriverScreen),
          role == UserRole.driver ? findsOneWidget : findsNothing,
        );
        if (role == UserRole.admin) {
          expect(find.textContaining('Администратор:'), findsOneWidget);
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final status in [
    AccessStatus.noRole,
    AccessStatus.blocked,
    AccessStatus.unknownRole,
    AccessStatus.noProfile,
    AccessStatus.inconsistent,
  ]) {
    testWidgets(
      'Нейтральный экран ${status.name} не содержит чужих рабочих экранов',
      (tester) async {
        final repo = FakeAuthRepository()
          ..saved = testSession()
          ..access = ServerAccess(userId: userA, status: status);
        await tester.pumpWidget(
          OrbitaApp(device: FakeDevice(), authRepository: repo),
        );
        await tester.pumpAndSettle();
        expect(find.byType(PassengerScreen), findsNothing);
        expect(find.byType(DriverScreen), findsNothing);
        expect(find.text('Выйти'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('Форма входа с клавиатурой и системным шрифтом $scale', (
      tester,
    ) async {
      setViewport(tester, const Size(360, 800), scale);
      final repo = FakeAuthRepository();
      await tester.pumpWidget(
        OrbitaApp(device: FakeDevice(), authRepository: repo),
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('login-email')));
      await tester.enterText(
        find.byKey(const Key('login-email')),
        'artificial@example.test',
      );
      await scrollTo(tester, find.byKey(const Key('login-password')));
      await tester.enterText(
        find.byKey(const Key('login-password')),
        'not-a-real-password',
      );
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      checkHorizontalBounds(tester);
      expect(tester.takeException(), isNull);
      await scrollTo(tester, find.byKey(const Key('sign-in')));
      await tester.tap(find.byKey(const Key('sign-in')));
      await tester.pumpAndSettle();
      expect(repo.logins, 1);
      expect(find.byType(PassengerScreen), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
    testWidgets('Нейтральное состояние и ошибка при крупном шрифте $scale', (
      tester,
    ) async {
      setViewport(tester, const Size(360, 800), scale);
      final repo = FakeAuthRepository()
        ..saved = testSession()
        ..accessError = const AuthFailure(AuthFailureKind.network);
      await tester.pumpWidget(
        OrbitaApp(device: FakeDevice(), authRepository: repo),
      );
      await tester.pumpAndSettle();
      expect(find.text('Нет связи с сервером.'), findsOneWidget);
      checkHorizontalBounds(tester);
      expect(tester.takeException(), isNull);
      expect(find.byType(DriverScreen), findsNothing);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
