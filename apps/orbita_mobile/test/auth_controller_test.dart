import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/auth/auth_controller.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';

import 'fake_auth_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeAuthRepository repo;
  late AuthController controller;
  setUp(() {
    repo = FakeAuthRepository();
    controller = AuthController(repo);
  });
  tearDown(() => controller.dispose());

  for (final role in UserRole.values) {
    test('Вход ${role.name}: только актуальная серверная роль', () async {
      repo.access = testAccess(role);
      await controller.start();
      await controller.signIn('artificial@example.test', 'not-a-real-password');
      expect(
        controller.phase,
        role == UserRole.admin ? AuthPhase.admin : AuthPhase.active,
      );
      expect(controller.canUseRole, role != UserRole.admin);
      expect(repo.fetches, 1);
    });
  }
  for (final kind in [
    AuthFailureKind.invalidCredentials,
    AuthFailureKind.rateLimited,
    AuthFailureKind.network,
    AuthFailureKind.tls,
    AuthFailureKind.http,
    AuthFailureKind.server,
    AuthFailureKind.sessionExpired,
  ]) {
    test(
      'Ошибка входа ${kind.name}: русский безопасный код и закрытый доступ',
      () async {
        await controller.start();
        repo.loginError = AuthFailure(kind, httpStatus: 503);
        await controller.signIn(
          'artificial@example.test',
          'not-a-real-password',
        );
        expect(controller.phase, AuthPhase.failure);
        expect(controller.failure!.kind, kind);
        expect(controller.canUseRole, false);
        expect(controller.access, isNull);
        expect(
          controller.failure.toString(),
          isNot(contains('not-a-real-password')),
        );
      },
    );
  }
  test(
    'Выход немедленно закрывает роль и удаляет искусственно сохранённую сессию',
    () async {
      repo.saved = testSession();
      await controller.start();
      expect(controller.canUseRole, true);
      final future = controller.signOut();
      expect(controller.canUseRole, false);
      await future;
      expect(controller.phase, AuthPhase.signedOut);
      expect(repo.saved, isNull);
    },
  );
  test(
    'Холодный запуск с сохранённой сессией обязательно запрашивает сервер',
    () async {
      repo.saved = testSession();
      await controller.start();
      expect(repo.restores, 1);
      expect(repo.fetches, 1);
      expect(controller.canUseRole, true);
    },
  );
  test('Истёкшая сессия обновляется до запроса роли', () async {
    repo.saved = AuthSession(
      userId: userA,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    await controller.start();
    expect(repo.refreshes, 1);
    expect(repo.fetches, 1);
    expect(controller.canUseRole, true);
  });
  test(
    'Отозванный refresh закрывает UI без выдуманной ошибки пароля',
    () async {
      repo.saved = AuthSession(
        userId: userA,
        expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
      );
      repo.refreshError = const AuthFailure(AuthFailureKind.sessionExpired);
      await controller.start();
      expect(controller.failure!.kind, AuthFailureKind.sessionExpired);
      expect(repo.fetches, 0);
      expect(controller.canUseRole, false);
    },
  );
  test('Холодный запуск без сети сохраняет Auth-сессию; восстановление связи работает', () async {
    repo.saved = testSession();
    repo.accessError = const AuthFailure(AuthFailureKind.network);
    await controller.start();
    expect(controller.canUseRole, false);
    expect(repo.saved, isNotNull);
    expect(repo.logouts, 0);
    repo.accessError = null;
    await controller.retry();
    expect(controller.canUseRole, true);
  });
  test('Сетевая ошибка refresh не удаляет сохранённую сессию', () async {
    repo.saved = AuthSession(
      userId: userA,
      expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
    );
    repo.refreshError = const AuthFailure(AuthFailureKind.network);
    await controller.start();
    expect(repo.saved, isNotNull);
    expect(repo.logouts, 0);
    expect(controller.canUseRole, false);
  });
  for (final (status, phase) in [
    (AccessStatus.noRole, AuthPhase.noRole),
    (AccessStatus.blocked, AuthPhase.blocked),
    (AccessStatus.unknownRole, AuthPhase.unknownRole),
    (AccessStatus.noProfile, AuthPhase.noProfile),
    (AccessStatus.inconsistent, AuthPhase.inconsistent),
  ]) {
    test(
      'Нейтральное состояние ${status.name} не открывает пассажира/водителя',
      () async {
        repo.saved = testSession();
        repo.access = ServerAccess(
          userId: userA,
          status: status,
          role: UserRole.driver,
          version: 1,
        );
        await controller.start();
        expect(controller.phase, phase);
        expect(controller.canUseRole, false);
      },
    );
  }
  test(
    'Отзыв роли в открытом приложении закрывает прежнее состояние',
    () async {
      repo.saved = testSession();
      await controller.start();
      repo.access = const ServerAccess(
        userId: userA,
        status: AccessStatus.noRole,
      );
      final check = controller.revalidate();
      expect(controller.canUseRole, false);
      await check;
      expect(controller.phase, AuthPhase.revoked);
    },
  );
  test(
    'Возврат из фона не восстанавливает старую роль; ждёт ответа новой',
    () async {
      repo.saved = testSession();
      await controller.start();
      controller.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(controller.canUseRole, false);
      expect(controller.access, isNull);
      repo.accessPending = Completer<ServerAccess>();
      controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(controller.canUseRole, false);
      repo.accessPending!.complete(testAccess(UserRole.driver));
      await Future<void>.delayed(Duration.zero);
      expect(controller.access!.role, UserRole.driver);
      expect(controller.canUseRole, true);
    },
  );
  test(
    'Действие старой роли отменяется и поздний результат отбрасывается',
    () async {
      repo.saved = testSession();
      await controller.start();
      final pending = Completer<int>();
      var cancelled = false;
      final work = controller.guardAction((lease) {
        lease.onCancel(() => cancelled = true);
        return pending.future;
      });
      repo.access = const ServerAccess(
        userId: userA,
        status: AccessStatus.blocked,
      );
      await controller.revalidate();
      expect(cancelled, true);
      pending.complete(42);
      expect(await work, isNull);
      expect(controller.canUseRole, false);
    },
  );
  test('Нельзя начать действие без актуальных прав', () async {
    await controller.start();
    var called = false;
    await expectLater(
      controller.guardAction((_) async {
        called = true;
        return 1;
      }),
      throwsA(isA<AuthFailure>()),
    );
    expect(called, false);
  });
  test('Поздний ответ пользователя A после выхода не открывает роль пользователя B', () async {
    repo.saved = testSession();
    final pending = Completer<ServerAccess>();
    repo.accessPending = pending;
    final old = controller.start();
    await Future<void>.delayed(Duration.zero);
    await controller.signOut();
    repo.accessPending = null;
    repo.loginSession = testSession(userB);
    repo.access = testAccess(UserRole.driver, userB);
    await controller.signIn(
      'second-artificial@example.test',
      'not-a-real-password',
    );
    expect(controller.access!.userId, userB);
    pending.complete(testAccess());
    await old;
    expect(controller.access!.userId, userB);
    expect(controller.access!.role, UserRole.driver);
    expect(controller.canUseRole, true);
  });
  test('Поздний ответ проверки A после выхода отбрасывается', () async {
    repo.saved = testSession();
    final pending = Completer<ServerAccess>();
    repo.accessPending = pending;
    final old = controller.start();
    await Future<void>.delayed(Duration.zero);
    await controller.signOut();
    pending.complete(testAccess());
    await old;
    expect(controller.phase, AuthPhase.signedOut);
    expect(controller.access, isNull);
  });
  test('Поздний ответ входа после выхода отбрасывается', () async {
    await controller.start();
    repo.loginPending = Completer<AuthSession>();
    final old = controller.signIn(
      'artificial@example.test',
      'not-a-real-password',
    );
    await controller.signOut();
    repo.loginPending!.complete(testSession());
    await old;
    expect(controller.canUseRole, false);
    expect(controller.session, isNull);
    expect(repo.fetches, 0);
  });
  test('Ответ роли другого пользователя отклоняется', () async {
    repo.saved = testSession();
    repo.access = testAccess(UserRole.admin, userB);
    await controller.start();
    expect(controller.failure!.kind, AuthFailureKind.unverified);
    expect(controller.canUseRole, false);
  });
  test('Неожиданный active без версии не становится полномочием', () async {
    repo.saved = testSession();
    repo.access = const ServerAccess(
      userId: userA,
      status: AccessStatus.active,
      role: UserRole.driver,
    );
    await controller.start();
    expect(controller.phase, AuthPhase.inconsistent);
    expect(controller.canUseRole, false);
  });
  test('Сбой проверки роли закрывает UI, не выполняя выход', () async {
    repo.saved = testSession();
    await controller.start();
    repo.accessError = const AuthFailure(AuthFailureKind.server);
    await controller.revalidate();
    expect(controller.canUseRole, false);
    expect(repo.saved, isNotNull);
    expect(repo.logouts, 0);
  });
  test('Общий таймаут закрывает доступ и отменяет поздний ответ', () async {
    controller.dispose();
    controller = AuthController(
      repo,
      timeout: const Duration(milliseconds: 20),
    );
    repo.saved = testSession();
    final pending = Completer<ServerAccess>();
    repo.accessPending = pending;
    await controller.start();
    expect(controller.failure!.kind, AuthFailureKind.timeout);
    pending.complete(testAccess());
    await Future<void>.delayed(Duration.zero);
    expect(controller.canUseRole, false);
    expect(repo.saved, isNotNull);
  });
  test(
    'Периодическая проверка обнаруживает отзыв в активном приложении',
    () async {
      controller.dispose();
      controller = AuthController(
        repo,
        pollInterval: const Duration(milliseconds: 20),
      );
      repo.saved = testSession();
      await controller.start();
      repo.access = const ServerAccess(
        userId: userA,
        status: AccessStatus.noRole,
      );
      await Future<void>.delayed(const Duration(milliseconds: 35));
      expect(controller.canUseRole, false);
      expect(controller.phase, isIn([AuthPhase.noRole, AuthPhase.revoked]));
    },
  );
}
