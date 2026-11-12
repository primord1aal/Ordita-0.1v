import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/ui/adaptive_navigation.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'test_helpers.dart';
import 'design_test_fonts.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);
  Future<void> mount(
    WidgetTester tester, {
    required Size size,
    required double scale,
    double? availableHeight,
    EdgeInsets padding = EdgeInsets.zero,
    ValueChanged<int>? onSelected,
  }) async {
    setViewport(tester, size, scale);
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: orbitaTheme(brightness: Brightness.light),
        home: MediaQuery(
          data: MediaQueryData(
            size: size,
            textScaler: TextScaler.linear(scale),
            padding: padding,
          ),
          child: StatefulBuilder(
            builder: (context, setState) => LayoutBuilder(
              builder: (context, constraints) => Scaffold(
                body: Center(child: Text('Текущий раздел: $selected')),
                bottomNavigationBar: AdaptiveNavigation(
                  driver: false,
                  selected: selected,
                  availableHeight:
                      availableHeight ??
                      constraints.maxHeight - padding.vertical,
                  onSelected: (value) {
                    onSelected?.call(value);
                    setState(() => selected = value);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void checkTargets(WidgetTester tester, Size view) {
    final rects = [
      for (var i = 0; i < 3; i++) tester.getRect(find.byKey(Key('nav-$i'))),
    ];
    for (var i = 0; i < rects.length; i++) {
      final rect = rects[i];
      expect(rect.width, greaterThanOrEqualTo(48));
      expect(rect.height, greaterThanOrEqualTo(48));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(view.width));
      expect(rect.bottom, lessThanOrEqualTo(view.height));
      final labelText = ['Заказ', 'Поездки', 'Профиль'][i];
      final label = find.descendant(
        of: find.text(labelText),
        matching: find.byType(RichText),
      );
      final paragraph = tester.renderObject<RenderParagraph>(label.first);
      final text = paragraph.text.toPlainText();
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: text.length),
      );
      expect(boxes.map((box) => box.top).toSet().length, 1, reason: text);
    }
  }

  for (final size in [
    const Size(320, 568),
    const Size(360, 740),
    const Size(390, 844),
    const Size(800, 1280),
  ]) {
    for (final scale in [1.0, 1.3, 2.0, 3.2]) {
      testWidgets('Все разделы доступны: $size, ×$scale', (tester) async {
        await mount(tester, size: size, scale: scale);
        final compact = find
            .byKey(const Key('navigation-compact'))
            .evaluate()
            .isNotEmpty;
        final vertical = find
            .byKey(const Key('navigation-vertical'))
            .evaluate()
            .isNotEmpty;
        if (scale == 1) {
          expect(
            find.byKey(const Key('navigation-horizontal')),
            findsOneWidget,
          );
        }
        if (vertical) {
          expect(
            tester.getSize(find.byKey(const Key('navigation-vertical'))).height,
            lessThanOrEqualTo(size.height * 0.20 + 0.5),
          );
        }
        if (compact) {
          final rect = tester.getRect(find.byKey(const Key('nav-sections')));
          expect(rect.width, greaterThanOrEqualTo(48));
          expect(rect.height, greaterThanOrEqualTo(48));
          await tester.tap(find.byKey(const Key('nav-sections')));
          await tester.pumpAndSettle();
        }
        checkTargets(tester, size);
        await tester.tap(find.byKey(const Key('nav-2')));
        await tester.pumpAndSettle();
        expect(find.text('Текущий раздел: 2'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('Вертикальные строки учитывают доступную область и SafeArea', (
    tester,
  ) async {
    const size = Size(320, 2000);
    const padding = EdgeInsets.fromLTRB(12, 24, 12, 24);
    await mount(
      tester,
      size: size,
      scale: 3.2,
      availableHeight: 1920,
      padding: padding,
    );
    final vertical = find.byKey(const Key('navigation-vertical'));
    expect(vertical, findsOneWidget);
    expect(tester.getSize(vertical).height, lessThanOrEqualTo(1920 * 0.20));
    final target = tester.getRect(find.byKey(const Key('nav-2')));
    expect(target.left, greaterThanOrEqualTo(12));
    expect(target.right, lessThanOrEqualTo(308));
    expect(target.bottom, lessThanOrEqualTo(1976));
    await mount(
      tester,
      size: size,
      scale: 3.2,
      availableHeight: 600,
      padding: padding,
    );
    expect(find.byKey(const Key('navigation-compact')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Разделы: семантика текущего экрана, Back и однократный переход',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final transitions = <int>[];
      try {
        await mount(
          tester,
          size: const Size(320, 568),
          scale: 3.2,
          onSelected: transitions.add,
        );
        final opener = find.byKey(const Key('nav-sections'));
        expect(
          tester.getSemantics(opener).getSemanticsData().label,
          contains('Текущий раздел: Заказ'),
        );
        final openAction = tester.widget<Semantics>(opener).properties.onTap!;
        openAction();
        openAction();
        await tester.pumpAndSettle();
        expect(find.byType(BottomSheet), findsOneWidget);
        final selected = tester.getSemantics(find.byKey(const Key('nav-0')));
        expect(selected.flagsCollection.isButton, isTrue);
        expect(selected.flagsCollection.isSelected, ui.Tristate.isTrue);
        expect(selected.getSemanticsData().label, 'Заказ');
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
        expect(transitions, isEmpty);
        expect(find.byKey(const Key('nav-0')), findsNothing);
        await tester.tap(opener);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('nav-2')));
        await tester.pumpAndSettle();
        expect(transitions, [2]);
        expect(
          tester.getSemantics(opener).getSemanticsData().label,
          contains('Текущий раздел: Профиль'),
        );
        await tester.tap(opener);
        await tester.pumpAndSettle();
        expect(
          tester
              .getSemantics(find.byKey(const Key('nav-2')))
              .flagsCollection
              .isSelected,
          ui.Tristate.isTrue,
        );
        await tester.tap(find.byKey(const Key('nav-2')));
        await tester.pumpAndSettle();
        expect(transitions, [2]);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );
}
