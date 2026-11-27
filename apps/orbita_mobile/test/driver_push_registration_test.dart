import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/orders/driver_push_registration.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';

import 'fake_device.dart';

class _DriverPushApi implements DriverPushApi {
  final bound = <String?>[];
  bool heartbeatStarts = true;
  int starts = 0;

  @override
  Future<bool> bindDriverPushDevice(String? token) async {
    bound.add(token);
    return true;
  }

  @override
  Future<bool> startDriverHeartbeat() async {
    starts++;
    return heartbeatStarts;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('test.orbita.driver_push');
  const token = 'synthetic-rustore-installation';
  final session = AuthSession(
    userId: 'synthetic-driver',
    expiresAt: DateTime.now().add(const Duration(minutes: 10)),
  );

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  void bridge(Future<Object?> Function(MethodCall) handler) {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, handler);
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
  }

  test(
    'only a confirmed shift enables native delivery and starts heartbeat',
    () async {
      final gates = <bool>[];
      bridge((call) async {
        if (call.method == 'getToken') return token;
        gates.add(call.arguments as bool);
        return null;
      });
      final api = _DriverPushApi()..heartbeatStarts = false;
      final device = FakeDevice()..state = const DeviceState(sdk: 34);
      final registration = DriverPushRegistration(
        api,
        device,
        channel: channel,
      );
      addTearDown(registration.dispose);

      registration.authorize(session);
      await settle();
      expect(api.bound, [token]);
      expect(gates, [false]);
      expect(api.starts, 0);
      expect(device.calls, isEmpty);

      registration.setConfirmedOnline(true);
      await settle();
      expect(gates.last, isTrue);
      expect(api.starts, 1);
      expect(device.calls, ['read', 'notifications']);
      api.heartbeatStarts = true;
      registration.setConfirmedOnline(true);
      await settle();
      registration.setConfirmedOnline(true);
      await settle();
      expect(api.starts, 2);
      expect(device.calls, ['read', 'notifications']);
      expect(api.bound, [token]);

      registration.setConfirmedOnline(false);
      await settle();
      expect(gates.last, isFalse);
    },
  );

  test(
    'sign-out ignores a late token and leaves the notification gate closed',
    () async {
      final reply = Completer<String>();
      final gates = <bool>[];
      bridge((call) async {
        if (call.method == 'getToken') return reply.future;
        gates.add(call.arguments as bool);
        return null;
      });
      final api = _DriverPushApi();
      final registration = DriverPushRegistration(
        api,
        FakeDevice(),
        channel: channel,
      );
      addTearDown(registration.dispose);

      registration.authorize(session);
      await settle();
      registration.setConfirmedOnline(true);
      registration.authorize(null);
      reply.complete(token);
      await settle();
      expect(api.bound, isEmpty);
      expect(api.starts, 0);
      expect(gates, everyElement(isFalse));
    },
  );

  test('a build without a provider keeps the line and notification permission separate', () async {
    bridge((_) async => null);
    final api = _DriverPushApi();
    final device = FakeDevice();
    final registration = DriverPushRegistration(api, device, channel: channel);
    addTearDown(registration.dispose);
    registration.authorize(session);
    registration.setConfirmedOnline(true);
    await settle();
    expect(api.bound, isEmpty);
    expect(api.starts, 0);
    expect(device.calls, isEmpty);
  });
}
