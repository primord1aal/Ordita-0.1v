import 'dart:async';

import 'package:orbita_mobile/src/backend/api_probe.dart';
import 'package:orbita_mobile/src/platform/network_observer.dart';

class FakeApiProbe implements ApiProbe {
  @override
  bool configured = true;
  @override
  Uri get targetUri =>
      Uri.https('aaaaaaaaaaaaaaaaaaaa.supabase.co', '/auth/v1/health');
  @override
  String get expectedDomain => targetUri.host;
  @override
  bool domainMatches = true;
  int calls = 0;
  bool disposed = false;
  Completer<ProbeResult>? pending;
  ProbeState state = ProbeState.ready;
  @override
  Future<ProbeResult> check() async {
    calls++;
    return pending?.future ??
        ProbeResult(
          state: state,
          elapsed: const Duration(milliseconds: 100),
          checkedAt: DateTime(2026, 1, 1),
          httpStatus: state == ProbeState.ready ? 200 : null,
          requestUri: targetUri,
        );
  }

  @override
  void dispose() => disposed = true;
}

class FakeNetworkObserver implements NetworkObserver {
  NetworkType type = NetworkType.wifi;
  NetworkType? afterType;
  bool? vpn = false, proxy = false;
  bool? afterVpn, afterProxy;
  int attempt = 0;
  final List<bool> calls = [];
  @override
  Future<NetworkSnapshot> snapshot({bool beginProbe = false}) async {
    calls.add(beginProbe);
    if (beginProbe) attempt++;
    final observed = !beginProbe && attempt > 0 ? afterType ?? type : type;
    return NetworkSnapshot(
      type: observed,
      networkId: observed == NetworkType.unknown ? null : observed.name,
      vpn: !beginProbe && attempt > 0 ? afterVpn ?? vpn : vpn,
      proxy: !beginProbe && attempt > 0 ? afterProxy ?? proxy : proxy,
      processSession: '00000000-0000-4000-8000-000000000001',
      attempt: attempt,
    );
  }
}
