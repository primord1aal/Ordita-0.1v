import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/platform/device_gateway.dart';
import 'src/auth/supabase_auth_repository.dart';
import 'src/maps/map_settings.dart';
import 'src/ui/theme_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final themeSettings = ThemeSettings();
  await themeSettings.load();
  runApp(
    OrbitaApp(
      themeSettings: themeSettings,
      device: AndroidDeviceGateway(),
      authRepository: createAuthRepository(),
      mapSettings: MapSettings(store: SecureMapKeyStore())..load(),
    ),
  );
}
