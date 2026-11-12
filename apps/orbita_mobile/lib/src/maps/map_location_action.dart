import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../platform/device_gateway.dart';
import 'address_models.dart';

/// One explicit map action. No background service or automatic tracking.
class MapLocationAction extends ChangeNotifier with WidgetsBindingObserver {
  MapLocationAction({
    required this.device,
    required this.isAllowed,
    required this.onLocation,
    required this.onError,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  final DeviceGateway device;
  final bool Function() isAllowed;
  final FutureOr<void> Function(GeoPoint) onLocation;
  final ValueChanged<String> onError;
  bool busy = false, _disposed = false;
  int _revision = 0;

  bool _current(int revision) =>
      !_disposed && revision == _revision && isAllowed();

  Future<void> locate() async {
    if (_disposed || busy || !isAllowed()) return;
    final revision = ++_revision;
    busy = true;
    _notify();
    try {
      var state = await device.read();
      if (!_current(revision)) return;
      if (!state.hasForegroundLocation) {
        await device.requestForegroundLocation();
        if (!_current(revision)) return;
        state = await device.read();
        if (!_current(revision)) return;
      }
      if (!state.hasForegroundLocation) {
        throw PlatformException(code: 'permission');
      }
      if (!state.locationEnabled) {
        throw PlatformException(code: 'location_disabled');
      }
      final fix = await device.currentLocation();
      if (!_current(revision)) return;
      final point = GeoPoint(fix.latitude, fix.longitude);
      final age = DateTime.now().toUtc().difference(fix.capturedAt);
      if (!point.valid ||
          age > const Duration(minutes: 1) ||
          age < const Duration(seconds: -5)) {
        throw PlatformException(code: 'invalid_location');
      }
      await onLocation(point);
    } on PlatformException catch (error) {
      if (_current(revision)) {
        onError(switch (error.code) {
          'permission' =>
            'Разрешите доступ к местоположению в настройках приложения.',
          'location_disabled' => 'Включите геолокацию на устройстве.',
          'timeout' =>
            'Не удалось определить местоположение. Попробуйте ещё раз.',
          'busy' => 'Местоположение уже определяется.',
          _ => 'Местоположение недоступно. Выберите точку на карте.',
        });
      }
    } catch (_) {
      if (_current(revision)) {
        onError('Местоположение недоступно. Выберите точку на карте.');
      }
    } finally {
      if (!_disposed && revision == _revision) {
        busy = false;
        _notify();
      }
    }
  }

  void cancel({bool notify = true}) {
    ++_revision;
    final wasBusy = busy;
    busy = false;
    if (wasBusy) {
      unawaited(device.cancelCurrentLocation().catchError((Object _) {}));
    }
    if (notify && wasBusy) _notify();
  }

  void _notify() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      cancel();
    }
  }

  @override
  void dispose() {
    cancel(notify: false);
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
