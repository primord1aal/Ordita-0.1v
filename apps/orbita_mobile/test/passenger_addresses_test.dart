import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/passenger_address_controller.dart';

import 'maps_test_fakes.dart';

void main() {
  late MapSettings settings;
  late FakeAddressService service;
  late PassengerAddressController controller;
  setUp(() {
    settings = MapSettings(initialKey: fakeMapKey);
    service = FakeAddressService();
    controller = PassengerAddressController(
      settings,
      serviceFactory: (_) => service,
    );
  });
  tearDown(() {
    controller.dispose();
    settings.dispose();
  });

  testWidgets('Подсказки ждут окончания ввода и трёх символов', (tester) async {
    controller.edit(AddressField.pickup, 'Чи');
    await tester.pump(const Duration(seconds: 1));
    expect(service.queries, isEmpty);
    controller.edit(AddressField.pickup, 'Чик');
    await tester.pump(const Duration(milliseconds: 300));
    controller.edit(AddressField.pickup, 'Чик, улица');
    await tester.pump(const Duration(milliseconds: 499));
    expect(service.queries, isEmpty);
    await tester.pump(const Duration(milliseconds: 1));
    expect(service.queries, ['Чик, улица']);
    expect(controller.pickup.suggestions.single, examplePlace);
  });
  test('Старый ответ не подменяет адрес другого поля', () async {
    final pending = Completer<List<AddressPlace>>();
    service.pending = pending;
    controller.edit(AddressField.pickup, 'Старый адрес');
    final old = controller.searchNow(AddressField.pickup);
    controller.edit(AddressField.destination, 'Новый адрес');
    service.pending = null;
    await controller.searchNow(AddressField.destination);
    pending.complete([
      const AddressPlace('Устаревшая подсказка', GeoPoint(55.0, 82.4)),
    ]);
    await old;
    expect(controller.pickup.suggestions, isEmpty);
    expect(controller.destination.suggestions.single, examplePlace);
  });
  test('Выбор подсказки сохраняет настоящие координаты; редактирование их сбрасывает', () {
    controller.select(AddressField.pickup, examplePlace);
    expect(controller.pickup.text, examplePlace.label);
    expect(controller.pickup.place!.point, examplePlace.point);
    controller.edit(AddressField.pickup, '${examplePlace.label}а');
    expect(controller.pickup.place, isNull);
    expect(controller.destination.text, isEmpty);
  });
  test(
    'Обратный поиск не переносит выбранную точку на соседний адрес',
    () async {
      const point = GeoPoint(55.008, 82.445);
      await controller.choosePoint(AddressField.destination, point);
      expect(controller.destination.text, service.reverseLabel);
      expect(controller.destination.place!.point, point);
      expect(controller.pickup.place, isNull);
    },
  );
  test('Сбой обратного поиска сохраняет точку, не выдумывает адрес', () async {
    service.failure = const MapFailure(MapFailureKind.network);
    await controller.choosePoint(AddressField.pickup, examplePlace.point);
    expect(controller.pickup.place!.point, examplePlace.point);
    expect(controller.pickup.text, 'Точка на карте');
    expect(controller.pickup.message, contains('Выбранная точка сохранена'));
  });
  test(
    'Закрытый доступ отменяет запрос, поздний ответ не попадает в черновик',
    () async {
      final pending = Completer<List<AddressPlace>>();
      service.pending = pending;
      controller.edit(AddressField.pickup, 'Проверочный адрес');
      final result = controller.searchNow(AddressField.pickup);
      controller.setEnabled(false);
      pending.complete([examplePlace]);
      await result;
      expect(controller.pickup.busy, isFalse);
      expect(controller.pickup.suggestions, isEmpty);
      expect(controller.pickup.text, 'Проверочный адрес');
      controller.select(AddressField.pickup, examplePlace);
      expect(controller.pickup.place, isNull);
      controller.setEnabled(true);
      expect(controller.pickup.text, 'Проверочный адрес');
    },
  );
  test('Точка и адрес не теряются при уходе на другую вкладку', () {
    controller.select(AddressField.pickup, examplePlace);
    controller.setEnabled(false);
    controller.setEnabled(true);
    expect(controller.pickup.place, examplePlace);
    expect(controller.pickup.text, examplePlace.label);
    expect(service.queries, isEmpty);
  });
  testWidgets('Без настройки карты ручной ввод не запускает запросы', (
    tester,
  ) async {
    await settings.clear();
    controller.edit(AddressField.destination, 'Ручной адрес без карты');
    await tester.pump(const Duration(seconds: 2));
    await controller.searchNow(AddressField.destination);
    expect(service.queries, isEmpty);
    expect(controller.destination.text, 'Ручной адрес без карты');
    expect(controller.destination.place, isNull);
  });
  test(
    'Пустой результат и ошибка различимы, повтор запускается только явно',
    () async {
      controller.edit(AddressField.pickup, 'Неизвестный адрес');
      service.results = [];
      await controller.searchNow(AddressField.pickup);
      expect(controller.pickup.message, contains('Адрес не найден'));
      service.failure = const MapFailure(MapFailureKind.limit);
      await controller.searchNow(AddressField.pickup);
      expect(controller.pickup.message, contains('ограничил запросы'));
      expect(service.queries.length, 2);
    },
  );
  test('Смена ключа отменяет прежний запрос, сохраняя ручной текст', () async {
    final pending = Completer<List<AddressPlace>>();
    service.pending = pending;
    controller.edit(AddressField.pickup, 'Черновик');
    final request = controller.searchNow(AddressField.pickup);
    await settings.clear();
    pending.complete([examplePlace]);
    await request;
    expect(controller.pickup.suggestions, isEmpty);
    expect(controller.pickup.text, 'Черновик');
  });
  test('Preview показывает адрес, но Back не изменяет черновик', () async {
    controller.edit(AddressField.pickup, 'Прежний ручной адрес');
    final label = await controller.previewPoint(examplePlace.point);
    expect(label, service.reverseLabel);
    expect(controller.pickup.text, 'Прежний ручной адрес');
    expect(controller.pickup.place, isNull);
    await controller.choosePoint(
      AddressField.pickup,
      examplePlace.point,
      address: label,
    );
    expect(controller.pickup.text, label);
    expect(controller.pickup.place!.point, examplePlace.point);
    expect(service.points, hasLength(1));
  });
  test(
    'Старый reverse preview после новой точки или потери доступа отклоняется',
    () async {
      final pending = Completer<String?>();
      service.reversePending = pending;
      final old = controller.previewPoint(examplePlace.point);
      final rejection = expectLater(old, throwsA(isA<MapFailure>()));
      controller.cancelPointPreview();
      controller.setEnabled(false);
      pending.complete('Устаревший адрес');
      await rejection;
      expect(controller.pickup.place, isNull);
      expect(controller.pickup.text, isEmpty);
    },
  );
}
