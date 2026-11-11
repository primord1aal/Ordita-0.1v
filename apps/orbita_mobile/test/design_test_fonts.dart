import 'package:flutter/services.dart';

/// Шрифты берутся из Flutter asset bundle текущей сборки, а не из пути SDK.
Future<void> loadDesignTestFonts() async {
  final inter = FontLoader('Inter');
  for (final file in [
    'Inter-Regular.ttf',
    'Inter-Medium.ttf',
    'Inter-SemiBold.ttf',
    'Inter-Bold.ttf',
  ]) {
    inter.addFont(rootBundle.load('assets/fonts/$file'));
  }
  await inter.load();
  await (FontLoader(
    'MaterialIcons',
  )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
}

/// PNG обновляются только при явном запуске:
/// flutter test --dart-define=ORBITA_CAPTURE_GOLDENS=true --update-goldens
const captureDesignGoldens = bool.fromEnvironment('ORBITA_CAPTURE_GOLDENS');
