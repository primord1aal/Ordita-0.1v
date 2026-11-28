import 'dart:async';

import 'package:flutter/services.dart';

import '../auth/auth_repository.dart';
import '../platform/device_gateway.dart';

abstract interface class DriverPushApi {
  Future<bool> bindDriverPushDevice(String? token);
  Future<bool> startDriverHeartbeat();
}

/// Registers the device only for the driver's current verified session.
class DriverPushRegistration {
  DriverPushRegistration(this.api, this.device, {MethodChannel? channel})
    : _channel = channel ?? platformChannel {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'tokenChanged' && _authorization != null) {
        _registered = null;
        _schedule();
      }
    });
  }

  static const platformChannel = MethodChannel(
    'ru.orbita.taxi.foundation/driver_push',
  );
  final DriverPushApi api;
  final DeviceGateway device;
  final MethodChannel _channel;
  (String, DateTime)? _authorization, _registered;
  bool _known = false,
      _online = false,
      _askedPermission = false,
      _disposed = false;
  bool _heartbeatReady = false;
  int _revision = 0;
  Future<void> _work = Future.value();

  void authorize(AuthSession? session) {
    if (_disposed) return;
    final allowed = session == null || session.expired
        ? null
        : (session.userId, session.expiresAt);
    if (_known && allowed == _authorization && allowed == _registered) return;
    final changedUser = _authorization?.$1 != allowed?.$1;
    if (changedUser) {
      _online = false;
      _askedPermission = false;
    }
    _known = true;
    _authorization = allowed;
    if (allowed == null) _registered = null;
    if (allowed == null || changedUser) unawaited(_disable());
    _schedule();
  }

  void setConfirmedOnline(bool online) {
    if (_disposed ||
        _authorization == null ||
        (_online == online && (!online || _heartbeatReady))) {
      return;
    }
    _online = online;
    if (!online) unawaited(_disable());
    _schedule();
  }

  void _schedule() {
    final revision = ++_revision;
    _work = _work.then((_) => _synchronize(revision));
  }

  bool _current(int revision) =>
      !_disposed && revision == _revision && _authorization != null;

  Future<void> _synchronize(int revision) async {
    if (!_current(revision)) return;
    try {
      if (_registered != _authorization) {
        final token = await _channel.invokeMethod<String>('getToken');
        if (!_current(revision)) return;
        if (token == null || !await api.bindDriverPushDevice(token)) {
          if (_current(revision)) await _disable();
          return;
        }
        if (!_current(revision)) return;
        _registered = _authorization;
      }
      if (!_online) return;
      if (!_askedPermission) {
        _askedPermission = true;
        final state = await device.read();
        if (!_current(revision)) return;
        if (state.sdk >= 33 && !state.notifications) {
          await device.requestNotifications();
        }
      }
      if (!_current(revision)) return;
      await _channel.invokeMethod<void>('setEnabled', true);
      if (!_current(revision)) return;
      final running = await api.startDriverHeartbeat();
      if (_current(revision)) _heartbeatReady = running;
    } catch (_) {
      if (_current(revision)) await _disable();
    }
  }

  Future<void> _disable() async {
    _heartbeatReady = false;
    try {
      await _channel.invokeMethod<void>('setEnabled', false);
    } catch (_) {
      // An optional Android bridge must not interfere with auth or dispatch.
    }
  }

  void dispose() {
    _disposed = true;
    _channel.setMethodCallHandler(null);
    unawaited(_disable());
  }
}

/// Both polling in the open app and RuStore use Android's existing offer channel.
class DriverForegroundOffers {
  DriverForegroundOffers({MethodChannel? channel})
    : _channel = channel ?? DriverPushRegistration.platformChannel;

  final MethodChannel _channel;
  final _seen = <String, DateTime>{};
  String? _current;

  bool update(String? id, DateTime? deadline, {required int seconds}) {
    final incoming = deadline == null || seconds <= 0 ? null : id;
    final previous = _current;
    _current = incoming;
    if (previous != null && previous != incoming) {
      unawaited(_send('dismissOffer', previous));
    }
    if (incoming == null || deadline == null) return false;

    final now = DateTime.now();
    _seen.removeWhere(
      (_, expiry) => !expiry.isAfter(now) && expiry != deadline,
    );
    if (_seen.containsKey(incoming)) return false;
    if (_seen.length == 64) _seen.remove(_seen.keys.first);
    _seen[incoming] = deadline;
    unawaited(
      _send('showForegroundOffer', {
        'kind': 'driver_offer',
        'offer_id': incoming,
        'expires_at': deadline.toUtc().toIso8601String(),
      }),
    );
    return true;
  }

  Future<void> _send(String method, Object payload) async {
    try {
      await _channel.invokeMethod<void>(method, payload);
    } catch (_) {
      // Offer actions remain usable when Android notifications are unavailable.
    }
  }
}
