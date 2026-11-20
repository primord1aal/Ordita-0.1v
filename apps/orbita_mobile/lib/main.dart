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
  final auth = createAuthRepository();
  runApp(
    OrbitaApp(
      themeSettings: themeSettings,
      device: AndroidDeviceGateway(),
      authRepository: auth,
      mapSettings: auth is SupabaseAuthRepository
          ? MapSettings.managed(auth.mapRequest)
          : MapSettings(),
    ),
  );
}
