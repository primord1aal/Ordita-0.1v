import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/orders/dispatch_controller.dart';
import 'package:orbita_mobile/src/orders/trip_location.dart';
import 'package:orbita_mobile/src/orders/trip_people.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';
import 'package:orbita_mobile/src/ui/orbita_map.dart';
import 'package:orbita_mobile/src/ui/theme.dart';

import 'dispatch_controller_test.dart'
    show FakeApi, destination, envelope, passenger, pickup, trip;
import 'maps_test_fakes.dart';

class _Api extends FakeApi implements TripLocationApi, TripPeopleApi {
  final locationCalls = <(String, Completer<Object?>)>[];

  @override
  Future<Object?> loadTripPeer(String orderId) async => {
    'order_id': orderId,
    'display_name': 'Водитель из тестового API',
    'vehicle': {
      'make': 'Тестовая марка',
      'model': 'Модель',
      'color': 'Серый',
      'plate': 'A 123 BB',
    },
  };

  @override
  Future<Object?> loadOwnVehicle() async => null;

  @override
  Future<Object?> exchangeTripLocation(
    String orderId, {
    DeviceLocationFix? fix,
  }) {
    expect(fix, isNull);
    final call = Completer<Object?>();
    locationCalls.add((orderId, call));
    return call.future;
  }
}

void main() {
  testWidgets(
    'Пассажир видит только позицию активного заказа и отдельный дорожный участок',
    (tester) async {
      final intent = {
        'request_id': '00000000-0000-4000-8000-000000000004',
        'pickup': {'address': pickup.label, 'latitude': 55, 'longitude': 82.43},
        'destination': {
          'address': destination.label,
          'latitude': 55.01,
          'longitude': 82.44,
        },
      };
      var status = 'to_pickup';
      final api = _Api()
        ..handler = (_, _) async =>
            envelope(order: trip(intent, status: status));
      final controller = DispatchController(
        api: api,
        userId: passenger,
        driver: false,
      )..setEnabled(true);
      final maps = MapSettings(initialKey: fakeMapKey);
      final roads = FakeRouteService();
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        controller.dispose();
        maps.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          theme: orbitaTheme(),
          home: Scaffold(
            body: PassengerScreen(
              dispatch: controller,
              mapSettings: maps,
              routeServiceFactory: (_) => roads,
              tileSessionFactory: (_) => FakeMapTiles(),
            ),
          ),
        ),
      );
      await tester.pump();
      final (id, initial) = api.locationCalls.single;
      initial.complete({
        'order_id': id,
        'fix': {'latitude': 55.003, 'longitude': 82.431, 'age_seconds': 1},
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      OrbitaMap map() => tester.widget(find.byKey(const Key('passenger-map')));
      expect(map().vehiclePosition?.latitude, 55.003);
      expect(map().approachRoute, isNotNull);
      expect(find.text('Водитель из тестового API'), findsOneWidget);
      expect(find.text('Серый · Тестовая марка Модель'), findsOneWidget);
      expect(find.text('A 123 BB'), findsOneWidget);
      expect(roads.calls.last.$2.latitude, pickup.point.latitude);

      status = 'riding';
      await controller.refresh();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(map().approachRoute, isNull);
      expect(roads.calls.last.$2.latitude, destination.point.latitude);
      expect(find.textContaining('До назначения ·'), findsOneWidget);

      await tester.pump(const Duration(seconds: 5));
      expect(api.locationCalls, hasLength(2));
      status = 'completed';
      await controller.refresh();
      api.locationCalls.last.$2.complete({
        'order_id': id,
        'fix': {'latitude': 55.003, 'longitude': 82.431, 'age_seconds': 1},
      });
      await tester.pumpAndSettle();
      expect(map().vehiclePosition, isNull);
      expect(find.text('A 123 BB'), findsNothing);
      expect(map().route, isNull);
      controller.setEnabled(false);
    },
  );
}
