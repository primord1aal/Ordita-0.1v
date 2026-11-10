enum AddressField { pickup, destination }

class GeoPoint {
  const GeoPoint(this.latitude, this.longitude);
  final double latitude, longitude;
  bool get valid =>
      latitude.isFinite &&
      longitude.isFinite &&
      latitude.abs() <= 85.05112878 &&
      longitude.abs() <= 180;
  String get caption =>
      '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)}';
}

// Начальный обзор окрестностей Чика, не текущая позиция пассажира и не зона обслуживания.
const localMapCenter = GeoPoint(55.0, 82.43);

class AddressPlace {
  const AddressPlace(this.label, this.point);
  final String label;
  final GeoPoint point;
}

enum MapFailureKind {
  configuration,
  network,
  timeout,
  unavailable,
  limit,
  invalid,
  cancelled,
  storage,
}

class MapFailure implements Exception {
  const MapFailure(this.kind);
  final MapFailureKind kind;
  String get message => switch (kind) {
    MapFailureKind.configuration =>
      'Карты пока не настроены или ключ недействителен.',
    MapFailureKind.network =>
      'Нет связи с картографическим сервисом. Адрес можно ввести вручную.',
    MapFailureKind.timeout =>
      'Картографический сервис не ответил. Попробуйте ещё раз.',
    MapFailureKind.limit =>
      'Сервис карт временно ограничил запросы. Попробуйте позже.',
    MapFailureKind.invalid || MapFailureKind.unavailable => 'Не удалось получить адрес. Можно выбрать точку или ввести адрес вручную.',
    MapFailureKind.cancelled => 'Запрос отменён.',
    MapFailureKind.storage =>
      'Не удалось сохранить настройку в защищённом хранилище.',
  };
  // Ни URI с ключом, ни ответ поставщика не входят в исключение.
  @override
  String toString() => 'MapFailure(${kind.name})';
}
