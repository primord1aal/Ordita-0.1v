import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/map_location_action.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';

import 'fake_device.dart';
import 'test_helpers.dart';

void main() {
  testWidgets(
    'GPS запрашивает только foreground-доступ и отдаёт свежую точку',
    (tester) async {
      final device = FakeDevice()
        ..state = readyState()
        ..locationHandler = () async => DeviceLocationFix(
          latitude: 55.002,
          longitude: 82.432,
          accuracyMeters: 12,
          capturedAt: DateTime.now().toUtc(),
        );
      final points = <GeoPoint>[], errors = <String>[];
      final action = MapLocationAction(
        device: device,
        isAllowed: () => true,
        onLocation: points.add,
        onError: errors.add,
      );
      addTearDown(action.dispose);
      expect(device.calls, isEmpty);
      await action.locate();
      expect(points.single.latitude, 55.002);
      expect(points.single.longitude, 82.432);
      expect(errors, isEmpty);
      expect(device.calls, ['read', 'currentLocation']);
      expect(action.busy, isFalse);
    },
  );

  testWidgets('Отказ разрешения не запускает GPS и не выдумывает точку', (
    tester,
  ) async {
    final device = FakeDevice();
    final errors = <String>[];
    var applied = false;
    final action = MapLocationAction(
      device: device,
      isAllowed: () => true,
      onLocation: (_) => applied = true,
      onError: errors.add,
    );
    addTearDown(action.dispose);
    await action.locate();
    expect(device.calls, ['read', 'foreground', 'read']);
    expect(applied, isFalse);
    expect(errors.single, contains('Разрешите доступ'));
  });

  testWidgets('Уход в фон отменяет разовый GPS, поздний ответ игнорируется', (
    tester,
  ) async {
    final pending = Completer<DeviceLocationFix>();
    final device = FakeDevice()
      ..state = readyState()
      ..locationHandler = () => pending.future;
    final points = <GeoPoint>[], errors = <String>[];
    final action = MapLocationAction(
      device: device,
      isAllowed: () => true,
      onLocation: points.add,
      onError: errors.add,
    );
    addTearDown(action.dispose);
    final request = action.locate();
    await tester.pump();
    action.didChangeAppLifecycleState(AppLifecycleState.paused);
    pending.complete(
      DeviceLocationFix(
        latitude: 55,
        longitude: 82.43,
        accuracyMeters: 10,
        capturedAt: DateTime.now().toUtc(),
      ),
    );
    await request;
    expect(device.calls, contains('cancelCurrentLocation'));
    expect(points, isEmpty);
    expect(errors, isEmpty);
    expect(action.busy, isFalse);
  });

  testWidgets('Старый fix и platform timeout не превращаются в успешный GPS', (
    tester,
  ) async {
    final device = FakeDevice()..state = readyState();
    final errors = <String>[];
    var applied = false;
    final action = MapLocationAction(
      device: device,
      isAllowed: () => true,
      onLocation: (_) => applied = true,
      onError: errors.add,
    );
    addTearDown(action.dispose);
    device.locationHandler = () async => DeviceLocationFix(
      latitude: 55,
      longitude: 82.43,
      accuracyMeters: 10,
      capturedAt: DateTime.now().subtract(const Duration(minutes: 5)),
    );
    await action.locate();
    device.locationHandler = () async =>
        throw PlatformException(code: 'timeout');
    await action.locate();
    expect(applied, isFalse);
    expect(errors, hasLength(2));
    expect(errors.last, contains('Попробуйте ещё раз'));
  });
}
