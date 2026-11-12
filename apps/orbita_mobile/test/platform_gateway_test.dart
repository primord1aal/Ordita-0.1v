import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('orbita.test/device');
  final calls = <String>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          if (call.method == 'capabilities') {
            return <String, dynamic>{
              'sdk': 34,
              'notifications': true,
              'location': 'approximate',
              'backgroundLocation': false,
              'locationEnabled': true,
            };
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test(
    'Чтение готовности не запрашивает разрешения и не запускает службу',
    () async {
      final gateway = AndroidDeviceGateway(channel: channel);
      final state = await gateway.read();
      expect(state.sdk, 34);
      expect(state.canStartDiagnostic, isTrue);
      expect(calls, ['capabilities']);
    },
  );
  test('Запросы геопозиции разделены на независимые явные действия', () async {
    final gateway = AndroidDeviceGateway(channel: channel);
    await gateway.requestForegroundLocation();
    expect(calls, ['requestForegroundLocation']);
    await gateway.requestBackgroundLocation();
    expect(calls, ['requestForegroundLocation', 'requestBackgroundLocation']);
  });
  test('Неизвестный ответ о доступе не разрешает запуск службы', () {
    final state = DeviceState.fromMap({
      'sdk': 34,
      'notifications': true,
      'location': 'unknown',
      'locationEnabled': true,
    });
    expect(state.canStartDiagnostic, isFalse);
  });
  test(
    'Разовый запрос получает координаты и точность без запуска службы',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return <String, dynamic>{
              'latitude': 55.012,
              'longitude': 82.432,
              'accuracyMeters': 18.5,
              'capturedAt': 1794484800000,
            };
          });
      final fix = await AndroidDeviceGateway(channel: channel)
          .currentLocation();
      expect(fix.latitude, 55.012);
      expect(fix.longitude, 82.432);
      expect(fix.accuracyMeters, 18.5);
      expect(fix.capturedAt.millisecondsSinceEpoch, 1794484800000);
      expect(calls, ['currentLocation']);
    },
  );
  test(
    'Отмена разового запроса не останавливает диагностическую службу',
    () async {
      await AndroidDeviceGateway(channel: channel).cancelCurrentLocation();
      expect(calls, ['cancelCurrentLocation']);
    },
  );
  for (final code in ['permission', 'location_disabled', 'timeout', 'busy']) {
    test('Ошибка разовой геопозиции $code сохраняет причину', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async {
            throw PlatformException(code: code, message: 'Тестовая причина');
          });
      await expectLater(
        AndroidDeviceGateway(channel: channel).currentLocation(),
        throwsA(isA<PlatformException>().having((e) => e.code, 'code', code)),
      );
    });
  }
  test(
    'Пустой ответ Android не превращается в вымышленные координаты',
    () async {
      await expectLater(
        AndroidDeviceGateway(channel: channel).currentLocation(),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'invalid_location',
          ),
        ),
      );
    },
  );
  test('Некорректные координаты, точность и время отклоняются', () {
    final valid = <String, dynamic>{
      'latitude': 55.012,
      'longitude': 82.432,
      'accuracyMeters': 18.5,
      'capturedAt': 1794484800000,
    };
    for (final invalid in [
      {'latitude': double.nan},
      {'latitude': 91},
      {'longitude': double.infinity},
      {'longitude': -181},
      {'accuracyMeters': -1},
      {'accuracyMeters': 'unknown'},
      {'capturedAt': 0},
      {'capturedAt': 8640000000000001},
    ]) {
      expect(
        () => DeviceLocationFix.fromMap({...valid, ...invalid}),
        throwsA(isA<PlatformException>()),
      );
    }
  });
}
