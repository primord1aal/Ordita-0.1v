import 'dart:ui' as ui;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';
import 'package:orbita_mobile/src/screens/preview_screens.dart';
import 'package:orbita_mobile/src/ui/theme.dart';
import 'package:orbita_mobile/src/ui/adaptive_navigation.dart';

import 'fake_device.dart';
import 'test_helpers.dart';
import 'design_test_fonts.dart';

void checkHorizontalBounds(WidgetTester tester) {
  final viewport =
      Offset.zero & (tester.view.physicalSize / tester.view.devicePixelRatio);
  for (final element in find.byType(RichText).evaluate()) {
    final render = element.renderObject;
    if (render is! RenderParagraph || !render.hasSize || render.size.isEmpty) {
      continue;
    }
    final rect = render.localToGlobal(Offset.zero) & render.size;
    if (!rect.overlaps(viewport)) continue;
    expect(
      rect.left,
      greaterThanOrEqualTo(-0.5),
      reason: render.text.toPlainText(),
    );
    expect(
      rect.right,
      lessThanOrEqualTo(viewport.width + 0.5),
      reason: render.text.toPlainText(),
    );
    // Пробел на переносе может иметь selection-box за краем строки,
    // хотя видимые буквы не обрезаны. Проверяем каждый непробельный фрагмент.
    // CSS бренда использует отрицательный tracking: selection-box включает
    // половину межбуквенного интервала перед первой/после последней буквы.
    // Границы самого параграфа проверены выше относительно viewport.
    final tracking = render.text.style?.letterSpacing ?? 0;
    final selectionInset = math.max(
      .5,
      -tracking * MediaQuery.textScalerOf(element).scale(1) / 2 + .01,
    );
    for (final word in RegExp(r'\S+').allMatches(render.text.toPlainText())) {
      for (final box in render.getBoxesForSelection(
        TextSelection(baseOffset: word.start, extentOffset: word.end),
      )) {
        expect(
          box.left,
          greaterThanOrEqualTo(-selectionInset),
          reason: render.text.toPlainText(),
        );
        expect(
          box.right,
          lessThanOrEqualTo(render.size.width + selectionInset),
          reason: render.text.toPlainText(),
        );
      }
    }
  }
  expect(tester.takeException(), isNull);
}

