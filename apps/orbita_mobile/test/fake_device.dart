import 'package:orbita_mobile/src/platform/device_gateway.dart';

class FakeDevice implements DeviceGateway {
  DeviceState state = const DeviceState();
  final List<String> calls = [];
  bool launchRequested = false;
  bool failRead = false;
  void Function()? openCallback;
  @override
  Future<DeviceState> read() async {
    calls.add('read');
    if (failRead) throw StateError('Тестовый отказ платформы');
    return state;
  }

  @override
  Future<void> requestNotifications() async {
    calls.add('notifications');
  }

  @override
  Future<void> requestForegroundLocation() async {
    calls.add('foreground');
  }

  @override
  Future<void> requestBackgroundLocation() async {
    calls.add('background');
  }

  @override
  Future<void> showLocalNotification() async {
    calls.add('notification');
  }

  @override
  Future<void> startLocationDiagnostic() async {
    calls.add('start');
  }

  @override
  Future<void> stopLocationDiagnostic() async {
    calls.add('stop');
  }

  @override
  Future<void> openSettings() async {
    calls.add('settings');
  }

  @override
  Future<bool> consumeLaunchRequest() async => launchRequested;
  @override
  void onOpenChecks(void Function()? callback) {
    openCallback = callback;
  }
}
