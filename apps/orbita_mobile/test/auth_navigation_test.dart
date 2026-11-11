import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/screens/device_check_screen.dart';
import 'package:orbita_mobile/src/screens/account_pages.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart';

import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'responsive_test.dart' show checkHorizontalBounds;
import 'test_helpers.dart';

Future<void> mountAccount(
  WidgetTester tester,
  FakeAuthRepository repository,
) async {
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  await tester.pumpWidget(
    OrbitaApp(device: FakeDevice(), authRepository: repository),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'Единая форма сразу: нет выбора роли, промежуточного входа и Back',
    (tester) async {
      await mountAccount(tester, FakeAuthRepository());
      expect(find.byKey(const Key('login-email')), findsOneWidget);
      expect(find.byKey(const Key('login-password')), findsOneWidget);
      expect(find.text('Войти в аккаунт'), findsNothing);
      expect(find.text('Выберите интерфейс'), findsNothing);
      expect(find.textContaining('Чик, Прокудское'), findsNothing);
      expect(find.byType(BackButton), findsNothing);
      expect(find.text('Проверка API'), findsNothing);
    },
  );

  testWidgets('При восстановлении сессии до прав нет мигания формы входа', (
    tester,
  ) async {
    final pending = Completer<AuthSession?>();
    final repository = FakeAuthRepository()..restorePending = pending;
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      OrbitaApp(device: FakeDevice(), authRepository: repository),
    );
    await tester.pump(const Duration(seconds: 1));
    try {
      expect(find.byKey(const Key('startup-splash')), findsOneWidget);
      expect(find.byKey(const Key('login-email')), findsNothing);
      expect(find.text('Проверяем сессию и доступ'), findsNothing);
      expect(find.text('Проверка API'), findsNothing);
      expect(find.byType(BackButton), findsNothing);
    } finally {
      pending.complete(testSession());
      await tester.pumpAndSettle();
    }
    expect(find.byType(PassengerScreen), findsOneWidget);
    expect(find.byKey(const Key('login-email')), findsNothing);
  });

  testWidgets('Перепроверка сохраняет вкладку и введённый адрес', (
    tester,
  ) async {
    final repository = FakeAuthRepository()..saved = testSession();
    await mountAccount(tester, repository);
    await scrollTo(tester, find.byKey(const Key('pickup')));
    await tester.enterText(find.byKey(const Key('pickup')), 'Учебный адрес');
    tester.testTextInput.hide();
    await openProfile(tester);
    final pending = Completer<ServerAccess>();
    repository.accessPending = pending;
    await tester.pump(const Duration(seconds: 30));
    await tester.pump();
    try {
      expect(find.byType(ProfileScreen), findsOneWidget);
      expect(find.byKey(const Key('login-email')), findsNothing);
      await tester.tap(find.byKey(const Key('nav-1')), warnIfMissed: false);
      await tester.pump();
      expect(find.byType(ProfileScreen), findsOneWidget);
    } finally {
      repository.accessPending = null;
      pending.complete(testAccess());
      await tester.pumpAndSettle();
    }
    expect(find.byType(ProfileScreen), findsOneWidget);
    await tester.tap(find.byKey(const Key('nav-0')));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('pickup')), delta: -180);
    expect(find.text('Учебный адрес'), findsOneWidget);
  });

  testWidgets('Блокировка закрывает роль и показывает служебную карточку', (
    tester,
  ) async {
    final repository = FakeAuthRepository()..saved = testSession();
    await mountAccount(tester, repository);
    await openProfile(tester);
    repository.access = const ServerAccess(
      userId: userA,
      status: AccessStatus.blocked,
    );
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byType(PassengerScreen), findsNothing);
    expect(find.byType(DriverScreen), findsNothing);
    expect(find.byKey(const Key('login-email')), findsNothing);
    expect(find.byKey(const Key('auth-state-card')), findsOneWidget);
    expect(
      find.text('Аккаунт заблокирован. Обратитесь к администратору.'),
      findsOneWidget,
    );
    expect(repository.logouts, 0);
    repository.access = testAccess();
    await scrollTo(tester, find.byKey(const Key('auth-retry')));
    await tester.tap(find.byKey(const Key('auth-retry')));
    await tester.pumpAndSettle();
    expect(find.byType(PassengerScreen), findsOneWidget);
    expect(repository.logins, 0);
  });

  testWidgets(
    'Реальная смена роли закрывает прежний экран и меняет интерфейс',
    (tester) async {
      final repository = FakeAuthRepository()..saved = testSession();
      await mountAccount(tester, repository);
      await openProfile(tester);
      repository.access = testAccess(UserRole.driver);
      await tester.pump(const Duration(seconds: 30));
      await tester.pumpAndSettle();
      expect(find.byType(PassengerScreen), findsNothing);
      expect(find.byType(DriverScreen), findsOneWidget);
      expect(find.text('Текущий заказ'), findsOneWidget);
      expect(repository.logins, 0);
    },
  );

  testWidgets('Временный сетевой сбой закрывает роль, но сохраняет сессию', (
    tester,
  ) async {
    final repository = FakeAuthRepository()..saved = testSession();
    await mountAccount(tester, repository);
    repository.accessError = const AuthFailure(AuthFailureKind.network);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byType(PassengerScreen), findsNothing);
    expect(find.text('Нет связи с сервером.'), findsOneWidget);
    expect(find.byKey(const Key('login-password')), findsNothing);
    expect(repository.saved, isNotNull);
    expect(repository.logouts, 0);
    repository.accessError = null;
    await tester.tap(find.byKey(const Key('auth-retry')));
    await tester.pumpAndSettle();
    expect(find.byType(PassengerScreen), findsOneWidget);
    expect(repository.logins, 0);
  });

  testWidgets(
    'Back из профиля ведёт на основную вкладку, а из диагностики назад',
    (tester) async {
      await mountAccount(tester, FakeAuthRepository()..saved = testSession());
      await openProfile(tester);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('create-order')), findsOneWidget);
      expect(find.text('Выберите интерфейс'), findsNothing);
      await openCheck(tester, 'Проверка устройства');
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(AboutScreen), findsOneWidget);
      expect(find.byType(DeviceCheckScreen), findsNothing);
    },
  );

  testWidgets(
    'В профиле один раздел диагностики, все уникальные проверки внутри',
    (tester) async {
      await mountAccount(tester, FakeAuthRepository()..saved = testSession());
      await openProfile(tester);
      expect(find.text('Проверка API'), findsNothing);
      expect(find.text('Проверка уведомлений'), findsNothing);
      expect(find.text('Диагностика геолокации'), findsNothing);
      expect(find.text('Сменить интерфейс просмотра'), findsNothing);
      await tester.tap(find.text('О приложении'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Проверка устройства'));
      await tester.tap(find.text('Проверка устройства'));
      await tester.pumpAndSettle();
      for (final name in [
        'notifications-card',
        'location-card',
        'service-card',
      ]) {
        expect(find.byKey(Key(name)), findsOneWidget);
      }
      await scrollTo(tester, find.byKey(const Key('advanced-diagnostics')));
      await tester.tap(find.byKey(const Key('advanced-diagnostics')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('Проверка API'));
      expect(find.text('Проверка API'), findsOneWidget);
    },
  );

  testWidgets('Потеря доступа закрывает и вложенную диагностику', (
    tester,
  ) async {
    final repository = FakeAuthRepository()..saved = testSession();
    await mountAccount(tester, repository);
    await openCheck(tester, 'Проверка устройства');
    repository.access = const ServerAccess(
      userId: userA,
      status: AccessStatus.blocked,
    );
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.byType(DeviceCheckScreen), findsNothing);
    expect(find.byKey(const Key('login-email')), findsNothing);
    expect(find.byKey(const Key('auth-state-card')), findsOneWidget);
    expect(find.textContaining('Аккаунт заблокирован.'), findsOneWidget);
  });

  testWidgets('Показ пароля не сохраняет его после отправки', (tester) async {
    final repository = FakeAuthRepository();
    await mountAccount(tester, repository);
    await scrollTo(tester, find.byKey(const Key('login-password')));
    await tester.enterText(
      find.byKey(const Key('login-password')),
      'искусственный пароль',
    );
    await tester.tap(find.byTooltip('Показать пароль'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('login-password')))
          .obscureText,
      isFalse,
    );
    await scrollTo(tester, find.byKey(const Key('sign-in')));
    await tester.tap(find.byKey(const Key('sign-in')));
    await tester.pumpAndSettle();
    await openProfile(tester);
    await scrollTo(tester, find.byKey(const Key('sign-out')));
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    final field = tester.widget<TextField>(
      find.byKey(const Key('login-password')),
    );
    expect(field.controller!.text, isEmpty);
    expect(field.obscureText, isTrue);
  });

  testWidgets('Медленное восстановление имеет тайм-аут и безопасный повтор', (
    tester,
  ) async {
    final pending = Completer<AuthSession?>();
    final repository = FakeAuthRepository()..restorePending = pending;
    addTearDown(() => tester.pumpWidget(const SizedBox()));
    await tester.pumpWidget(
      OrbitaApp(device: FakeDevice(), authRepository: repository),
    );
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('Подключаемся…'), findsOneWidget);
    expect(find.byKey(const Key('login-email')), findsNothing);
    await tester.pump(const Duration(seconds: 9));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('startup-splash')), findsNothing);
    expect(find.byKey(const Key('auth-retry')), findsOneWidget);
    expect(find.text('Сервер не ответил за отведённое время.'), findsOneWidget);
    pending.complete(testSession());
    await tester.pumpAndSettle();
    expect(find.byType(PassengerScreen), findsNothing);
  });

  testWidgets(
    'Фон скрывает содержимое, возврат сохраняет вкладку после проверки',
    (tester) async {
      final repository = FakeAuthRepository()..saved = testSession();
      await mountAccount(tester, repository);
      addTearDown(() {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      });
      await openProfile(tester);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pump();
      expect(find.byKey(const Key('background-privacy-cover')), findsOneWidget);
      final pending = Completer<ServerAccess>();
      repository.accessPending = pending;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();
      try {
        expect(find.byType(ProfileScreen), findsOneWidget);
        expect(find.byKey(const Key('background-privacy-cover')), findsNothing);
      } finally {
        repository.accessPending = null;
        pending.complete(testAccess());
        await tester.pumpAndSettle();
      }
      expect(find.byType(ProfileScreen), findsOneWidget);
    },
  );

  for (final size in [const Size(800, 1280), const Size(1280, 800)]) {
    for (final scale in [1.0, 3.2]) {
      testWidgets('Форма на планшете $size, системный шрифт $scale', (
        tester,
      ) async {
        setViewport(tester, size, scale);
        await mountAccount(tester, FakeAuthRepository());
        checkHorizontalBounds(tester);
        await scrollTo(tester, find.byKey(const Key('login-password')));
        await tester.enterText(
          find.byKey(const Key('login-password')),
          'fixture',
        );
        tester.view.viewInsets = const FakeViewPadding(bottom: 280);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        checkHorizontalBounds(tester);
      });
    }
  }
}
