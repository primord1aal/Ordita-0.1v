import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/orders/trip_history.dart';
import 'package:orbita_mobile/src/screens/trip_history_screen.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

class _HistoryApi implements TripHistoryApi {
  final calls = <Completer<Object?>>[];

  @override
  Future<Object?> loadTripHistory({required bool driver, HistoryTrip? before}) {
    expect(driver, isTrue);
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
  testWidgets(
    'История загружается при открытии, обновляется и отбрасывает чужой ответ',
    (tester) async {
      final api = _HistoryApi();

      Future<void> show({bool active = true, bool terminal = false}) =>
          tester.pumpWidget(
            MaterialApp(
              theme: orbitaTheme(),
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

      await show(terminal: true);
      expect(api.calls, hasLength(2));
      await show(active: false, terminal: true);
      api.calls.last.complete(_page());
      await tester.pump();
      expect(find.text('Свой заказ'), findsNothing);

      await show(terminal: true);
      expect(api.calls, hasLength(3));
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
