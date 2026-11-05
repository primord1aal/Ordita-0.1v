import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/platform/device_gateway.dart';
import 'src/auth/supabase_auth_repository.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    OrbitaApp(
      device: AndroidDeviceGateway(),
      authRepository: createAuthRepository(),
    ),
  );
}
