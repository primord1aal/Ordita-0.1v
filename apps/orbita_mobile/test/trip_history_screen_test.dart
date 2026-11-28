import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:orbita_mobile/src/orders/trip_history.dart';
import 'package:orbita_mobile/src/screens/trip_history_screen.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'design_test_fonts.dart';
import 'test_helpers.dart';

class _HistoryApi implements TripHistoryApi {
  final calls = <Completer<Object?>>[];
  final filters = <String?>[];

  @override
  Future<Object?> loadTripHistory({
    required bool driver,
    HistoryTrip? before,
    String? status,
  }) {
    expect(driver, isTrue);
    filters.add(status);
    final call = Completer<Object?>();
    calls.add(call);
    return call.future;
  }
}

const _account = '00000000-0000-4000-8000-000000000001';
const _trip = '00000000-0000-4000-8000-000000000002';

Map<String, dynamic> _page({String user = _account}) => {
  'contract_version': 1,
  'user_id': user,
  'role': 'driver',
  'items': [
    {
      'id': _trip,
      'status': 'completed',
      'created_at': '2026-11-28T05:00:00Z',
      'finished_at': '2026-11-28T05:05:00Z',
      'pickup_address': 'Свой заказ',
      'destination_address': 'Пункт назначения',
    },
  ],
  'has_more': false,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadDesignTestFonts);
  testWidgets(
    'История загружается при открытии, обновляется и отбрасывает чужой ответ',
    (tester) async {
      final api = _HistoryApi();
      setViewport(tester, const Size(390, 844), 1);

      Future<void> show({bool active = true, bool terminal = false}) =>
          tester.pumpWidget(
            MaterialApp(
              theme: orbitaTheme(),
              locale: const Locale("ru"),
              supportedLocales: const [Locale("ru")],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              home: Scaffold(
                body: HistoryScreen(
                  api: api,
                  userId: _account,
                  driver: true,
                  active: active,
                  lastTerminal: terminal ? (_trip, 5, 'completed') : null,
                ),
              ),
            ),
          );

      await show(active: false);
      expect(api.calls, isEmpty);
      await show();
      api.calls.single.complete(_page());
      await tester.pump();
      expect(find.text('Свой заказ'), findsOneWidget);
      if (captureDesignGoldens) {
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('goldens/glass-history.png'),
        );
      }
      await tester.tap(find.text('Свой заказ'));
      await tester.pumpAndSettle();
      expect(find.text('Детали поездки'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.text('Отменённые'));
      await tester.pump();
      expect(api.filters.last, 'cancelled');
      api.calls.last.complete({..._page(), 'items': <Object>[]});
      await tester.pump();
      expect(find.text('Пока нет поездок.'), findsOneWidget);

      await show(terminal: true);
      expect(api.calls, hasLength(3));
      await show(active: false, terminal: true);
      api.calls.last.complete(_page());
      await tester.pump();
      expect(find.text('Свой заказ'), findsNothing);

      await show(terminal: true);
      expect(api.calls, hasLength(4));
      api.calls.last.complete(_page(user: 'foreign-user'));
      await tester.pump();
      expect(
        find.text('Не удалось загрузить историю поездок.'),
        findsOneWidget,
      );
      expect(find.text('Свой заказ'), findsNothing);
    },
  );
}
