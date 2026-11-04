import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/backend/api_probe.dart';
import 'package:orbita_mobile/src/backend/probe_journal.dart';
import 'package:orbita_mobile/src/platform/network_observer.dart';
import 'package:orbita_mobile/src/screens/api_check_screen.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'api_fixtures.dart';
import 'responsive_test.dart' show checkHorizontalBounds;
import 'test_helpers.dart';

Future<void> open(
  WidgetTester tester,
  FakeApiProbe probe,
  FakeNetworkObserver network, {
  ProbeJournal? journal,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: orbitaTheme(),
      home: ApiCheckScreen(probe: probe, network: network, journal: journal),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> choose(WidgetTester tester, String key, String label) async {
  await scrollTo(tester, find.byKey(Key(key)));
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  final action = find.widgetWithText(OutlinedButton, label);
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> conditions(WidgetTester tester, {bool mobile = false}) async {
  await choose(tester, 'expected-network', mobile ? 'Мобильная сеть' : 'Wi-Fi');
  if (mobile) await choose(tester, 'operator', 'Yota');
  await choose(tester, 'dns', 'Автоматически');
  final checkbox = find.descendant(
    of: find.byKey(const Key('conditions-confirmed')),
    matching: find.byType(Checkbox),
  );
  await tester.ensureVisible(checkbox);
  await tester.pumpAndSettle();
  await tester.tap(checkbox);
  await tester.pumpAndSettle();
}

void main() {
  WidgetController.hitTestWarningShouldBeFatal = true;
  testWidgets('Снимок Android не вызывает HTTP, условия проверяются отдельно', (
    tester,
  ) async {
    final probe = FakeApiProbe();
    final network = FakeNetworkObserver();
    await open(tester, probe, network);
    expect(probe.calls, 0);
    expect(find.text('Активная сеть Android: Wi-Fi'), findsOneWidget);
    await conditions(tester);
    await scrollTo(tester, find.byKey(const Key('check-api')));
    await tester.tap(find.byKey(const Key('check-api')));
    await tester.pumpAndSettle();
    expect(probe.calls, 1);
    expect(find.text('HTTP 200 · 100 мс'), findsOneWidget);
    expect(find.text('Первый запрос процесса Android'), findsOneWidget);
  });

  testWidgets('Без конфигурации HTTP заблокирован', (tester) async {
    final probe = FakeApiProbe()..configured = false;
    await open(tester, probe, FakeNetworkObserver());
    await conditions(tester);
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
    await open(tester, probe, FakeNetworkObserver());
    await conditions(tester);
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
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Буфер содержит только сведения диагностики, серия доступна после возврата',
    (tester) async {
      final journal = ProbeJournal();
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await open(
        tester,
        FakeApiProbe(),
        FakeNetworkObserver(),
        journal: journal,
      );
      await conditions(tester);
      await scrollTo(tester, find.byKey(const Key('check-api')));
      await tester.tap(find.byKey(const Key('check-api')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('copy-result-1')));
      await tester.tap(find.byKey(const Key('copy-result-1')));
      await tester.pumpAndSettle();
      expect(copied, contains('HTTP: 200'));
      expect(copied, contains('Частный DNS (владелец): Автоматически'));
      expect(copied, isNot(contains('apikey')));
      expect(copied, isNot(contains('sb_publishable_')));
      await tester.pumpWidget(const SizedBox());
      await open(
        tester,
        FakeApiProbe(),
        FakeNetworkObserver(),
        journal: journal,
      );
      await scrollTo(tester, find.byKey(const Key('copy-series')));
      await tester.tap(find.byKey(const Key('copy-series')));
      await tester.pumpAndSettle();
      expect(copied, contains('HTTP: 200'));
      expect(journal.records.length, 1);
    },
  );

  testWidgets('Неопределённая сеть требует отдельного ручного подтверждения', (
    tester,
  ) async {
    final probe = FakeApiProbe();
    await open(
      tester,
      probe,
      FakeNetworkObserver()..type = NetworkType.unknown,
    );
    await conditions(tester);
    final action = find.descendant(
      of: find.byKey(const Key('check-api')),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(action).onPressed, isNull);
    await scrollTo(tester, find.byKey(const Key('manual-network')));
    await tester.tap(find.byKey(const Key('manual-network')));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(action).onPressed, isNotNull);
  });

  testWidgets('Нет сети и восстановление отделены от двух приёмочных окон', (
    tester,
  ) async {
    final probe = FakeApiProbe();
    final network = FakeNetworkObserver()..type = NetworkType.none;
    await open(tester, probe, network);
    await conditions(tester);
    await choose(tester, 'test-window', 'Без сети / восстановление');
    await scrollTo(tester, find.byKey(const Key('check-api')));
    await tester.tap(find.byKey(const Key('check-api')));
    await tester.pumpAndSettle();
    expect(probe.calls, 0);
    expect(find.text('Нет сети. Запрос не отправлен.'), findsOneWidget);
    network.type = NetworkType.wifi;
    await scrollTo(tester, find.byKey(const Key('check-api')));
    await tester.tap(find.byKey(const Key('check-api')));
    await tester.pumpAndSettle();
    expect(probe.calls, 1);
    expect(find.text('HTTP 200 · 100 мс'), findsOneWidget);
  });

  for (final scale in [1.0, 2.0, 3.2]) {
    testWidgets('Журнал API: малый экран и масштаб $scale', (tester) async {
      setViewport(tester, const Size(320, 568), scale);
      final probe = FakeApiProbe();
      await open(
        tester,
        probe,
        FakeNetworkObserver()..type = NetworkType.mobile,
      );
      checkHorizontalBounds(tester);
      await conditions(tester, mobile: true);
      await scrollTo(tester, find.byKey(const Key('check-api')));
      checkHorizontalBounds(tester);
      await tester.tap(find.byKey(const Key('check-api')));
      await tester.pumpAndSettle();
      await scrollTo(tester, find.byKey(const Key('copy-result-1')));
      checkHorizontalBounds(tester);
    });
  }
}
