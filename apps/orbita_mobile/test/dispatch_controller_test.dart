import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';
import 'package:orbita_mobile/src/screens/driver_screen.dart';
import 'package:orbita_mobile/src/ui/orbita_map.dart';
import 'package:orbita_mobile/src/ui/driver_map.dart';
import 'package:orbita_mobile/src/ui/theme.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';
import 'package:orbita_mobile/src/orders/order_models.dart';
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
  test(
    'foreground waits for the old request and refreshes immediately',
    () async {
      final api = FakeApi();
      final c = DispatchController(api: api, userId: passenger, driver: false);
      addTearDown(c.dispose);
      c.setEnabled(true);
      await settle();
      expect(c.canAct, isTrue);

      final oldReply = Completer<Object?>();
      final resumedReply = Completer<Object?>();
      api.handler = (_, _) => oldReply.future;
      final oldPoll = c.refresh();
      await settle();
      c.setEnabled(false);
      c.setEnabled(true);
      expect(c.canAct, isFalse);
      expect(api.calls, hasLength(2));

      api.handler = (_, _) => resumedReply.future;
      oldReply.complete(envelope());
      await oldPoll;
      await settle();
      expect(
        api.calls.map((call) => call.action),
        List.filled(3, 'passenger_poll'),
      );
      expect(c.canAct, isFalse);
      resumedReply.complete(envelope());
      await settle();
      expect(c.canAct, isTrue);
    },
  );
  test(
    'accept tap cannot apply to a replacement offer returned by polling',
    () async {
      const originalOffer = '00000000-0000-4000-8000-000000000005';
      const replacementOffer = '00000000-0000-4000-8000-000000000006';
      final order = trip({
        'request_id': '00000000-0000-4000-8000-000000000004',
        'pickup': {'address': pickup.label, 'latitude': 55, 'longitude': 82.43},
        'destination': {
          'address': destination.label,
          'latitude': 55.01,
          'longitude': 82.44,
        },
      });
      Map<String, dynamic> offer(String id) => {
        ...envelope(isDriver: true, order: order),
        'offer': {
          'id': id,
          'order_id': order['id'],
          'expires_at': '2026-11-20T16:00:25Z',
        },
      };

      final api = FakeApi()..handler = (_, _) async => offer(originalOffer);
      final c = DispatchController(api: api, userId: driver, driver: true);
      addTearDown(c.dispose);
      c.setEnabled(true);
      await settle();
      final reply = Completer<Object?>();
      api.handler = (_, _) => reply.future;
      final polling = c.refresh();
      final accept = c.respond(true, offerId: originalOffer);
      reply.complete(offer(replacementOffer));
      await Future.wait([polling, accept]);

      expect(c.state!.offerId, replacementOffer);
      expect(api.calls.where((call) => call.action == 'respond'), isEmpty);
      await c.respond(true, offerId: replacementOffer);
      expect(api.calls.last.payload['offer_id'], replacementOffer);
    },
  );
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
    'shift only succeeds when the server confirms the requested state',
    () async {
      var confirm = false;
      final api = FakeApi()
        ..handler = (action, payload) async => {
          ...envelope(isDriver: true),
          'online': action == 'online' && confirm && payload['online'] == true,
        };
      final c = DispatchController(api: api, userId: driver, driver: true);
      addTearDown(c.dispose);
      c.setEnabled(true);
      await settle();
      await expectLater(c.setOnline(true), throwsA(isA<OrderFailure>()));
      expect(c.state!.online, isFalse);
      confirm = true;
      await c.setOnline(true);
      expect(c.state!.online, isTrue);
    },
  );
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
      await c.advance('to_pickup', orderId: c.state!.trip!.id);
      await c.advance('to_pickup', orderId: c.state!.trip!.id);
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
  testWidgets(
    'restored passenger trip restores address fields and map points',
    (tester) async {
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
            envelope(order: trip(intent, status: 'accepted')));
      final c = DispatchController(api: api, userId: passenger, driver: false);
      final maps = MapSettings();
      c.setEnabled(true);
      await tester.pump();
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(brightness: Brightness.light),
          home: Scaffold(
            body: PassengerScreen(mapSettings: maps, dispatch: c),
          ),
        ),
      );
      await tester.pump();
      expect(find.byKey(const Key('pickup')), findsNothing);
      expect(find.text('Откуда: ${pickup.label}'), findsOneWidget);
      final map = tester.widget<OrbitaMap>(
        find.byKey(const Key('passenger-map')),
      );
      expect(map.pickup!.label, pickup.label);
      expect(map.destination!.label, destination.label);
      expect(find.text('Заказ принят водителем'), findsOneWidget);
      expect(find.byKey(const Key('create-order')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      c.dispose();
      maps.dispose();
    },
  );

  testWidgets('real driver screen submits offer and trip actions to API', (
    tester,
  ) async {
    final intent = {
      'request_id': '00000000-0000-4000-8000-000000000004',
      'pickup': {'address': pickup.label, 'latitude': 55, 'longitude': 82.43},
      'destination': {
        'address': destination.label,
        'latitude': 55.01,
        'longitude': 82.44,
      },
    };
    var status = 'created';
    final api = FakeApi()
      ..handler = ((action, payload) async {
        if (action == 'respond') {
          expect(payload['response'], 'accept');
          status = 'accepted';
        }
        if (action == 'advance') {
          status = payload['status'] as String;
        }
        return {
          ...envelope(isDriver: true, order: trip(intent, status: status)),
          'offer': status == 'created'
              ? {
                  'id': '00000000-0000-4000-8000-000000000005',
                  'order_id': '00000000-0000-4000-8000-000000000003',
                  'expires_at': '2026-11-20T16:00:18Z',
                }
              : null,
        };
      });
    final c = DispatchController(api: api, userId: driver, driver: true);
    final maps = MapSettings();
    c.setEnabled(true);
    await tester.pump();
    await tester.pumpWidget(
      MaterialApp(
        theme: orbitaTheme(brightness: Brightness.light),
        home: Scaffold(
          body: DriverScreen(mapSettings: maps, dispatch: c),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('18 с'), findsOneWidget);
    expect(tester.widget<DriverMap>(find.byType(DriverMap)).tripId, isNotNull);
    await tester.ensureVisible(find.byKey(const Key('accept-offer')));
    await tester.tap(find.byKey(const Key('accept-offer')));
    await tester.pump();
    expect(c.state!.trip!.status, 'accepted');
    for (final label in [
      'Ехать к пассажиру',
      'Я на месте',
      'Начать поездку',
      'Завершить поездку',
    ]) {
      await tester.ensureVisible(find.text(label));
      await tester.tap(find.text(label));
      await tester.pump();
    }
    expect(c.state!.trip!.status, 'completed');
    expect(find.text('Поездка завершена'), findsOneWidget);
    expect(find.text('Ожидаем заказ'), findsOneWidget);
    expect(find.text(pickup.label), findsNothing);
    expect(tester.widget<DriverMap>(find.byType(DriverMap)).tripId, isNull);
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('Поездка завершена'), findsNothing);
    await tester.pumpWidget(const SizedBox());
    c.dispose();
    maps.dispose();
  });
}
