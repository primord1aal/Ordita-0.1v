import 'package:flutter/services.dart';

class DeviceState {
  const DeviceState({
    this.sdk = 0,
    this.notifications = false,
    this.location = 'denied',
    this.backgroundLocation = false,
    this.locationEnabled = false,
    this.serviceRunning = false,
    this.startedAt = 0,
    this.lastHeartbeat = 0,
    this.lastFix = 0,
    this.fixCount = 0,
  });
  factory DeviceState.fromMap(Map<String, dynamic> map) => DeviceState(
    sdk: (map['sdk'] as num?)?.toInt() ?? 0,
    notifications: map['notifications'] == true,
    location: map['location'] as String? ?? 'denied',
    backgroundLocation: map['backgroundLocation'] == true,
    locationEnabled: map['locationEnabled'] == true,
    serviceRunning: map['serviceRunning'] == true,
    startedAt: (map['startedAt'] as num?)?.toInt() ?? 0,
    lastHeartbeat: (map['lastHeartbeat'] as num?)?.toInt() ?? 0,
    lastFix: (map['lastFix'] as num?)?.toInt() ?? 0,
    fixCount: (map['fixCount'] as num?)?.toInt() ?? 0,
  );
  final int sdk;
  final bool notifications;
  final String location;
  final bool backgroundLocation;
  final bool locationEnabled;
  final bool serviceRunning;
  final int startedAt;
  final int lastHeartbeat;
  final int lastFix;
  final int fixCount;
  bool get hasForegroundLocation =>
      location == 'precise' || location == 'approximate';
  bool get canStartDiagnostic =>
      notifications && hasForegroundLocation && locationEnabled;
}

abstract interface class DeviceGateway {
  Future<DeviceState> read();
  Future<void> requestNotifications();
  Future<void> requestForegroundLocation();
  Future<void> requestBackgroundLocation();
  Future<void> showLocalNotification();
  Future<void> startLocationDiagnostic();
  Future<void> stopLocationDiagnostic();
  Future<void> openSettings();
  Future<bool> consumeLaunchRequest();
  void onOpenChecks(void Function()? callback);
}

class AndroidDeviceGateway implements DeviceGateway {
  AndroidDeviceGateway({MethodChannel? channel})
    : _channel =
          channel ?? const MethodChannel('ru.orbita.taxi.foundation/device');
  final MethodChannel _channel;
  Future<void> _call(String method) => _channel.invokeMethod<void>(method);
  @override
  Future<DeviceState> read() async => DeviceState.fromMap(
    await _channel.invokeMapMethod<String, dynamic>('capabilities') ?? {},
  );
  @override
  Future<void> requestNotifications() => _call('requestNotifications');
  @override
  Future<void> requestForegroundLocation() =>
      _call('requestForegroundLocation');
  @override
  Future<void> requestBackgroundLocation() =>
      _call('requestBackgroundLocation');
  @override
  Future<void> showLocalNotification() => _call('showLocalNotification');
  @override
  Future<void> startLocationDiagnostic() => _call('startLocationDiagnostic');
  @override
  Future<void> stopLocationDiagnostic() => _call('stopLocationDiagnostic');
  @override
  Future<void> openSettings() => _call('openSettings');
  @override
  Future<bool> consumeLaunchRequest() async =>
      await _channel.invokeMethod<bool>('consumeLaunchRequest') ?? false;
  @override
  void onOpenChecks(void Function()? callback) {
    _channel.setMethodCallHandler(
      callback == null
          ? null
          : (call) async {
              if (call.method == 'openChecks') callback();
            },
    );
  }
}
