import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../maps/address_models.dart';
import '../services/session_store.dart';
import 'order_models.dart';

abstract interface class DispatchApi {
  Future<Object?> dispatch(String action, Map<String, Object?> payload);
  SessionStore orderIntentStore(String userId);
}

class Trip {
  Trip(Map<String, dynamic> data)
    : id = data['id'] as String,
      requestId = data['request_id'] as String,
      passengerId = data['passenger_id'] as String,
      driverId = data['driver_id'] as String?,
      pickup = _point(data['pickup']),
      destination = _point(data['destination']),
      status = data['status'] as String,
      cancellationReason = data['cancellation_reason'] as String?,
      expiresAt = DateTime.parse(data['expires_at'] as String),
      version = data['version'] as int {
    if (!labels.containsKey(status) || version < 1) {
      throw const FormatException();
    }
  }
  final String id, requestId, passengerId, status;
  final String? driverId, cancellationReason;
  final OrderPoint pickup, destination;
  final DateTime expiresAt;
  final int version;
  bool get active => status != 'completed' && status != 'cancelled';
  String get label => cancellationReason == 'search_timeout'
      ? 'Свободная машина не найдена за 5 минут'
      : labels[status]!;
  static const labels = {
    'created': 'Ищем свободного водителя',
    'accepted': 'Заказ принят водителем',
    'to_pickup': 'Водитель едет к клиенту',
    'arrived': 'Водитель на месте',
    'riding': 'В пути',
    'completed': 'Поездка завершена',
    'cancelled': 'Заказ отменён',
  };
  static OrderPoint _point(dynamic data) => OrderPoint(
    address: data['address'] as String,
    point: GeoPoint(
      (data['latitude'] as num).toDouble(),
      (data['longitude'] as num).toDouble(),
    ),
  );
}

class DispatchState {
  DispatchState(Object? value, String userId, bool driver) {
    final data = value as Map<String, dynamic>;
    if (data['contract_version'] != 2 ||
        data['user_id'] != userId ||
        data['role'] != (driver ? 'driver' : 'passenger')) {
      throw const FormatException();
    }
    serverTime = DateTime.parse(data['server_time'] as String);
    online = data['online'] as bool;
    outcome = data['outcome'] as String;
    acknowledgedRequestId = data['acknowledged_request_id'] as String?;
    trip = data['order'] == null
        ? null
        : Trip(data['order'] as Map<String, dynamic>);
    final offer = data['offer'] as Map<String, dynamic>?;
    offerId = offer?['id'] as String?;
    offerExpiresAt = offer == null
        ? null
        : DateTime.parse(offer['expires_at'] as String);
    if (trip case final trip?) {
      if ((!driver && trip.passengerId != userId) ||
          (driver &&
              trip.driverId != userId &&
              !(offerId != null &&
                  offer!['order_id'] == trip.id &&
                  trip.status == 'created'))) {
        throw const FormatException();
      }
    }
    if (offer != null &&
        (!driver || trip == null || offer['order_id'] != trip!.id)) {
      throw const FormatException();
    }
  }
  late final DateTime serverTime;
  late final bool online;
  late final String outcome;
  late final String? acknowledgedRequestId;
  late final Trip? trip;
  late final String? offerId;
  late final DateTime? offerExpiresAt;
}

/// A single in-flight command, server snapshots, and a durable request ID.
/// Polling never overlaps mutations. Lifecycle generations discard late replies.
class DispatchController extends ChangeNotifier {
  DispatchController({
    required this.api,
    required this.userId,
    required this.driver,
  }) : _store = api.orderIntentStore(userId);
  final DispatchApi api;
  final String userId;
  final bool driver;
  final SessionStore _store;
  final Stopwatch _age = Stopwatch();
  Timer? _timer;
  int _generation = 0, _ticks = 0;
  bool _enabled = false, _disposed = false, _loaded = false;
  bool busy = false;
  Completer<void>? _flight;
  final ValueNotifier<int> clock = ValueNotifier(0);
  Future<void> _waitForPoll() async {
    if (!busy) await _flight?.future;
  }

  String? message;
  DispatchState? state;
  Map<String, Object?>? pending;
  bool get enabled => _enabled;
  bool get canAct => _enabled && !busy && state != null && message == null;
  bool get hasActiveTrip => state?.trip?.active ?? false;
  int secondsUntil(DateTime deadline) => max(
    0,
    (deadline.difference(state!.serverTime).inMilliseconds -
            _age.elapsedMilliseconds +
            999) ~/
        1000,
  );

