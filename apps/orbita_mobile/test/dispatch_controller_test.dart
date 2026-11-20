import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';
import 'package:orbita_mobile/src/services/session_store.dart';

const passenger = '00000000-0000-4000-8000-000000000001';
const driver = '00000000-0000-4000-8000-000000000002';
const pickup = AddressPlace('Чик, Учебная, 1', GeoPoint(55, 82.43));
const destination = AddressPlace('Чик, Речная, 2', GeoPoint(55.01, 82.44));
Map<String, dynamic> trip(
  Map<String, Object?> intent, {
  String status = 'created',
}) => {
  'id': '00000000-0000-4000-8000-000000000003',
  'request_id': intent['request_id'],
  'passenger_id': passenger,
  'driver_id': status == 'created' ? null : driver,
  'pickup': intent['pickup'],
  'destination': intent['destination'],
  'status': status,
  'expires_at': '2026-11-20T16:05:00Z',
  'cancellation_reason': null,
  'version': status == 'created' ? 1 : 2,
};
Map<String, dynamic> envelope({
  Map<String, dynamic>? order,
  bool isDriver = false,
}) => {
  'contract_version': 2,
  'user_id': isDriver ? driver : passenger,
  'role': isDriver ? 'driver' : 'passenger',
  'server_time': '2026-11-20T16:00:00Z',
  'online': isDriver,
  'outcome': 'ok',
  'order': order,
  'offer': null,
};

class MemoryStore implements SessionStore {
  String? value;
  bool failWrite = false;
  @override
  Future<String?> read() async => value;
  @override
  Future<void> write(String session) async {
    if (failWrite) throw StateError('storage');
    value = session;
  }

  @override
  Future<void> clear() async {
    value = null;
  }
}

class FakeApi implements DispatchApi {
  final store = MemoryStore();
  final calls = <({String action, Map<String, Object?> payload})>[];
  Future<Object?> Function(String, Map<String, Object?>)? handler;
  @override
  SessionStore orderIntentStore(String userId) => store;
  @override
  Future<Object?> dispatch(String action, Map<String, Object?> payload) async {
    calls.add((action: action, payload: Map.of(payload)));
    return handler == null ? envelope() : await handler!(action, payload);
  }
}

