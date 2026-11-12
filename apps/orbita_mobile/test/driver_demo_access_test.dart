import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/auth/auth_controller.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/ui/driver_demo_access.dart';

import 'fake_auth_repository.dart';

class _Account {
  _Account(this.repository)
    : controller = AuthController(
        repository,
        pollInterval: const Duration(hours: 1),
      );
  final FakeAuthRepository repository;
  final AuthController controller;
  bool disposed = false;

  void dispose() {
    if (disposed) return;
    disposed = true;
    controller.dispose();
  }
}

class _LocalEvents {
  int disposed = 0, completions = 0;
  Completer<void>? pending;
}

class _AccountOwner extends StatefulWidget {
  const _AccountOwner({required this.account, required this.child});
  final _Account account;
  final Widget child;

  @override
  State<_AccountOwner> createState() => _AccountOwnerState();
}

class _AccountOwnerState extends State<_AccountOwner> {
  @override
  void dispose() {
    widget.account.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _LocalDemo extends StatefulWidget {
  const _LocalDemo(this.events);
  final _LocalEvents events;

  @override
  State<_LocalDemo> createState() => _LocalDemoState();
}

class _LocalDemoState extends State<_LocalDemo> {
  int count = 0;

  Future<void> _step() async {
    if (!DriverDemoAccess.allowed(context)) return;
    final pending = widget.events.pending;
    if (pending != null) await pending.future;
    if (!mounted || !DriverDemoAccess.allowed(context)) return;
    widget.events.completions++;
    setState(() => count++);
  }

  @override
  void dispose() {
    widget.events.disposed++;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!DriverDemoAccess.allowed(context)) {
      return const DriverDemoDeniedScreen();
    }
    return Scaffold(
      body: Column(
        children: [
          Text('ДЕМО: $count'),
          TextButton(onPressed: _step, child: const Text('Локальный шаг')),
        ],
      ),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Account> account(
    WidgetTester tester, {
    UserRole role = UserRole.driver,
  }) async {
    final result = _Account(
      FakeAuthRepository()
        ..saved = testSession()
        ..access = testAccess(role),
    );
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      result.dispose();
    });
    await result.controller.start();
    return result;
  }

  Future<_LocalEvents> mount(
    WidgetTester tester,
    _Account account, {
    _LocalEvents? events,
  }) async {
    final local = events ?? _LocalEvents();
    await tester.pumpWidget(
      MaterialApp(
        home: _AccountOwner(
          account: account,
          child: DriverDemoGate(
            controller: account.controller,
            child: _LocalDemo(local),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    return local;
  }

  testWidgets('Проверенный водитель получает только локальные демособытия', (
    tester,
  ) async {
    final auth = await account(tester);
    final before = auth.repository.fetches;
    await mount(tester, auth);
    expect(find.text('ДЕМО: 0'), findsOneWidget);
    await tester.tap(find.text('Локальный шаг'));
    await tester.pump();
    expect(find.text('ДЕМО: 1'), findsOneWidget);
    expect(auth.repository.fetches, before);
    expect(auth.repository.logins, 0);
    expect(auth.repository.logouts, 0);
  });

  for (final role in [UserRole.passenger, UserRole.admin]) {
    testWidgets('Роль ${role.name} не создаёт демо-subtree', (tester) async {
      final auth = await account(tester, role: role);
      final events = await mount(tester, auth);
      expect(find.byKey(const Key('driver-demo-denied')), findsOneWidget);
      expect(find.text('Локальный шаг'), findsNothing);
      expect(events.completions, 0);
    });
  }

  for (final state in [
    'noSession',
    'noRole',
    'blocked',
    'revoked',
    'expired',
    'mismatch',
    'checking',
    'background',
    'disposed',
    'unconfigured',
  ]) {
    testWidgets('Нет допуска к демо: $state', (tester) async {
      final auth = await account(tester);
      Future<void>? checking;
      Completer<ServerAccess>? pending;
      switch (state) {
        case 'noSession':
          await auth.controller.signOut();
        case 'noRole':
          auth.controller.phase = AuthPhase.noRole;
          auth.controller.access = const ServerAccess(
            userId: userA,
            status: AccessStatus.noRole,
          );
        case 'blocked':
          auth.repository.access = const ServerAccess(
            userId: userA,
            status: AccessStatus.blocked,
          );
          await auth.controller.revalidate();
        case 'revoked':
          auth.repository.access = const ServerAccess(
            userId: userA,
            status: AccessStatus.noRole,
          );
          await auth.controller.revalidate();
          expect(auth.controller.phase, AuthPhase.revoked);
        case 'expired':
          auth.controller.session = AuthSession(
            userId: userA,
            expiresAt: DateTime.now().subtract(const Duration(seconds: 1)),
          );
        case 'mismatch':
          auth.controller.access = testAccess(UserRole.driver, userB);
        case 'checking':
          pending = Completer<ServerAccess>();
          auth.repository.accessPending = pending;
          checking = auth.controller.revalidate();
        case 'background':
          auth.controller.didChangeAppLifecycleState(
            AppLifecycleState.inactive,
          );
        case 'disposed':
          auth.dispose();
        case 'unconfigured':
          auth.repository.configured = false;
      }
      await mount(tester, auth);
      expect(find.byKey(const Key('driver-demo-denied')), findsOneWidget);
      expect(find.text('Локальный шаг'), findsNothing);
      if (pending != null) {
        pending.complete(testAccess(UserRole.driver));
        await checking;
        await tester.pumpAndSettle();
        // Прямой закрытый вход не превращается сам в разрешённый маршрут.
        expect(find.byKey(const Key('driver-demo-denied')), findsOneWidget);
      }
    });
  }

  testWidgets('Без доверенного scope прямой экран не включает демо', (
    tester,
  ) async {
    final local = _LocalEvents();
    await tester.pumpWidget(MaterialApp(home: _LocalDemo(local)));
    expect(find.byKey(const Key('driver-demo-denied')), findsOneWidget);
    expect(local.completions, 0);
    expect(tester.takeException(), isNull);
  });

  for (final operation in [
    'recheck',
    'background',
    'logout',
    'blocked',
    'revoked',
    'dispose',
    'expiry',
  ]) {
    testWidgets('Потеря допуска $operation уничтожает локальную демонстрацию', (
      tester,
    ) async {
      final auth = await account(tester);
      if (operation == 'expiry') {
        auth.controller.session = AuthSession(
          userId: userA,
          expiresAt: DateTime.now().add(const Duration(seconds: 1)),
        );
      }
      final local = await mount(tester, auth);
      await tester.tap(find.text('Локальный шаг'));
      await tester.pump();
      expect(find.text('ДЕМО: 1'), findsOneWidget);
      switch (operation) {
        case 'recheck':
          // Оба состояния могут уложиться в один кадр: key всё равно меняется.
          await auth.controller.revalidate();
        case 'background':
          auth.controller.didChangeAppLifecycleState(
            AppLifecycleState.inactive,
          );
        case 'logout':
          await auth.controller.signOut();
        case 'blocked':
          auth.repository.access = const ServerAccess(
            userId: userA,
            status: AccessStatus.blocked,
          );
          await auth.controller.revalidate();
        case 'revoked':
          auth.repository.access = const ServerAccess(
            userId: userA,
            status: AccessStatus.noRole,
          );
          await auth.controller.revalidate();
        case 'dispose':
          auth.dispose();
        case 'expiry':
          await tester.pump(const Duration(seconds: 2));
      }
      await tester.pumpAndSettle();
      expect(local.disposed, 1);
      expect(find.text('ДЕМО: 1'), findsNothing);
      if (operation == 'recheck') {
        expect(find.text('ДЕМО: 0'), findsOneWidget);
      } else {
        expect(find.byKey(const Key('driver-demo-denied')), findsOneWidget);
      }
      if (operation == 'background') {
        auth.controller.didChangeAppLifecycleState(AppLifecycleState.resumed);
        await tester.pumpAndSettle();
        expect(find.text('ДЕМО: 0'), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Позднее локальное подтверждение после отзыва игнорируется', (
    tester,
  ) async {
    final auth = await account(tester);
    final local = _LocalEvents()..pending = Completer<void>();
    await mount(tester, auth, events: local);
    await tester.tap(find.text('Локальный шаг'));
    auth.repository.access = const ServerAccess(
      userId: userA,
      status: AccessStatus.blocked,
    );
    await auth.controller.revalidate();
    await tester.pumpAndSettle();
    local.pending!.complete();
    await tester.pumpAndSettle();
    expect(local.disposed, 1);
    expect(local.completions, 0);
    expect(find.byKey(const Key('driver-demo-denied')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'После закрытия и повторного открытия локальное состояние сброшено',
    (tester) async {
      final auth = await account(tester);
      await mount(tester, auth);
      await tester.tap(find.text('Локальный шаг'));
      await tester.pump();
      await tester.pumpWidget(const SizedBox());
      final restarted = await account(tester);
      await mount(tester, restarted);
      expect(find.text('ДЕМО: 0'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
