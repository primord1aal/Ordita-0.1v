import 'package:flutter/foundation.dart';

class DriverOfferOpen {
  const DriverOfferOpen._(this.offerId, this.expiresAt);

  final String offerId;
  final DateTime expiresAt;

  static final _offerId = RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  );
  static final _utcExpiry = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?(?:Z|\+00:00)$',
  );

  static DriverOfferOpen? parse(Object? payload) {
    if (payload is! Map ||
        payload.length != 3 ||
        payload['kind'] != 'driver_offer') {
      return null;
    }
    final id = payload['offer_id'];
    final expiry = payload['expires_at'];
    if (id is! String ||
        _offerId.stringMatch(id) != id ||
        expiry is! String ||
        _utcExpiry.stringMatch(expiry) != expiry) {
      return null;
    }
    final time = DateTime.tryParse(expiry);
    if (time == null ||
        time.toIso8601String().substring(0, 19) != expiry.substring(0, 19)) {
      return null;
    }
    return DriverOfferOpen._(id, time);
  }
}

/// Сохраняет последнее открытие, пока приложение восстанавливает сессию.
class DriverOfferOpens extends ChangeNotifier {
  final _recent = <String, DateTime>{};
  DriverOfferOpen? _pending;

  bool get hasPending => _pending != null;

  void add(Object? payload) {
    final open = DriverOfferOpen.parse(payload);
    final now = DateTime.now();
    if (open == null || !open.expiresAt.isAfter(now)) return;
    _recent.removeWhere((_, expiry) => !expiry.isAfter(now));
    if (_recent.containsKey(open.offerId)) return;
    if (_recent.length == 64) _recent.remove(_recent.keys.first);
    _recent[open.offerId] = open.expiresAt;
    _pending = open;
    notifyListeners();
  }

  DriverOfferOpen? take() {
    final pending = _pending;
    _pending = null;
    if (pending == null || !pending.expiresAt.isAfter(DateTime.now())) {
      return null;
    }
    return pending;
  }
}
