import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../maps/address_models.dart';
import '../platform/device_gateway.dart';
import 'dispatch_controller.dart';
import 'order_models.dart';

abstract interface class TripLocationApi {
  Future<Object?> exchangeTripLocation(
    String orderId, {
    DeviceLocationFix? fix,
  });
}

class TripLocation extends ChangeNotifier {
  TripLocation(this.dispatch, {this.device}) {
    dispatch.addListener(_sync);
  }

  final DispatchController dispatch;
  final DeviceGateway? device;
  Timer? _timer;
  String? _order;
  bool _enabled = false, _busy = false, _disposed = false;
  int _generation = 0;
  GeoPoint? _point;
  DateTime? _seenAt;
  bool _stale = false;

  GeoPoint? get point => _point;
  bool get stale => _stale;

  void setEnabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _sync();
  }

  void _clear() {
    final hadPoint = _point != null;
    _point = null;
    _seenAt = null;
    _stale = false;
    if (hadPoint) _notify();
  }

  void _sync() {
    final trip = dispatch.state?.trip;
    final order =
        _enabled &&
            dispatch.hasCurrentSnapshot &&
            trip?.active == true &&
            trip?.driverId != null
        ? trip!.id
        : null;
    if (order == _order) return;
    _order = order;
    final revision = ++_generation;
    _timer?.cancel();
    _clear();
    if (order == null) return;
    final period = Duration(seconds: dispatch.driver ? 10 : 5);
    _timer = Timer.periodic(period, (_) => unawaited(_sample(order, revision)));
    scheduleMicrotask(() => unawaited(_sample(order, revision)));
  }

  bool _current(int revision) =>
      !_disposed && _enabled && revision == _generation;

  Future<void> _sample(String order, int revision) async {
    if (!_current(revision)) return;
    _age();
    if (_busy) return;
    final backend = dispatch.api;
    if (backend is! TripLocationApi) return;
    final api = backend as TripLocationApi;
    _busy = true;
    try {
      if (dispatch.driver) {
        final gps = device;
        if (gps == null) return;
        final state = await gps.read();
        if (!_current(revision) ||
            !state.hasForegroundLocation ||
            !state.locationEnabled) {
          return;
        }
        final fix = await gps.currentLocation();
        if (!_current(revision)) return;
        final point = GeoPoint(fix.latitude, fix.longitude);
        final now = DateTime.now().toUtc();
        final age = now.difference(fix.capturedAt).inSeconds;
        if (!point.valid ||
            !fix.accuracyMeters.isFinite ||
            fix.accuracyMeters < 0 ||
            fix.accuracyMeters > 100 ||
            age < -5 ||
            age > 30) {
          return;
        }
        _apply(point, age);
        await api.exchangeTripLocation(order, fix: fix);
      } else {
        final result = await api.exchangeTripLocation(order);
        if (!_current(revision)) return;
        final response = result as Map<String, dynamic>;
        if (response['order_id'] != order) {
          _clear();
          return;
        }
        final raw = response['fix'] as Map<String, dynamic>?;
        if (raw == null) {
          _clear();
          return;
        }
        final point = GeoPoint(
          (raw['latitude'] as num).toDouble(),
          (raw['longitude'] as num).toDouble(),
        );
        final age = raw['age_seconds'] as int;
        if (!point.valid || age < 0 || age > 120) {
          _clear();
          return;
        }
        _apply(point, age);
      }
    } on OrderFailure catch (error) {
      if (_current(revision) &&
          !dispatch.driver &&
          error.kind != OrderFailureKind.unavailable) {
        _clear();
      }
    } catch (_) {
      if (_current(revision)) _age();
    } finally {
      _busy = false;
    }
  }

  void _apply(GeoPoint point, int age) {
    final changed =
        _point?.latitude != point.latitude ||
        _point?.longitude != point.longitude ||
        _stale != (age > 25);
    _point = point;
    _seenAt = DateTime.now().subtract(Duration(seconds: age));
    _stale = age > 25;
    if (changed) _notify();
  }

  void _age() {
    final seenAt = _seenAt;
    if (seenAt == null) return;
    final age = DateTime.now().difference(seenAt).inSeconds;
    if (age > 120) {
      _clear();
    } else if (age > 25 && !_stale) {
      _stale = true;
      _notify();
    }
  }

  void _notify() {
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    dispatch.removeListener(_sync);
    _timer?.cancel();
    super.dispose();
  }
}
