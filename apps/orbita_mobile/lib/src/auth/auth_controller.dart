import 'dart:async';

import 'package:flutter/widgets.dart';

import '../domain/contracts.dart';
import 'auth_repository.dart';

enum AuthPhase {
  checking,
  signedOut,
  active,
  admin,
  noRole,
  revoked,
  blocked,
  unknownRole,
  noProfile,
  inconsistent,
  failure,
}

/// Отмена совместная: рабочая операция должна подключить реальную отмену I/O.
/// На 3Б заказов нет; контракт заранее проверяет сброс временного состояния.
class RoleWorkLease {
  bool cancelled = false;
  final List<VoidCallback> _cancel = [];
  void onCancel(VoidCallback action) {
    if (cancelled) {
      action();
    } else {
      _cancel.add(action);
    }
  }

  void invalidate() {
    cancelled = true;
    for (final action in _cancel) {
      try {
        action();
      } catch (_) {}
    }
    _cancel.clear();
  }
}

class AuthController extends ChangeNotifier with WidgetsBindingObserver {
  AuthController(
    this.repository, {
    this.timeout = const Duration(seconds: 12),
    this.pollInterval = const Duration(seconds: 30),
  }) {
    WidgetsBinding.instance.addObserver(this);
  }
  final AuthRepository repository;
  final Duration timeout, pollInterval;
  AuthPhase phase = AuthPhase.checking;
  AuthSession? session;
  ServerAccess? access;
  AuthFailure? failure;
  bool foreground = true, _disposed = false;
  int _epoch = 0;
  Timer? _poll;
  final Set<RoleWorkLease> _work = {};
  bool get busy => phase == AuthPhase.checking;
  bool get canUseRole =>
      !_disposed &&
      foreground &&
      phase == AuthPhase.active &&
      session != null &&
      !session!.expired &&
      access?.active == true &&
      access!.userId == session!.userId &&
      (access!.role == UserRole.passenger || access!.role == UserRole.driver);

  void _invalidate() {
    _poll?.cancel();
    for (final lease in _work) {
      lease.invalidate();
    }
    _work.clear();
    access = null;
  }

  bool _current(int epoch) => !_disposed && foreground && _epoch == epoch;
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  Future<void> start() => _check(restore: true);
  Future<void> retry() => _check(restore: session == null);
  Future<void> revalidate() => _check(restore: session == null);

  Future<void> signIn(String email, String password) async {
    if (_disposed || busy || !foreground) return;
    await _check(credentials: (email, password));
  }

  Future<void> _check({
    bool restore = false,
    (String, String)? credentials,
  }) async {
    if (_disposed || !foreground) return;
    final old = access;
    final previousUser = session?.userId;
    final epoch = ++_epoch;
    _invalidate();
    repository.cancelPending();
    failure = null;
    phase = AuthPhase.checking;
    _emit();
    try {
      await (() async {
        var current = session;
        if (credentials != null) {
          current = await repository.signIn(credentials.$1, credentials.$2);
        } else if (restore) {
          current = await repository.restore();
        }
        if (!_current(epoch)) return;
        session = current;
        if (current == null) {
          phase = AuthPhase.signedOut;
          return;
        }
        if (current.needsRefresh) {
          current = await repository.refresh();
          if (!_current(epoch)) return;
          if (session?.userId != current.userId) {
            throw const AuthFailure(AuthFailureKind.unverified);
          }
          session = current;
        }
        if (current.expired) {
          throw const AuthFailure(AuthFailureKind.sessionExpired);
        }
        final fresh = await repository.fetchAccess();
        if (!_current(epoch)) return;
        if (fresh.userId != current.userId ||
            session?.userId != current.userId) {
          throw const AuthFailure(AuthFailureKind.unverified);
        }
        access = fresh;
        phase = switch (fresh.status) {
          AccessStatus.active =>
            fresh.active
                ? (fresh.role == UserRole.admin
                      ? AuthPhase.admin
                      : AuthPhase.active)
                : AuthPhase.inconsistent,
          AccessStatus.noRole =>
            old?.active == true && previousUser == current.userId
                ? AuthPhase.revoked
                : AuthPhase.noRole,
          AccessStatus.blocked => AuthPhase.blocked,
          AccessStatus.unknownRole => AuthPhase.unknownRole,
          AccessStatus.noProfile => AuthPhase.noProfile,
          AccessStatus.inconsistent => AuthPhase.inconsistent,
          AccessStatus.invalidSession => throw const AuthFailure(
            AuthFailureKind.sessionExpired,
          ),
        };
      })().timeout(timeout);
      if (_current(epoch) && session != null) {
        final untilExpiry = session!.expiresAt.difference(DateTime.now());
        final next = untilExpiry < pollInterval ? untilExpiry : pollInterval;
        _poll = Timer(next.isNegative ? Duration.zero : next, () {
          if (foreground && !_disposed) revalidate();
        });
      }
    } catch (error) {
      if (!_current(epoch)) return;
      // Future.timeout не отменяет сеть сам: отменяем сокеты и все поздние результаты.
      repository.cancelPending();
      ++_epoch;
      _invalidate();
      failure = error is AuthFailure
          ? error
          : AuthFailure(
              error is TimeoutException
                  ? AuthFailureKind.timeout
                  : AuthFailureKind.unverified,
            );
      phase = AuthPhase.failure;
      // Сетевая ошибка не вызывает signOut и не удаляет secure storage.
    } finally {
      if (!_disposed &&
          foreground &&
          (_epoch == epoch || phase == AuthPhase.failure)) {
        _emit();
      }
    }
  }

  Future<T?> guardAction<T>(
    Future<T> Function(RoleWorkLease lease) action,
  ) async {
    if (!canUseRole) throw const AuthFailure(AuthFailureKind.unverified);
    final lease = RoleWorkLease();
    final epoch = _epoch;
    _work.add(lease);
    try {
      final result = await action(lease);
      return !lease.cancelled && _current(epoch) && canUseRole ? result : null;
    } finally {
      _work.remove(lease);
    }
  }

  Future<void> signOut() async {
    if (_disposed) return;
    final epoch = ++_epoch;
    _invalidate();
    repository.cancelPending();
    session = null;
    failure = null;
    phase = AuthPhase.checking;
    _emit();
    try {
      await repository.signOut().timeout(timeout);
      if (!_disposed && _epoch == epoch) phase = AuthPhase.signedOut;
    } catch (error) {
      if (!_disposed && _epoch == epoch) {
        failure = error is AuthFailure
            ? error
            : const AuthFailure(AuthFailureKind.storage);
        phase = AuthPhase.failure;
      }
    } finally {
      if (!_disposed && _epoch == epoch) _emit();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed) return;
    if (state == AppLifecycleState.resumed) {
      foreground = true;
      // Старый интерфейс уже закрыт на уходе, пока выполняется новая проверка.
      _check(restore: session == null);
    } else {
      foreground = false;
      ++_epoch;
      _invalidate();
      repository.cancelPending();
      phase = AuthPhase.checking;
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    ++_epoch;
    _invalidate();
    WidgetsBinding.instance.removeObserver(this);
    repository.cancelPending();
    unawaited(repository.dispose());
    super.dispose();
  }
}
