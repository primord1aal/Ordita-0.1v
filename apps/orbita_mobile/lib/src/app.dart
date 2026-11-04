import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'platform/device_gateway.dart';
import 'screens/device_check_screen.dart';
import 'screens/preview_screens.dart';

class OrbitaApp extends StatefulWidget {
  const OrbitaApp({required this.device, super.key});
  final DeviceGateway device;
  @override
  State<OrbitaApp> createState() => _OrbitaAppState();
}

class _OrbitaAppState extends State<OrbitaApp> {
  final _navigator = GlobalKey<NavigatorState>();
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
    theme: ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xff111720),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xffb9ef63),
        brightness: Brightness.dark,
        primary: const Color(0xffb9ef63),
        surface: const Color(0xff1b2431),
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xff111720),
        centerTitle: false,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(48, 54),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
      ),
      cardTheme: const CardThemeData(
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(20)),
        ),
      ),
    ),
    routes: {
      '/': (_) => const WelcomeScreen(),
      '/device-check': (_) => DeviceCheckScreen(device: widget.device),
    },
  );
}
