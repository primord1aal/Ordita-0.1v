import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';
import 'package:orbita_mobile/src/orders/driver_offer_open.dart';
import 'package:orbita_mobile/src/services/session_store.dart';
import 'package:orbita_mobile/src/ui/adaptive_navigation.dart';

import 'dispatch_controller_test.dart' as dispatch_fakes;
import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'test_helpers.dart';

const _offerId = '00000000-0000-4000-8000-000000000005';
const _otherOfferId = '00000000-0000-4000-8000-000000000006';
const _channel = MethodChannel('ru.orbita.taxi.foundation/driver_offer_open');

Map<String, Object?> _payload(DateTime expiresAt, {String id = _offerId}) => {
  'kind': 'driver_offer',
  'offer_id': id,
  'expires_at': expiresAt.toUtc().toIso8601String(),
};

class _DriverRepository extends FakeAuthRepository implements DispatchApi {
  _DriverRepository() {
    saved = testSession(dispatch_fakes.driver);
    access = testAccess(UserRole.driver, dispatch_fakes.driver);
  }

  final api = dispatch_fakes.FakeApi();

  @override
  Future<Object?> dispatch(String action, Map<String, Object?> payload) =>
      api.dispatch(action, payload);

  @override
  SessionStore orderIntentStore(String userId) => api.orderIntentStore(userId);
}

Map<String, dynamic> _offerSnapshot(DateTime expiresAt) {
  final order = dispatch_fakes.trip({
    'request_id': '00000000-0000-4000-8000-000000000004',
    'pickup': {
      'address': dispatch_fakes.pickup.label,
      'latitude': 55,
      'longitude': 82.43,
    },
    'destination': {
      'address': dispatch_fakes.destination.label,
      'latitude': 55.01,
      'longitude': 82.44,
    },
  });
  return {
    ...dispatch_fakes.envelope(isDriver: true, order: order),
    'server_time': expiresAt
        .subtract(const Duration(seconds: 20))
        .toIso8601String(),
    'offer': {
      'id': _offerId,
      'order_id': order['id'],
      'expires_at': expiresAt.toIso8601String(),
    },
  };
}

void main() {
  test('Открытие принимает только три поля и отбрасывает повтор по ID', () {
    final inbox = DriverOfferOpens();
    addTearDown(inbox.dispose);
    final now = DateTime.now().toUtc();
    final expires = now.add(const Duration(seconds: 20));
    final offer = _payload(expires);

    for (final malformed in [
      {...offer, 'address': 'Чик, Учебная'},
      {...offer, 'kind': 'other'},
      {...offer, 'offer_id': 'invalid'},
      {...offer, 'expires_at': '2026-02-30T12:15:20Z'},
      {...offer, 'expires_at': '2026-11-28T12:15:20+07:00'},
    ]) {
      expect(DriverOfferOpen.parse(malformed), isNull);
      inbox.add(malformed);
    }
    inbox.add(_payload(now.subtract(const Duration(seconds: 1))));
    expect(inbox.take(), isNull);

    inbox.add(offer);
    expect(inbox.take()?.expiresAt, expires);
    inbox.add(offer);
    expect(inbox.take(), isNull);
  });

  testWidgets(
    'Холодный запуск ждёт роль и сверяет предложение отдельным запросом',
    (tester) async {
      final expires = DateTime.now().toUtc().add(const Duration(seconds: 20));
      final access = Completer<ServerAccess>();
      final repo = _DriverRepository()..accessPending = access;
      repo.api.handler = (_, _) async => _offerSnapshot(expires);
      final transportExpiry = DateTime.fromMillisecondsSinceEpoch(
        expires.millisecondsSinceEpoch,
        isUtc: true,
      );
      final bridge = tester.binding.defaultBinaryMessenger;
      bridge.setMockMethodCallHandler(_channel, (call) async {
        expect(call.method, 'takeOfferOpen');
        return _payload(transportExpiry);
      });
      addTearDown(() => bridge.setMockMethodCallHandler(_channel, null));

      await tester.pumpWidget(
        OrbitaApp(device: FakeDevice(), authRepository: repo),
      );
      await tester.pump();
      expect(repo.api.calls, isEmpty);

      access.complete(repo.access);
      await tester.pumpAndSettle();
      expect(repo.api.calls.map((call) => call.action), [
        'driver_poll',
        'driver_poll',
      ]);
      expect(find.byKey(const Key('accept-offer')), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Открытие из профиля ведёт только к ожидаемому предложению', (
    tester,
  ) async {
    final expires = DateTime.now().toUtc().add(const Duration(seconds: 20));
    final repo = _DriverRepository();
    repo.api.handler = (_, _) async => _offerSnapshot(expires);
    final bridge = tester.binding.defaultBinaryMessenger;
    Object? pending;
    bridge.setMockMethodCallHandler(_channel, (_) async {
      final result = pending;
      pending = null;
      return result;
    });
    addTearDown(() => bridge.setMockMethodCallHandler(_channel, null));
    Future<void> open(
      Map<String, Object?> payload, {
      bool settle = true,
    }) async {
      pending = payload;
      await bridge.handlePlatformMessage(
        _channel.name,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('offerOpenAvailable'),
        ),
        null,
      );
      if (settle) {
        await tester.pumpAndSettle();
      } else {
        await tester.pump();
      }
    }

    await tester.pumpWidget(
      OrbitaApp(device: FakeDevice(), authRepository: repo),
    );
    await tester.pumpAndSettle();
    await openProfile(tester);
    expect(
      tester
          .widget<AdaptiveNavigation>(find.byType(AdaptiveNavigation))
          .selected,
      2,
    );

    await open(_payload(expires, id: _otherOfferId));
    expect(
      tester
          .widget<AdaptiveNavigation>(find.byType(AdaptiveNavigation))
          .selected,
      2,
    );
    expect(repo.api.calls, hasLength(2));

    await open(_payload(expires));
    expect(
      tester
          .widget<AdaptiveNavigation>(find.byType(AdaptiveNavigation))
          .selected,
      0,
    );
    expect(find.byKey(const Key('accept-offer')), findsOneWidget);
    expect(
      repo.api.calls.map((call) => call.action),
      List.filled(3, 'driver_poll'),
    );

    await openProfile(tester);
    final beforeDuplicate = repo.api.calls.length;
    await open(_payload(expires), settle: false);
    expect(
      tester
          .widget<AdaptiveNavigation>(find.byType(AdaptiveNavigation))
          .selected,
      2,
    );
    expect(repo.api.calls, hasLength(beforeDuplicate));
    await tester.pumpWidget(const SizedBox());
  });
}
