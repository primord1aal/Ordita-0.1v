import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/platform/device_gateway.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(OrbitaApp(device: AndroidDeviceGateway()));
}
