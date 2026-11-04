import 'package:flutter/services.dart';

enum NetworkType {
  wifi('Wi-Fi'),
  mobile('Мобильная сеть'),
  vpn('VPN'),
  other('Другая сеть'),
  none('Нет сети'),
  unknown('Не определено');

  const NetworkType(this.label);
  final String label;
}

class NetworkSnapshot {
  const NetworkSnapshot({
    this.type = NetworkType.unknown,
    this.networkId,
    this.vpn,
    this.proxy,
    this.processSession,
    this.attempt = 0,
  });
  factory NetworkSnapshot.fromMap(Map<String, dynamic> map) => NetworkSnapshot(
    type: NetworkType.values.firstWhere(
      (type) => type.name == map['type'],
      orElse: () => NetworkType.unknown,
    ),
    networkId: map['networkId'] as String?,
    vpn: map['vpn'] as bool?,
    proxy: map['proxy'] as bool?,
    processSession: map['processSession'] as String?,
    attempt: (map['attempt'] as num?)?.toInt() ?? 0,
  );
  final NetworkType type;
  // Только для сравнения снимков; в буфер/интерфейс этот идентификатор не попадает.
  final String? networkId;
  final bool? vpn, proxy;
  // Случайная метка жизни Android-процесса, не идентификатор устройства или Auth.
  final String? processSession;
  final int attempt;
  bool get knownTransport =>
      type == NetworkType.wifi || type == NetworkType.mobile;
}

abstract interface class NetworkObserver {
  Future<NetworkSnapshot> snapshot({bool beginProbe = false});
}

class AndroidNetworkObserver implements NetworkObserver {
  const AndroidNetworkObserver({
    this.channel = const MethodChannel('ru.orbita.taxi.foundation/network'),
  });
  final MethodChannel channel;
  @override
  Future<NetworkSnapshot> snapshot({bool beginProbe = false}) async {
    try {
      final map = await channel
          .invokeMapMethod<String, dynamic>(
            beginProbe ? 'beginProbe' : 'snapshot',
          )
          .timeout(const Duration(milliseconds: 700));
      return NetworkSnapshot.fromMap(map ?? {});
    } catch (_) {
      return const NetworkSnapshot();
    }
  }
}
