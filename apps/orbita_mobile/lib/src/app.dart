import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'backend/api_probe.dart';
import 'backend/probe_journal.dart';
import 'auth/auth_repository.dart';
import 'platform/device_gateway.dart';
import 'screens/api_check_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/device_check_screen.dart';
import 'screens/preview_screens.dart';
import 'ui/theme.dart';

class OrbitaApp extends StatefulWidget {
  const OrbitaApp({
    required this.device,
    this.apiProbeFactory,
    this.authRepository,
    super.key,
  });
  final DeviceGateway device;
  final ApiProbe Function()? apiProbeFactory;
  final AuthRepository? authRepository;
  @override
  State<OrbitaApp> createState() => _OrbitaAppState();
}

class _OrbitaAppState extends State<OrbitaApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _apiJournal = ProbeJournal();
  @override
  void initState() {
    super.initState();
    widget.device.onOpenChecks(_openChecks);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (await widget.device.consumeLaunchRequest() && mounted) {
          _openChecks();
        }
      } catch (_) {
        // Отсутствие Android-моста не препятствует просмотру интерфейса.
      }
    });
  }

  void _openChecks() => _navigator.currentState?.pushNamed('/device-check');
  @override
  void dispose() {
    widget.device.onOpenChecks(null);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Орбита',
    debugShowCheckedModeBanner: false,
    locale: const Locale('ru'),
    supportedLocales: const [Locale('ru')],
    localizationsDelegates: GlobalMaterialLocalizations.delegates,
    navigatorKey: _navigator,
    theme: orbitaTheme(),
    routes: {
      '/': (_) => widget.authRepository == null
          ? WelcomeScreen(device: widget.device)
          : AuthScreen(
              repository: widget.authRepository!,
              device: widget.device,
            ),
      '/api-check': (_) => ApiCheckScreen(
        probe: (widget.apiProbeFactory ?? createApiProbe)(),
        journal: _apiJournal,
      ),
      '/device-check': (_) => DeviceCheckScreen(device: widget.device),
      '/device-check/notifications': (_) => DeviceCheckScreen(
        device: widget.device,
        section: DeviceCheckSection.notifications,
      ),
      '/device-check/location': (_) => DeviceCheckScreen(
        device: widget.device,
        section: DeviceCheckSection.location,
      ),
    },
  );
}
