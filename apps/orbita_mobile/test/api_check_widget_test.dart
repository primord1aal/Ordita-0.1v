import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/backend/api_probe.dart';
import 'package:orbita_mobile/src/screens/api_check_screen.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'responsive_test.dart' show checkHorizontalBounds;
import 'test_helpers.dart';

class FakeApiProbe implements ApiProbe {
  @override
  bool configured = true;
  int calls = 0;
  bool disposed = false;
  Completer<ProbeResult>? pending;
  @override
  Future<ProbeResult> check() async {
    calls++;
    return pending?.future ??
        ProbeResult(
          state: ProbeState.ready,
          elapsed: const Duration(milliseconds: 100),
          checkedAt: DateTime(2026, 1, 1),
          httpStatus: 200,
        );
  }

  @override
  void dispose() => disposed = true;
}

Future<void> open(WidgetTester tester, FakeApiProbe probe) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: orbitaTheme(),
      home: ApiCheckScreen(probe: probe),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('Нет автоматических запросов, сначала выбирается сеть', (
    tester,
  ) async {
    final probe = FakeApiProbe();
    await open(tester, probe);
    expect(probe.calls, 0);
    final action = find.descendant(
      of: find.byKey(const Key('check-api')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    await tester.tap(find.text('Wi-Fi'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('check-api')));
    await tester.tap(find.byKey(const Key('check-api')));
    await tester.pumpAndSettle();
    expect(probe.calls, 1);
    expect(find.text('HTTP 200 · 100 мс'), findsOneWidget);
  });

  testWidgets('Без конфигурации кнопка заблокирована', (tester) async {
    final probe = FakeApiProbe()..configured = false;
    await open(tester, probe);
    await tester.tap(find.text('Wi-Fi'));
    await tester.pumpAndSettle();
    final action = find.descendant(
      of: find.byKey(const Key('check-api')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    expect(probe.calls, 0);
  });

  testWidgets('Уход со страницы закрывает запрос, поздний ответ не ломает UI', (
    tester,
  ) async {
    final probe = FakeApiProbe()..pending = Completer<ProbeResult>();
    await open(tester, probe);
    await tester.tap(find.text('Wi-Fi'));
    await tester.pumpAndSettle();
    await scrollTo(tester, find.byKey(const Key('check-api')));
    await tester.tap(find.byKey(const Key('check-api')));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    expect(probe.disposed, isTrue);
    probe.pending!.complete(
      ProbeResult(
        state: ProbeState.timeout,
        elapsed: Duration.zero,
        checkedAt: DateTime(2026),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('Проверка API: малый экран и масштаб $scale', (tester) async {
      setViewport(tester, const Size(320, 568), scale);
      final probe = FakeApiProbe();
      await open(tester, probe);
      checkHorizontalBounds(tester);
      await scrollTo(tester, find.text('Мобильная сеть'));
      checkHorizontalBounds(tester);
      await tester.tap(find.text('Мобильная сеть'));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('check-api')));
      checkHorizontalBounds(tester);
      await tester.tap(find.byKey(const Key('check-api')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.text('HTTP 200 · 100 мс'));
      checkHorizontalBounds(tester);
    });
  }
}
