import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/ui/shift_control.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

void main() {
  Future<void> mount(WidgetTester tester, Widget child) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: orbitaTheme(brightness: Brightness.light),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(18),
            child: Align(alignment: Alignment.topCenter, child: child),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> slide(
    WidgetTester tester,
    double proportion, {
    bool cancel = false,
  }) async {
    final thumb = tester.getCenter(find.byKey(const Key('shift-thumb')));
    final travel =
        tester.getSize(find.byKey(const Key('shift-track'))).width - 64;
    final gesture = await tester.startGesture(thumb);
    await gesture.moveBy(Offset(travel * proportion, 0));
    await tester.pump();
    if (cancel) {
      await gesture.cancel();
    } else {
      await gesture.up();
    }
    await tester.pump();
  }

  testWidgets('Рабочая линия отключена до серверного подключения', (
    tester,
  ) async {
    var calls = 0;
    await mount(
      tester,
      ShiftControl(
        requestChange: (_) async {
          calls++;
        },
      ),
    );
    await slide(tester, 1);
    expect(calls, 0);
    expect(find.text('Линия не подключена'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Жест вне бегунка, короткий и отменённый жест не подтверждаются',
    (tester) async {
      var calls = 0;
      await mount(
        tester,
        ShiftControl(
          available: true,
          requestChange: (_) async {
            calls++;
          },
        ),
      );
      final track = tester.getRect(find.byKey(const Key('shift-track')));
      await tester.dragFrom(track.center, const Offset(150, 0));
      await tester.pump();
      expect(calls, 0, reason: 'Жест должен начинаться только на бегунке');
      await slide(tester, 0.85);
      expect(calls, 0, reason: '85% меньше порога подтверждения');
      await slide(tester, 0.95, cancel: true);
      expect(calls, 0);
      expect(
        tester.getTopLeft(find.byKey(const Key('shift-thumb'))).dx,
        closeTo(track.left + 9, 1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('86% запрашивают подтверждение один раз, состояние ждёт ответ', (
    tester,
  ) async {
    var calls = 0;
    var online = false;
    final pending = Completer<void>();
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return ShiftControl(
            available: true,
            confirmedOnline: online,
            requestChange: (target) async {
              calls++;
              await pending.future;
              update(() => online = target);
            },
          );
        },
      ),
    );
    await slide(tester, 0.87);
    expect(calls, 1);
    expect(online, isFalse);
    expect(find.text('Подтверждаем…'), findsOneWidget);
    await slide(tester, -1);
    expect(calls, 1);
    pending.complete();
    await tester.pumpAndSettle();
    expect(online, isTrue);
    expect(find.text('На линии'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Подтверждённая линия выключается только жестом влево', (
    tester,
  ) async {
    final values = <bool>[];
    await mount(
      tester,
      ShiftControl(
        available: true,
        confirmedOnline: true,
        requestChange: (target) async {
          values.add(target);
        },
      ),
    );
    await slide(tester, 1);
    expect(values, isEmpty);
    await slide(tester, -0.9);
    await tester.pumpAndSettle();
    expect(values, [false]);
    // Виджет не присваивает себе неподтверждённый статус.
    expect(find.text('На линии'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Ошибка возвращает бегунок в прежнее положение', (tester) async {
    await mount(
      tester,
      ShiftControl(
        available: true,
        requestChange: (_) async {
          throw StateError('artificial');
        },
      ),
    );
    final track = tester.getRect(find.byKey(const Key('shift-track')));
    await slide(tester, 0.9);
    await tester.pumpAndSettle();
    expect(find.text('Не на линии'), findsOneWidget);
    expect(
      find.text('Не удалось изменить статус. Попробуй ещё раз.'),
      findsOneWidget,
    );
    expect(
      tester.getTopLeft(find.byKey(const Key('shift-thumb'))).dx,
      closeTo(track.left + 10, 1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Отзыв доступности игнорирует позднюю ошибку', (tester) async {
    final pending = Completer<void>();
    var available = true;
    late StateSetter update;
    await mount(
      tester,
      StatefulBuilder(
        builder: (context, setState) {
          update = setState;
          return ShiftControl(
            available: available,
            requestChange: (_) => pending.future,
          );
        },
      ),
    );
    await slide(tester, 0.9);
    update(() => available = false);
    await tester.pump();
    pending.completeError(StateError('late artificial response'));
    await tester.pumpAndSettle();
    expect(find.text('Линия не подключена'), findsOneWidget);
    expect(
      find.text('Не удалось изменить статус. Попробуй ещё раз.'),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Уничтоженный ползунок не принимает поздний ответ', (
    tester,
  ) async {
    final pending = Completer<void>();
    await mount(
      tester,
      ShiftControl(available: true, requestChange: (_) => pending.future),
    );
    await slide(tester, 0.9);
    await tester.pumpWidget(const SizedBox());
    pending.completeError(StateError('late artificial response'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Клавиатура и TalkBack имеют доступное действие и видимый фокус',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final values = <bool>[];
        await mount(
          tester,
          ShiftControl(
            available: true,
            requestChange: (target) async {
              values.add(target);
            },
          ),
        );
        final data = tester
            .getSemantics(find.byKey(const Key('shift-control')))
            .getSemanticsData();
        expect(data.hasAction(ui.SemanticsAction.tap), isTrue);
        expect(data.hasAction(ui.SemanticsAction.increase), isTrue);
        expect(data.label, contains('Не на линии'));
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        final border =
            (tester
                            .widget<Container>(
                              find.byKey(const Key('shift-track')),
                            )
                            .decoration!
                        as BoxDecoration)
                    .border!
                as Border;
        expect(border.top.width, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(values, [true]);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets('Крупный текст на узком экране переносится без overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 3.2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await mount(
      tester,
      ShiftControl(available: true, requestChange: (_) async {}),
    );
    expect(
      tester.getSize(find.byKey(const Key('shift-track'))).height,
      greaterThan(64),
    );
    expect(tester.takeException(), isNull);
  });
}
