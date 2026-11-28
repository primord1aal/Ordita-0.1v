import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'backend/api_probe.dart';
import 'backend/probe_journal.dart';
import 'auth/auth_repository.dart';
import 'maps/map_settings.dart';
import 'maps/map_tiles.dart';
import 'maps/geoapify_service.dart';
import 'maps/route_preview.dart';
import 'orders/driver_offer_open.dart';
import 'platform/device_gateway.dart';
import 'screens/api_check_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/device_check_screen.dart';
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
    this.diagnosticsEnabled = const bool.fromEnvironment('ORBITA_DIAGNOSTICS'),
    super.key,
  });
  final DeviceGateway device;
  final bool diagnosticsEnabled;
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
  static const _offerChannel = MethodChannel(
    'ru.orbita.taxi.foundation/driver_offer_open',
  );
  final _navigator = GlobalKey<NavigatorState>();
  final _apiJournal = ProbeJournal();
  final _driverOfferOpens = DriverOfferOpens();
  final _hasOfferBridge =
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
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
    widget.device.onOpenChecks(widget.diagnosticsEnabled ? _openChecks : null);
    if (_hasOfferBridge) {
      _offerChannel.setMethodCallHandler((call) async {
        if (call.method == 'offerOpenAvailable') await _readOfferOpen();
      });
      unawaited(_readOfferOpen());
    }
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      try {
        if (await widget.device.consumeLaunchRequest() &&
            mounted &&
            widget.diagnosticsEnabled) {
          _openChecks();
        }
      } catch (_) {
        // Отсутствие Android-моста не препятствует просмотру интерфейса.
      }
    });
  }

  Future<void> _readOfferOpen() async {
    try {
      final payload = await _offerChannel.invokeMethod<Object?>(
        'takeOfferOpen',
      );
      if (mounted) _driverOfferOpens.add(payload);
    } on MissingPluginException {
      // Android-мост отсутствует в локальной среде или другой сборке.
    } on PlatformException {
      // Внешнее уведомление не влияет на обычный запуск приложения.
    }
  }

  void _openChecks() {
    if (widget.diagnosticsEnabled) {
      _navigator.currentState?.pushNamed('/device-check');
    }
  }

  @override
  void dispose() {
    widget.device.onOpenChecks(null);
    if (_hasOfferBridge) _offerChannel.setMethodCallHandler(null);
    _driverOfferOpens.dispose();
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
        builder: (context, child) => AnnotatedRegion<SystemUiOverlayStyle>(
          value: OrbitaChrome.systemBars(context),
          child: child!,
        ),
        onUnknownRoute: (_) => MaterialPageRoute<void>(
          builder: (_) => const Scaffold(
            body: SafeArea(
              child: Center(child: Text('Этот раздел недоступен.')),
            ),
          ),
        ),
        routes: {
          '/driver-demo': (_) => const DriverDemoDeniedScreen(),
          '/': (_) => AuthScreen(
            diagnosticsEnabled: widget.diagnosticsEnabled,
            repository: widget.authRepository ?? DisconnectedAuthRepository(),
            device: widget.device,
            mapSettings: _maps,
            addressServiceFactory: widget.addressServiceFactory,
            routeServiceFactory: widget.routeServiceFactory,
            tileSessionFactory: widget.tileSessionFactory,
            driverOfferOpens: _driverOfferOpens,
          ),
          if (widget.diagnosticsEnabled) ...{
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
        },
      ),
    ),
  );
}