  void setEnabled(bool value) {
    if (_disposed || value == _enabled) return;
    _enabled = value;
    ++_generation;
    _timer?.cancel();
    if (value) {
      unawaited(refresh());
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        ++_ticks;
        if (_ticks % (message == null ? 3 : 15) == 0) unawaited(refresh());
        clock.value++;
      });
    }
  }

  Future<void> _load() async {
    if (_loaded || driver) return;
    final saved = await _store.read();
    if (saved != null) {
      pending = Map<String, Object?>.from(jsonDecode(saved) as Map);
    }
    _loaded = true;
  }

  Future<void> refresh() => _run(driver ? 'driver_poll' : 'passenger_poll', {});

  Future<void> create(AddressPlace pickup, AddressPlace destination) async {
    await _waitForPoll();
    if (!canAct || hasActiveTrip || pending != null) return;
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    bytes[6] = (bytes[6] & 15) | 64;
    bytes[8] = (bytes[8] & 63) | 128;
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    final id =
        '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
    try {
      final command = CreateOrderCommand(
        requestId: id,
        pickup: OrderPoint(address: pickup.label, point: pickup.point),
        destination: OrderPoint(
          address: destination.label,
          point: destination.point,
        ),
      );
      await _run('create', {
        'request_id': id,
        'pickup': command.pickup.toJson(),
        'destination': command.destination.toJson(),
      }, saveIntent: true);
    } on OrderFailure catch (error) {
      message = error.message;
      notifyListeners();
    }
  }

  Future<void> retryCreate() async {
    if (pending case final intent?) {
      await _run('create', intent, saveIntent: true);
    }
  }

  Future<void> cancel() async {
    await _waitForPoll();
    if (!canAct || state?.trip?.status != 'created') return;
    await _run('cancel', {'order_id': state!.trip!.id});
  }

  Future<void> setOnline(bool value) async {
    await _waitForPoll();
    if (!canAct) return;
    await _run('online', {'online': value});
    if (message != null) throw const OrderFailure(OrderFailureKind.unavailable);
  }

  Future<void> respond(bool accept) async {
    await _waitForPoll();
    final current = state;
    if (!canAct ||
        current?.offerId == null ||
        secondsUntil(current!.offerExpiresAt!) == 0) {
      return;
    }
    await _run('respond', {
      'offer_id': current.offerId,
      'response': accept ? 'accept' : 'decline',
    });
  }

  Future<void> advance(String status) async {
    await _waitForPoll();
    if (!canAct || state?.trip == null) return;
    await _run('advance', {'order_id': state!.trip!.id, 'status': status});
  }

  Future<void> _run(
    String action,
    Map<String, Object?> payload, {
    bool saveIntent = false,
  }) async {
    if (!_enabled || _flight != null || _disposed) return;
    final generation = _generation;
    final silent =
        (action == 'driver_poll' || action == 'passenger_poll') &&
        state != null;
    final oldSignature = _signature;
    final oldMessage = message;
    _flight = Completer<void>();
    busy = !silent;
    if (!silent) notifyListeners();
    try {
      await _load();
      if (generation != _generation || !_enabled) return;
      if (saveIntent) {
        // Persist before the first request; a killed process retries exactly this intent.
        pending = Map.of(payload);
        await _store.write(jsonEncode(pending));
      }
      if (generation != _generation || !_enabled) return;
      final result = await api.dispatch(action, payload);
      if (generation != _generation || !_enabled) return;
      final fresh = DispatchState(result, userId, driver);
      if (pending != null &&
          (fresh.trip?.requestId == pending!['request_id'] ||
              fresh.acknowledgedRequestId == pending!['request_id'])) {
        await _store.clear();
        pending = null;
      }
      if (generation != _generation || !_enabled) return;
      state = fresh;
      _age
        ..reset()
        ..start();
      message = null;
    } catch (error) {
      if (generation == _generation && _enabled) {
        if (action == 'create' &&
            error is OrderFailure &&
            {
              OrderFailureKind.invalidRequest,
              OrderFailureKind.activeOrderExists,
              OrderFailureKind.creationForbidden,
            }.contains(error.kind)) {
          try {
            await _store.clear();
            pending = null;
          } catch (_) {}
        }
        if (generation != _generation || !_enabled) return;
        message = error is OrderFailure
            ? error.message
            : 'Нет подтверждения сервера. Проверяем связь…';
      }
    } finally {
      busy = false;
      final flight = _flight;
      _flight = null;
      flight?.complete();
      if (!_disposed) {
        clock.value++;
        if (!silent || oldSignature != _signature || oldMessage != message) {
          notifyListeners();
        }
      }
    }
  }

  String get _signature => jsonEncode([
    state?.online,
    state?.offerId,
    state?.offerExpiresAt?.toIso8601String(),
    state?.trip?.id,
    state?.trip?.version,
    state?.trip?.status,
    pending?['request_id'],
  ]);

  @override
  void dispose() {
    _disposed = true;
    _enabled = false;
    ++_generation;
    _timer?.cancel();
    _age.stop();
    clock.dispose();
    super.dispose();
  }
}