Future<void> settle() async {
  for (var i = 0; i < 8; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  test('double tap sends once and writes intent before network', () async {
    final api = FakeApi();
    final c = DispatchController(api: api, userId: passenger, driver: false);
    addTearDown(c.dispose);
    c.setEnabled(true);
    await settle();
    final reply = Completer<Object?>();
    api.handler = (action, payload) {
      expect(api.store.value, isNotNull);
      return reply.future;
    };
    final first = c.create(pickup, destination);
    final second = c.create(pickup, destination);
    await settle();
    expect(api.calls.where((x) => x.action == 'create'), hasLength(1));
    final intent = api.calls.last.payload;
    reply.complete(envelope(order: trip(intent)));
    await Future.wait([first, second]);
    expect(c.state!.trip!.active, isTrue);
    expect(api.store.value, isNull);
  });
  test(
    'uncertain network request survives process restart with same payload',
    () async {
      final api = FakeApi();
      var c = DispatchController(api: api, userId: passenger, driver: false);
      c.setEnabled(true);
      await settle();
      api.handler = (action, payload) async {
        throw TimeoutException('artificial');
      };
      await c.create(pickup, destination);
      final intent = api.calls.last.payload;
      expect(api.store.value, isNotNull);
      c.dispose();
      api.handler = (action, payload) async =>
          action == 'create' ? envelope(order: trip(payload)) : envelope();
      c = DispatchController(api: api, userId: passenger, driver: false);
      addTearDown(c.dispose);
      c.setEnabled(true);
      await settle();
      expect(c.pending, intent);
      await c.retryCreate();
      expect(api.calls.last.payload, intent);
      expect(c.pending, isNull);
    },
  );
  test('poll recovers accepted request after lost create response', () async {
    final api = FakeApi();
    final c = DispatchController(api: api, userId: passenger, driver: false);
    addTearDown(c.dispose);
    c.setEnabled(true);
    await settle();
    Map<String, dynamic>? saved;
    api.handler = (action, payload) async {
      saved = trip(payload, status: 'accepted');
      throw TimeoutException('artificial');
    };
    await c.create(pickup, destination);
    api.handler = (action, payload) async => envelope(order: saved);
    await c.refresh();
    expect(c.state!.trip!.status, 'accepted');
    expect(c.pending, isNull);
  });
  test('storage failure prevents sending an unrepeatable create', () async {
    final api = FakeApi();
    final c = DispatchController(api: api, userId: passenger, driver: false);
    addTearDown(c.dispose);
    c.setEnabled(true);
    await settle();
    api.store.failWrite = true;
    await c.create(pickup, destination);
    expect(api.calls.where((x) => x.action == 'create'), isEmpty);
    expect(c.message, isNotNull);
  });
  test('background discards late snapshot and blocks actions', () async {
    final api = FakeApi();
    final reply = Completer<Object?>();
    api.handler = (action, payload) => reply.future;
    final c = DispatchController(api: api, userId: passenger, driver: false);
    addTearDown(c.dispose);
    c.setEnabled(true);
    await settle();
    c.setEnabled(false);
    reply.complete(envelope());
    await settle();
    expect(c.state, isNull);
    await c.create(pickup, destination);
    expect(api.calls, hasLength(1));
    api.handler = (action, payload) async => envelope();
    c.setEnabled(true);
    await settle();
    expect(c.canAct, isTrue);
  });
  test('foreign snapshot fails closed', () async {
    final api = FakeApi()
      ..handler = ((action, payload) async => envelope(isDriver: true));
    final c = DispatchController(api: api, userId: passenger, driver: false);
    addTearDown(c.dispose);
    c.setEnabled(true);
    await settle();
    expect(c.state, isNull);
    expect(c.canAct, isFalse);
  });
  test(
    'driver restart restores active trip and repeat uses same target status',
    () async {
      final intent = {
        'request_id': '00000000-0000-4000-8000-000000000004',
        'pickup': {'address': pickup.label, 'latitude': 55, 'longitude': 82.43},
        'destination': {
          'address': destination.label,
          'latitude': 55.01,
          'longitude': 82.44,
        },
      };
      final api = FakeApi()
        ..handler = ((action, payload) async =>
            envelope(isDriver: true, order: trip(intent, status: 'accepted')));
      final c = DispatchController(api: api, userId: driver, driver: true);
      addTearDown(c.dispose);
      c.setEnabled(true);
      await settle();
      expect(c.state!.trip!.status, 'accepted');
      await c.advance('to_pickup');
      await c.advance('to_pickup');
      expect(api.calls.last.payload, {
        'order_id': c.state!.trip!.id,
        'status': 'to_pickup',
      });
    },
  );
  test(
    'acknowledged old request clears intent without hiding newer trip',
    () async {
      final api = FakeApi();
      final intent = {
        'request_id': '00000000-0000-4000-8000-000000000004',
        'pickup': {'address': pickup.label, 'latitude': 55, 'longitude': 82.43},
        'destination': {
          'address': destination.label,
          'latitude': 55.01,
          'longitude': 82.44,
        },
      };
      api.store.value = jsonEncode(intent);
      api.handler = (action, payload) async => {
        ...envelope(),
        'acknowledged_request_id': action == 'create'
            ? intent['request_id']
            : null,
      };
      final c = DispatchController(api: api, userId: passenger, driver: false);
      addTearDown(c.dispose);
      c.setEnabled(true);
      await settle();
      await c.retryCreate();
      expect(c.pending, isNull);
    },
  );
}
