import 'dart:async';

import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/auth_repository.dart';
import '../domain/contracts.dart';

bool _verifiedDriver(AuthController controller) {
  final session = controller.session;
  final access = controller.access;
  return controller.canUseRole &&
      !controller.busy &&
      controller.foreground &&
      controller.repository.configured &&
      session != null &&
      !session.expired &&
      access != null &&
      access.active &&
      access.role == UserRole.driver &&
      access.userId == session.userId;
}

/// Диагностика использует тот же временный допуск, что и рабочие операции Auth.
/// Создать этот scope через PreviewRole или локальный флаг невозможно.
abstract final class DriverDemoAccess {
  static bool allowed(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_DriverDemoScope>()?.allowed ??
      false;
}

class _DemoLease {
  _DemoLease(this.controller, this.work);
  final AuthController controller;
  final RoleWorkLease work;
  final done = Completer<void>();
  bool active = true;

  bool get allowed => active && !work.cancelled && _verifiedDriver(controller);

  void close() {
    active = false;
    if (!done.isCompleted) done.complete();
  }
}

class _DriverDemoScope extends InheritedWidget {
  const _DriverDemoScope({required this.lease, required super.child});
  final _DemoLease lease;
  bool get allowed => lease.allowed;

  @override
  bool updateShouldNotify(_DriverDemoScope oldWidget) =>
      lease != oldWidget.lease;
}

/// Вход только из диагностической UI-проводки с живым доверенным контроллером.
/// Потеря допуска уничтожает subtree, включая таймеры и локальные демособытия.
class DriverDemoGate extends StatefulWidget {
  const DriverDemoGate({
    required this.controller,
    required this.child,
    super.key,
  });
  final AuthController controller;
  final Widget child;

  @override
  State<DriverDemoGate> createState() => _DriverDemoGateState();
}

class _DriverDemoGateState extends State<DriverDemoGate> {
  _DemoLease? _lease;
  Timer? _expiry;
  int _revision = 0;
  bool _listening = false;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  void _attach() {
    // Закрытый прямой вход не ожидает будущего назначения роли. Его нужно
    // открыть заново из диагностики после завершённой серверной проверки.
    // Также не подписываемся на уже уничтоженный ChangeNotifier.
    if (!_verifiedDriver(widget.controller)) return;
    widget.controller.addListener(_changed);
    _listening = true;
    _open();
  }

  void _open() {
    if (_lease != null || !_verifiedDriver(widget.controller)) return;
    final controller = widget.controller;
    unawaited(_hold(controller));
  }

  Future<void> _hold(AuthController controller) async {
    try {
      await controller.guardAction<void>((work) async {
        final lease = _DemoLease(controller, work);
        _lease = lease;
        _revision++;
        work.onCancel(() => _revoke(lease));
        final remaining = controller.session!.expiresAt.difference(
          DateTime.now(),
        );
        _expiry = Timer(remaining.isNegative ? Duration.zero : remaining, () {
          _revoke(lease);
        });
        await lease.done.future;
      });
    } on AuthFailure {
      // Срок сессии может закончиться между чтением права и guardAction.
      // В этом случае scope не создаётся.
    }
  }

  void _revoke(_DemoLease lease) {
    lease.close();
    if (!identical(_lease, lease)) return;
    _expiry?.cancel();
    _expiry = null;
    _lease = null;
    if (mounted) setState(() {});
  }

  void _changed() {
    if (_verifiedDriver(widget.controller)) {
      _open();
      if (mounted) setState(() {});
    } else {
      final lease = _lease;
      if (lease != null) _revoke(lease);
    }
  }

  void _detach() {
    if (_listening) widget.controller.removeListener(_changed);
    _listening = false;
    _expiry?.cancel();
    _expiry = null;
    _lease?.close();
    _lease = null;
  }

  @override
  void didUpdateWidget(covariant DriverDemoGate oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    if (_listening) oldWidget.controller.removeListener(_changed);
    _listening = false;
    _expiry?.cancel();
    _lease?.close();
    _lease = null;
    _attach();
  }

  @override
  void dispose() {
    _detach();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lease = _lease;
    if (lease == null || !lease.allowed) return const DriverDemoDeniedScreen();
    return _DriverDemoScope(
      lease: lease,
      child: KeyedSubtree(key: ValueKey(_revision), child: widget.child),
    );
  }
}

/// Безопасный результат прямого маршрута: он не получает контроллер Auth.
class DriverDemoDeniedScreen extends StatelessWidget {
  const DriverDemoDeniedScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    key: const Key('driver-demo-denied'),
    appBar: AppBar(title: const Text('Диагностика водителя')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            const Icon(Icons.lock_outline, size: 40),
            const SizedBox(height: 16),
            Text(
              'Демонстрация недоступна',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 12),
            const Text(
              'Нужны действующая сессия и подтверждённая роль водителя. '
              'После проверки откройте диагностику заново.',
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    ),
  );
}
