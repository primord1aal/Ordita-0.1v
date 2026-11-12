import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:orbita_mobile/src/app.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/screens/passenger_screen.dart';
import 'package:orbita_mobile/src/ui/adaptive_navigation.dart';

import 'fake_auth_repository.dart';
import 'fake_device.dart';
import 'maps_test_fakes.dart';
import 'test_helpers.dart';

void main() {
  Future<void> mount(
    WidgetTester tester,
    FakeAddressService addresses,
    FakeRouteService routes,
  ) async {
    final settings = MapSettings(initialKey: fakeMapKey);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox());
      settings.dispose();
    });
    await tester.pumpWidget(
      OrbitaApp(
        device: FakeDevice(),
        authRepository: FakeAuthRepository()..saved = testSession(),
        mapSettings: settings,
        addressServiceFactory: (_) => addresses,
        routeServiceFactory: (_) => routes,
        tileSessionFactory: (_) => FakeMapTiles(),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Tecno: карта неподвижна, оба поля выше меню и клавиатуры', (
    tester,
  ) async {
    setViewport(tester, const Size(360, 800), 1.3);
    await mount(tester, FakeAddressService(), FakeRouteService());
    final map = find.byKey(const Key('passenger-map'));
    final before = tester.getRect(map);
    final nav = tester.getRect(find.byType(AdaptiveNavigation));
    final pickup = find.byKey(const Key('pickup'));
    final destination = find.byKey(const Key('destination'));
    expect(tester.getRect(pickup).top, greaterThan(before.top));
    expect(tester.getRect(destination).bottom, lessThanOrEqualTo(nav.top));
    await tester.tap(destination);
    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();
    expect(tester.getRect(map), before);
    expect(tester.getRect(destination).bottom, lessThanOrEqualTo(500));
    expect(tester.getRect(destination).top, greaterThanOrEqualTo(0));
    expect(find.byTooltip('Свернуть поиск'), findsOneWidget);
    tester.view.resetViewInsets();
    await tester.tap(find.byTooltip('Свернуть поиск'));
    await tester.pumpAndSettle();
    expect(tester.getRect(map), before);
    expect(tester.getRect(destination).bottom, lessThanOrEqualTo(nav.top));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Два адреса строят один дорожный маршрут, редактирование убирает его',
    (tester) async {
      setViewport(tester, const Size(360, 800), 1);
      final addresses = FakeAddressService();
      final routes = FakeRouteService();
      await mount(tester, addresses, routes);
      Future<void> select(String key, AddressPlace place) async {
        addresses.results = [place];
        await tester.enterText(find.byKey(Key(key)), 'Чик, ${place.label}');
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pumpAndSettle();
        await scrollTo(tester, find.text(place.label));
        await tester.tap(find.text(place.label));
        await tester.pumpAndSettle();
      }

      await select(
        'pickup',
        const AddressPlace('Чик, Комсомольская улица, 19', GeoPoint(55, 82.43)),
      );
      await select(
        'destination',
        const AddressPlace(
          'Прокудское, улица Ленина, 5',
          GeoPoint(55.025, 82.46),
        ),
      );
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      expect(routes.calls, hasLength(1));
      expect(find.byKey(const Key('road-route')), findsOneWidget);
      expect(
        tester
            .widget<PolylineLayer>(find.byKey(const Key('road-route')))
            .polylines
            .single
            .points,
        hasLength(3),
      );
      expect(find.byKey(const Key('route-summary')), findsOneWidget);
      final navTop = tester.getTopLeft(find.byType(AdaptiveNavigation)).dy;
      expect(
        tester.getBottomLeft(find.byKey(const Key('create-order'))).dy,
        lessThanOrEqualTo(navTop),
      );
      final map = tester.widget<FlutterMap>(find.byType(FlutterMap));
      final camera = map.mapController!.camera;
      final panelTop = tester
          .getTopLeft(find.byKey(const Key('passenger-scroll')))
          .dy;
      final mapTop = tester.getTopLeft(find.byType(FlutterMap)).dy;
      for (final point
          in tester
              .widget<PolylineLayer>(find.byKey(const Key('road-route')))
              .polylines
              .single
              .points) {
        final offset = camera.latLngToScreenOffset(point);
        expect(offset.dx, inInclusiveRange(0, 360));
        expect(offset.dy, inInclusiveRange(0, panelTop - mapTop));
      }
      await tester.enterText(
        find.byKey(const Key('destination')),
        'Изменённый адрес',
      );
      await tester.pump();
      expect(find.byKey(const Key('road-route')), findsNothing);
      expect(find.byType(PassengerScreen), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
