import 'dart:async';

import 'package:flutter/widgets.dart';

import '../platform/device_gateway.dart';

/// Один источник состояния для карточек и отдельного экрана разрешений.
class DeviceCheckController extends ChangeNotifier with WidgetsBindingObserver {
  DeviceCheckController(this.device) {
    WidgetsBinding.instance.addObserver(this);
    refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        refresh();
      }
    });
  }
  final DeviceGateway device;
  DeviceState state = const DeviceState();
  bool loading = true, busy = false, available = false;
  String? readError, actionError;
  Timer? _timer;
  Future<void>? _readJob;
  bool _readAgain = false, _disposed = false;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refresh();
  }

  Future<void> refresh() {
    if (_disposed) return Future.value();
    if (_readJob != null) {
      _readAgain = true;
      return _readJob!;
    }
    final job = _read();
    _readJob = job;
    return job.whenComplete(() => _readJob = null);
  }

  Future<void> _read() async {
    do {
      _readAgain = false;
      try {
        final snapshot = await device.read();
        if (_disposed) return;
        state = snapshot;
        available = true;
        readError = null;
      } catch (_) {
        if (_disposed) return;
        available = false;
        readError = 'Не удалось обновить состояние устройства.';
      }
      loading = false;
      notifyListeners();
    } while (_readAgain && !_disposed);
  }

  Future<bool> run(
    Future<void> Function() action, {
    required String failure,
  }) async {
    if (busy || _disposed) return false;
    busy = true;
    actionError = null;
    notifyListeners();
    try {
      await action();
      await refresh();
      return !_disposed && available;
    } catch (_) {
      if (!_disposed) actionError = failure;
      return false;
    } finally {
      if (!_disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  void dismissError() {
    actionError = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