Future<void> checkNavigation(WidgetTester tester) async {
  final view = tester.view.physicalSize / tester.view.devicePixelRatio;
  final compact = find
      .byKey(const Key('navigation-compact'))
      .evaluate()
      .isNotEmpty;
  final vertical = find
      .byKey(const Key('navigation-vertical'))
      .evaluate()
      .isNotEmpty;
  if (vertical) {
    final nav = tester.widget<AdaptiveNavigation>(
      find.byType(AdaptiveNavigation),
    );
    final context = tester.element(find.byType(AdaptiveNavigation));
    final media = MediaQuery.of(context);
    final availableHeight =
        nav.availableHeight ??
        (media.size.height - media.padding.vertical - media.viewInsets.bottom);
    expect(
      tester.getSize(find.byKey(const Key('navigation-vertical'))).height,
      lessThanOrEqualTo(availableHeight * 0.20 + 0.5),
    );
  }
  if (compact) {
    final menu = tester.getRect(find.byKey(const Key('nav-sections')));
    expect(menu.width, greaterThanOrEqualTo(48));
    expect(menu.height, greaterThanOrEqualTo(48));
    expect(menu.bottom, lessThanOrEqualTo(view.height));
    await tester.tap(find.byKey(const Key('nav-sections')));
    await tester.pumpAndSettle();
  }
  final rects = [
    for (var i = 0; i < 3; i++) tester.getRect(find.byKey(Key('nav-$i'))),
  ];
  for (final rect in rects) {
    expect(rect.width, greaterThanOrEqualTo(48));
    expect(rect.height, greaterThanOrEqualTo(48));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(view.width));
    expect(rect.bottom, lessThanOrEqualTo(view.height));
  }
  if (!compact && !vertical) {
    expect(rects[0].right, lessThanOrEqualTo(rects[1].left));
    expect(rects[1].right, lessThanOrEqualTo(rects[2].left));
  } else {
    expect(rects[0].bottom, lessThanOrEqualTo(rects[1].top));
    expect(rects[1].bottom, lessThanOrEqualTo(rects[2].top));
  }
  if (compact) {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('nav-sections')), findsOneWidget);
  }
  expect(tester.takeException(), isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);
  final viewports = [
    const Size(320, 568),
    const Size(360, 640),
    const Size(390, 844),
    const Size(412, 915),
  ];
  final cases = <(Size, double)>[
    for (final size in viewports)
      for (final scale in [1.0, 1.5, 2.0, 2.5, 3.2]) (size, scale),
    for (final scale in [1.0, 2.0, 3.2]) (const Size(640, 360), scale),
  ];
  for (final (size, scale) in cases) {
    testWidgets('Адаптивность ${size.width}x${size.height}, шрифт $scale', (
      tester,
    ) async {
      setViewport(tester, size, scale);
      final device = FakeDevice()..state = readyState();
      await openPreview(tester, 'Водитель', device: device);
      expect(
        MediaQuery.textScalerOf(tester.element(find.text('орбита.'))).scale(16),
        closeTo(16 * scale, 0.01),
      );
      await checkNavigation(tester);
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('current-order')));
      checkHorizontalBounds(tester);
      await openCheck(tester, 'Проверка устройства');
      for (final key in [
        'notifications-card',
        'location-card',
        'service-card',
      ]) {
        await scrollTo(tester, find.byKey(Key(key)));
        checkHorizontalBounds(tester);
      }
      await scrollTo(tester, find.byKey(const Key('start-diagnostic')));
      checkHorizontalBounds(tester);
      await tester.pumpWidget(const SizedBox());
      await openPreview(tester, 'Пассажир');
      await checkNavigation(tester);
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('create-order')));
      await checkNavigation(tester);
      checkHorizontalBounds(tester);
      await tester.pumpWidget(const SizedBox());
    });
  }

  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('Отказ разрешений и отдельные шаги при масштабе $scale', (
      tester,
    ) async {
      setViewport(tester, const Size(320, 568), scale);
      final device = FakeDevice()..state = const DeviceState(sdk: 34);
      await openPreview(tester, 'Водитель', device: device);
      await openCheck(tester, 'Проверка устройства');
      await scrollTo(tester, find.byKey(const Key('notification-permission')));
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('location-permissions')));
      await tester.tap(find.byKey(const Key('location-permissions')));
      await tester.pumpAndSettle();
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('foreground-permission')));
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.byKey(const Key('background-permission')));
      checkHorizontalBounds(tester);
      expect(
        tester
            .widget<OutlinedButton>(
              find.descendant(
                of: find.byKey(const Key('background-permission')),
                matching: find.byType(OutlinedButton),
              ),
            )
            .onPressed,
        isNull,
      );
      expect(device.calls, isNot(contains('background')));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('Клавиатура и адреса при масштабе $scale', (tester) async {
      setViewport(tester, const Size(360, 720), scale);
      await openPreview(tester, 'Пассажир');
      await scrollTo(tester, find.byKey(const Key('destination')));
      await tester.showKeyboard(find.byKey(const Key('destination')));
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('destination')),
        'Учебная улица, длинное название пункта назначения',
      );
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('destination')));
      checkHorizontalBounds(tester);
      expect(find.byKey(const Key('nav-0')), findsNothing);
      await scrollTo(tester, find.byKey(const Key('create-order')));
      expect(
        tester.getRect(find.byKey(const Key('create-order'))).bottom,
        lessThanOrEqualTo(440.5),
      );
      tester.view.resetViewInsets();
      tester.testTextInput.hide();
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await checkNavigation(tester);
    });
  }

  testWidgets(
    'TalkBack: подписанные цели, выбранная вкладка, недоступная линия',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await openPreview(tester, 'Водитель');
        final nav = tester.getSemantics(find.byKey(const Key('nav-0')));
        expect(nav.flagsCollection.isButton, isTrue);
        expect(nav.flagsCollection.isSelected, ui.Tristate.isTrue);
        expect(nav.getSemanticsData().label, 'Линия');
        final shift = tester.getSemantics(
          find.byKey(const Key('shift-control')),
        );
        expect(shift.flagsCollection.isEnabled, ui.Tristate.isFalse);
        expect(shift.getSemanticsData().label, contains('Не на линии'));
        expect(
          shift.getSemanticsData().hasAction(ui.SemanticsAction.tap),
          isFalse,
        );
        expect(
          tester.getSize(find.byKey(const Key('shift-control'))).height,
          greaterThanOrEqualTo(48),
        );
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('Будущая карточка заказа сохраняет длинные адреса и действие', (
    tester,
  ) async {
    setViewport(tester, const Size(320, 640), 3.2);
    await tester.pumpWidget(
      MaterialApp(
        theme: orbitaTheme(),
        home: const Scaffold(
          body: SafeArea(
            child: SingleChildScrollView(
              padding: EdgeInsets.all(16),
              child: CurrentOrderCard(
                pickup: 'Учебное название улицы и дополнительное описание точки подачи',
                destination: 'Учебный адрес назначения с длинным названием',
                status: 'Водитель прибыл',
                actionLabel: 'Начать поездку',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    checkHorizontalBounds(tester);
    await scrollTo(tester, find.text('Начать поездку'));
    checkHorizontalBounds(tester);
    expect(find.textContaining('Учебный адрес назначения'), findsOneWidget);
  });
}
