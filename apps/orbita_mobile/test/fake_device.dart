import 'package:orbita_mobile/src/platform/device_gateway.dart';

class FakeDevice implements DeviceGateway {
  DeviceState state = const DeviceState();
  final List<String> calls = [];
  bool launchRequested = false;
  bool failRead = false;
  Future<DeviceState> Function()? readHandler;
  Future<void> Function(String name)? actionHandler;
  Future<DeviceLocationFix> Function()? locationHandler;
  void Function()? openCallback;
  @override
  Future<DeviceState> read() async {
    calls.add('read');
    if (failRead) throw StateError('Тестовый отказ платформы');
    if (readHandler != null) return readHandler!();
    return state;
  }

  @override
  Future<void> requestNotifications() async {
    calls.add('notifications');
    await actionHandler?.call('notifications');
  }

  @override
  Future<void> requestForegroundLocation() async {
    calls.add('foreground');
    await actionHandler?.call('foreground');
  }

  @override
  Future<DeviceLocationFix> currentLocation() async {
    calls.add('currentLocation');
    if (locationHandler != null) return locationHandler!();
    throw StateError('Тестовая геопозиция не задана');
  }

  @override
  Future<void> cancelCurrentLocation() async {
    calls.add('cancelCurrentLocation');
    await actionHandler?.call('cancelCurrentLocation');
  }

  @override
  Future<void> requestBackgroundLocation() async {
    calls.add('background');
    await actionHandler?.call('background');
  }

  @override
  Future<void> showLocalNotification() async {
    calls.add('notification');
    await actionHandler?.call('notification');
  }

  @override
  Future<void> startLocationDiagnostic() async {
    calls.add('start');
    await actionHandler?.call('start');
  }

  @override
  Future<void> stopLocationDiagnostic() async {
    calls.add('stop');
    await actionHandler?.call('stop');
  }

  @override
  Future<void> openSettings() async {
    calls.add('settings');
    await actionHandler?.call('settings');
  }

  @override
  Future<bool> consumeLaunchRequest() async => launchRequested;
  @override
  void onOpenChecks(void Function()? callback) {
    openCallback = callback;
  }
}
