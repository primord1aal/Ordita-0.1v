import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/services.dart';

import 'backend/api_probe.dart';
import 'backend/probe_journal.dart';
import 'auth/auth_repository.dart';
import 'maps/map_settings.dart';
import 'maps/map_tiles.dart';
import 'maps/geoapify_service.dart';
import 'maps/route_preview.dart';
import 'platform/device_gateway.dart';
import 'screens/api_check_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/device_check_screen.dart';
import 'screens/map_settings_screen.dart';
import 'ui/theme.dart';
import 'ui/theme_settings.dart';
import 'ui/driver_demo_access.dart';

class OrbitaApp extends StatefulWidget {
  const OrbitaApp({
    required this.device,
    this.apiProbeFactory,
    this.authRepository,
    this.mapSettings,
    this.addressServiceFactory,
    this.routeServiceFactory,
    this.tileSessionFactory,
    this.themeSettings,
    super.key,
  });
  final DeviceGateway device;
  final ApiProbe Function()? apiProbeFactory;
  final AuthRepository? authRepository;
  final MapSettings? mapSettings;
  final AddressService Function(String)? addressServiceFactory;
  final RouteService Function(String)? routeServiceFactory;
  final MapTileSession Function(String)? tileSessionFactory;
  final ThemeSettings? themeSettings;
  @override
  State<OrbitaApp> createState() => _OrbitaAppState();
}

class _OrbitaAppState extends State<OrbitaApp> {
  static bool _fontLicenseRegistered = false;
  final _navigator = GlobalKey<NavigatorState>();
  final _apiJournal = ProbeJournal();
  late final _themeSettings = widget.themeSettings ?? ThemeSettings();
  late final _maps = widget.mapSettings ?? MapSettings();
  @override
  void initState() {
    super.initState();
    if (!_fontLicenseRegistered) {
      _fontLicenseRegistered = true;
      LicenseRegistry.addLicense(() async* {
        yield LicenseEntryWithLineBreaks([
          'Inter',
        ], await rootBundle.loadString('assets/fonts/OFL.txt'));
      });
    }
    if (widget.themeSettings == null) unawaited(_themeSettings.load());
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
    if (widget.themeSettings == null) _themeSettings.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _themeSettings,
    builder: (context, _) => ThemeSettingsScope(
      settings: _themeSettings,
      child: MaterialApp(
        title: 'Орбита',
        debugShowCheckedModeBanner: false,
        locale: const Locale('ru'),
        supportedLocales: const [Locale('ru')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        navigatorKey: _navigator,
        theme: orbitaTheme(brightness: Brightness.light),
        darkTheme: orbitaTheme(),
        themeMode: _themeSettings.mode,
        routes: {
          '/driver-demo': (_) => const DriverDemoDeniedScreen(),
          '/': (_) => AuthScreen(
            repository: widget.authRepository ?? DisconnectedAuthRepository(),
            device: widget.device,
            mapSettings: _maps,
            addressServiceFactory: widget.addressServiceFactory,
            routeServiceFactory: widget.routeServiceFactory,
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
      ),
    ),
  );
}
