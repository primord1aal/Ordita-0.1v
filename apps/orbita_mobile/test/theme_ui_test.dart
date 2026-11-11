import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart';
import 'package:orbita_mobile/src/ui/theme_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'test_helpers.dart';

void main() {
  testWidgets('Лицензия Inter доступна из профиля', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    await scrollTo(tester, find.text('Лицензии'));
    await tester.tap(find.text('Лицензии'));
    await tester.pumpAndSettle();
    expect(find.text('Inter'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Тема меняется из профиля и сохраняется после перезапуска', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    await tester.tap(find.text('Тема оформления'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тёмная'));
    await tester.pumpAndSettle();
    expect(
      Theme.of(tester.element(find.byType(ProfileScreen))).brightness,
      Brightness.dark,
    );
    expect(
      (await SharedPreferences.getInstance()).getString(
        ThemeSettings.storageKey,
      ),
      'dark',
    );
    await tester.pumpWidget(const SizedBox());
    await openPreview(tester, 'Пассажир');
    await openProfile(tester);
    expect(find.text('Тёмная'), findsOneWidget);
    expect(
      Theme.of(tester.element(find.byType(ProfileScreen))).brightness,
      Brightness.dark,
    );
    expect(tester.takeException(), isNull);
  });
}
