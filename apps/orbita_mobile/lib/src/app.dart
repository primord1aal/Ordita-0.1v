import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'backend/api_probe.dart';
import 'backend/probe_journal.dart';
import 'auth/auth_repository.dart';
import 'maps/map_settings.dart';
import 'maps/map_tiles.dart';
import 'maps/geoapify_service.dart';
import 'platform/device_gateway.dart';
import 'screens/api_check_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/device_check_screen.dart';
import 'screens/map_settings_screen.dart';
import 'ui/theme.dart';

class OrbitaApp extends StatefulWidget {
  const OrbitaApp({
    required this.device,
    this.apiProbeFactory,
    this.authRepository,
    this.mapSettings,
    this.addressServiceFactory,
    this.tileSessionFactory,
    super.key,
  });
  final DeviceGateway device;
  final ApiProbe Function()? apiProbeFactory;
  final AuthRepository? authRepository;
  final MapSettings? mapSettings;
  final AddressService Function(String)? addressServiceFactory;
  final MapTileSession Function(String)? tileSessionFactory;
  @override
  State<OrbitaApp> createState() => _OrbitaAppState();
}

class _OrbitaAppState extends State<OrbitaApp> {
  final _navigator = GlobalKey<NavigatorState>();
  final _apiJournal = ProbeJournal();
  late final _maps = widget.mapSettings ?? MapSettings();
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
    if (widget.mapSettings == null) _maps.dispose();
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
      '/': (_) => AuthScreen(
        repository: widget.authRepository ?? DisconnectedAuthRepository(),
        device: widget.device,
        mapSettings: _maps,
        addressServiceFactory: widget.addressServiceFactory,
        tileSessionFactory: widget.tileSessionFactory,
      ),
      if (kDebugMode)
        '/map-settings': (_) => MapSettingsScreen(settings: _maps),
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
