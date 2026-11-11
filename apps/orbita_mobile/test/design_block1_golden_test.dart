// Снимки настоящих Flutter-экранов. Данные и AuthRepository искусственные.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'design_test_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);

  for (final mode in [ThemeMode.light, ThemeMode.dark]) {
    testWidgets('Flutter: приветствие, ${mode.name}', (tester) async {
      SharedPreferences.setMockInitialValues({
        ThemeSettings.storageKey: mode.name,
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<AuthSession?>();
      final repo = FakeAuthRepository()..restorePending = pending;
      final settings = ThemeSettings();
      await settings.load();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        OrbitaApp(
          device: FakeDevice(),
          authRepository: repo,
          themeSettings: settings,
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const Key('startup-splash')), findsOneWidget);
      expect(
        Theme.of(tester.element(find.byKey(const Key('startup-splash'))))
            .brightness,
        mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
      );
      if (captureDesignGoldens) {
        await expectLater(
          find.byKey(const Key('startup-splash')),
          matchesGoldenFile('goldens/block1-welcome-${mode.name}.png'),
        );
      }
      pending.complete(null);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Flutter: вход, ${mode.name}', (tester) async {
      SharedPreferences.setMockInitialValues({
        ThemeSettings.storageKey: mode.name,
      });
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final settings = ThemeSettings();
      await settings.load();
      addTearDown(settings.dispose);
      await tester.pumpWidget(
        OrbitaApp(
          device: FakeDevice(),
          authRepository: FakeAuthRepository(),
          themeSettings: settings,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(2));
      expect(find.byType(Scaffold), findsWidgets);
      expect(
        Theme.of(tester.element(find.byType(Scaffold).first)).brightness,
        mode == ThemeMode.dark ? Brightness.dark : Brightness.light,
      );
      if (captureDesignGoldens) {
        await expectLater(
          find.byType(Scaffold).first,
          matchesGoldenFile('goldens/block1-login-${mode.name}.png'),
        );
      }
      expect(tester.takeException(), isNull);
    });
  }
}
