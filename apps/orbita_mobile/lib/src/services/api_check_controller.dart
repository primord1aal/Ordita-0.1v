import 'dart:async';

import 'package:flutter/widgets.dart';

import '../backend/api_probe.dart';
import '../backend/probe_journal.dart';
import '../platform/network_observer.dart';

class ApiCheckController extends ChangeNotifier with WidgetsBindingObserver {
  ApiCheckController({
    required this.probe,
    required this.network,
    required this.journal,
  }) {
    WidgetsBinding.instance.addObserver(this);
    refreshNetwork();
  }
  final ApiProbe probe;
  final NetworkObserver network;
  final ProbeJournal journal;
  NetworkSnapshot current = const NetworkSnapshot();
  bool busy = false, disposed = false;

  Future<NetworkSnapshot> _snapshot({bool begin = false}) async {
    try {
      return await network
          .snapshot(beginProbe: begin)
          .timeout(const Duration(milliseconds: 700));
    } catch (_) {
      return const NetworkSnapshot();
    }
  }

  Future<void> refreshNetwork() async {
    final observed = await _snapshot();
    if (disposed || busy) return;
    current = observed;
    notifyListeners();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) refreshNetwork();
  }

  Future<ProbeRecord?> run(ProbeConditions conditions) async {
    if (disposed || busy || journal.full || !conditions.valid) return null;
    busy = true;
    notifyListeners();
    final started = DateTime.now();
    var before = current;
    var after = current;
    var attempted = false;
    ProbeResult blocked(ProbeState state) => ProbeResult(
      state: state,
      elapsed: Duration.zero,
      checkedAt: DateTime.now(),
      requestUri: probe.targetUri,
    );
    late ProbeResult result;
    try {
      if (!probe.configured) {
        result = blocked(ProbeState.unconfigured);
      } else if (!probe.domainMatches) {
        result = blocked(ProbeState.domainMismatch);
      } else {
        before = await _snapshot(begin: true);
        if (disposed) return null;
        current = before;
        if (before.type == NetworkType.none) {
          result = blocked(ProbeState.noNetwork);
        } else if (before.vpn == true ||
            before.proxy == true ||
            before.type == NetworkType.vpn) {
          result = blocked(ProbeState.conditionsBlocked);
        } else if (before.type == NetworkType.unknown &&
            !conditions.manualNetworkConfirmed) {
          result = blocked(ProbeState.conditionsBlocked);
        } else if (before.type != NetworkType.unknown &&
            before.type != conditions.expectedNetwork) {
          result = blocked(ProbeState.networkMismatch);
        } else {
          attempted = true;
          result = await probe.check();
        }
        after = await _snapshot();
        current = after;
      }
      if (disposed) return null;
      final actualUri = result.requestUri ?? probe.targetUri;
      final record = ProbeRecord(
        result: result,
        conditions: conditions,
        before: before,
        after: after,
        startedAt: started,
        expectedDomain: probe.expectedDomain,
        requestDomain: actualUri?.host,
        domainMatches:
            probe.domainMatches && actualUri?.host == probe.expectedDomain,
        requestAttempted: attempted,
      );
      journal.add(record);
      return record;
    } finally {
      if (!disposed) {
        busy = false;
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    probe.dispose();
    super.dispose();
  }
}
