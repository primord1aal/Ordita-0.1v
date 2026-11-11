import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/ui/theme.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Светлая, тёмная и системная темы сохраняются отдельно от сессии',
    () async {
      SharedPreferences.setMockInitialValues({'session_marker': 'untouched'});
      final settings = ThemeSettings();
      expect(settings.mode, ThemeMode.system);
      await settings.setMode(ThemeMode.dark);
      expect(settings.mode, ThemeMode.dark);
      final restored = ThemeSettings();
      await restored.load();
      expect(restored.mode, ThemeMode.dark);
      await restored.setMode(ThemeMode.light);
      final again = ThemeSettings();
      await again.load();
      expect(again.mode, ThemeMode.light);
      await again.setMode(ThemeMode.system);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_marker'), 'untouched');
      expect(prefs.getString(ThemeSettings.storageKey), 'system');
      settings.dispose();
      restored.dispose();
      again.dispose();
    },
  );

  test('Цвета обеих тем соответствуют утверждённым токенам', () {
    expect(
      orbitaTheme(brightness: Brightness.light).scaffoldBackgroundColor,
      const Color(0xffF1F1E8),
    );
    expect(orbitaTheme().scaffoldBackgroundColor, const Color(0xff23241F));
    expect(orbitaTheme().textTheme.bodyLarge?.fontFamily, 'Inter');
  });
}
