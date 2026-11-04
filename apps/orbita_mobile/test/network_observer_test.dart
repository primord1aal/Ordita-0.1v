import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/platform/network_observer.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('orbita.fixture/network');
  const observer = AndroidNetworkObserver(channel: channel);
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('Мост передаёт фактический тип и начало попытки Android', () async {
    final calls = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call.method);
          return {
            'type': 'mobile',
            'networkId': 'fixture-private-handle',
            'vpn': false,
            'proxy': false,
            'processSession': '00000000-0000-4000-8000-000000000001',
            'attempt': 1,
          };
        });
    final result = await observer.snapshot(beginProbe: true);
    expect(result.type, NetworkType.mobile);
    expect(result.attempt, 1);
    expect(calls, ['beginProbe']);
  });

  test('Недоступный Android не подменяется предположением Wi-Fi', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'fixture'),
        );
    expect((await observer.snapshot()).type, NetworkType.unknown);
  });

  test('Неизвестный тип и пустой ответ остаются неопределёнными', () {
    expect(
      NetworkSnapshot.fromMap({'type': 'fixture-new-type'}).type,
      NetworkType.unknown,
    );
    expect(NetworkSnapshot.fromMap({}).type, NetworkType.unknown);
  });
}
