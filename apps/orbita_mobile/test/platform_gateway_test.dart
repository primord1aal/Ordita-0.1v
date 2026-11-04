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
}
