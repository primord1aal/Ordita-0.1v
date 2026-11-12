import '../maps/address_models.dart';

enum OrderFailureKind {
  invalidRequest,
  invalidResponse,
  sessionRequired,
  creationForbidden,
  notFound,
  activeOrderExists,
  idempotencyConflict,
  stateChanged,
  unavailable,
}

/// Ответ сервера и внутренние исключения не попадают в пользовательский текст.
class OrderFailure implements Exception {
  const OrderFailure(this.kind);

  factory OrderFailure.fromServerMessage(Object? message) => OrderFailure(
    switch (message) {
      'ORB_ORDER_INVALID_REQUEST' => OrderFailureKind.invalidRequest,
      'ORB_ORDER_SESSION_REQUIRED' => OrderFailureKind.sessionRequired,
      'ORB_ORDER_CREATE_FORBIDDEN' => OrderFailureKind.creationForbidden,
      'ORB_ORDER_NOT_FOUND' => OrderFailureKind.notFound,
      'ORB_ORDER_ACTIVE_EXISTS' => OrderFailureKind.activeOrderExists,
      'ORB_ORDER_IDEMPOTENCY_CONFLICT' => OrderFailureKind.idempotencyConflict,
      'ORB_ORDER_STATE_CHANGED' => OrderFailureKind.stateChanged,
      _ => OrderFailureKind.unavailable,
    },
  );

  final OrderFailureKind kind;

  String get message => switch (kind) {
    OrderFailureKind.invalidRequest => 'Проверьте адреса заказа.',
    OrderFailureKind.invalidResponse =>
      'Не удалось проверить ответ сервера о заказе. Обновите данные.',
    OrderFailureKind.sessionRequired => 'Войдите заново, чтобы открыть заказ.',
    OrderFailureKind.creationForbidden =>
      'Создание заказа сейчас недоступно для этого аккаунта.',
    OrderFailureKind.notFound => 'Заказ не найден.',
    OrderFailureKind.activeOrderExists =>
      'У вас уже есть текущий заказ. Обновите данные.',
    OrderFailureKind.idempotencyConflict =>
      'Данные отправленного заказа изменились. Обновите данные.',
    OrderFailureKind.stateChanged =>
      'Состояние заказа изменилось. Обновите данные.',
    OrderFailureKind.unavailable =>
      'Не удалось получить данные заказа. Повторите попытку.',
  };

  @override
  String toString() => 'OrderFailure(${kind.name})';
}

class OrderPoint {
  factory OrderPoint({required String address, required GeoPoint point}) {
    final normalized = _normalizeAddress(address);
    if (!_validAddress(normalized) || !_validPoint(point)) {
      throw const OrderFailure(OrderFailureKind.invalidRequest);
    }
    return OrderPoint._(normalized, point);
  }

  const OrderPoint._(this.address, this.point);

  static OrderPoint _fromJson(Object? value) {
    final data = _object(value, const {'address', 'latitude', 'longitude'});
    final address = data['address'];
    final latitude = data['latitude'];
    final longitude = data['longitude'];
    if (address is! String ||
        !_validAddress(address) ||
        address != _normalizeAddress(address) ||
        latitude is! num ||
        longitude is! num) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    final point = GeoPoint(latitude.toDouble(), longitude.toDouble());
    if (!_validPoint(point)) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    return OrderPoint._(address, point);
  }

  final String address;
  final GeoPoint point;

  Map<String, Object> toJson() => {
    'address': address,
    'latitude': point.latitude,
    'longitude': point.longitude,
  };
}

/// Caller supplies the same requestId for every retry of one unchanged intent.
/// Generating and persisting that identifier belongs to the integration layer.
class CreateOrderCommand {
  factory CreateOrderCommand({
    required String requestId,
    required OrderPoint pickup,
    required OrderPoint destination,
  }) {
    final id = _uuid(requestId, OrderFailureKind.invalidRequest);
    if (_samePoint(pickup.point, destination.point)) {
      throw const OrderFailure(OrderFailureKind.invalidRequest);
    }
    return CreateOrderCommand._(id, pickup, destination);
  }

  const CreateOrderCommand._(this.requestId, this.pickup, this.destination);

  final String requestId;
  final OrderPoint pickup;
  final OrderPoint destination;

  Map<String, Object> toRpcParameters() => {
    'p_request_id': requestId,
    'p_pickup': pickup.toJson(),
    'p_destination': destination.toJson(),
  };
}

enum OrderStatus { created, cancelled }

enum OrderCancellationReason { passenger, searchTimeout }

enum OrderOperation { create, getCurrent, get, cancel }

/// Constructed only through the envelope, after matching the actor and request.
class PassengerOrder {
  const PassengerOrder._({
    required this.id,
    required this.passengerId,
    required this.requestId,
    required this.pickup,
    required this.destination,
    required this.status,
    required this.cancellationReason,
    required this.createdAt,
    required this.expiresAt,
    required this.cancelledAt,
    required this.version,
  });

  final String id;
  final String passengerId;
  final String requestId;
  final OrderPoint pickup;
  final OrderPoint destination;
  final OrderStatus status;
  final OrderCancellationReason? cancellationReason;
  final DateTime createdAt;
  final DateTime expiresAt;
  final DateTime? cancelledAt;
  final int version;

  static PassengerOrder _fromJson(
    Object? value, {
    required DateTime serverTime,
    required String expectedUserId,
    required String? expectedRequestId,
    required String? expectedOrderId,
  }) {
    final data = _object(value, const {
      'id',
      'passenger_id',
      'request_id',
      'pickup',
      'destination',
      'status',
      'cancellation_reason',
      'created_at',
      'expires_at',
      'cancelled_at',
      'version',
    });
    final id = _uuid(data['id'], OrderFailureKind.invalidResponse);
    final passengerId = _uuid(
      data['passenger_id'],
      OrderFailureKind.invalidResponse,
    );
    final requestId = _uuid(
      data['request_id'],
      OrderFailureKind.invalidResponse,
    );
    if (passengerId != expectedUserId ||
        (expectedRequestId != null && requestId != expectedRequestId) ||
        (expectedOrderId != null && id != expectedOrderId)) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    final pickup = OrderPoint._fromJson(data['pickup']);
    final destination = OrderPoint._fromJson(data['destination']);
    if (_samePoint(pickup.point, destination.point)) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    final status = switch (data['status']) {
      'created' => OrderStatus.created,
      'cancelled' => OrderStatus.cancelled,
      _ => throw const OrderFailure(OrderFailureKind.invalidResponse),
    };
    final reason = switch (data['cancellation_reason']) {
      null => null,
      'passenger' => OrderCancellationReason.passenger,
      'search_timeout' => OrderCancellationReason.searchTimeout,
      _ => throw const OrderFailure(OrderFailureKind.invalidResponse),
    };
    final createdAt = _utcTime(data['created_at']);
    final expiresAt = _utcTime(data['expires_at']);
    final cancelledAt = data['cancelled_at'] == null
        ? null
        : _utcTime(data['cancelled_at']);
    final version = data['version'];
    if (version is! int ||
        createdAt.isAfter(serverTime) ||
        expiresAt != createdAt.add(const Duration(minutes: 5))) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    if (status == OrderStatus.created) {
      if (version != 1 ||
          reason != null ||
          cancelledAt != null ||
          !serverTime.isBefore(expiresAt)) {
        throw const OrderFailure(OrderFailureKind.invalidResponse);
      }
    } else {
      if (version != 2 ||
          reason == null ||
          cancelledAt == null ||
          cancelledAt.isBefore(createdAt) ||
          cancelledAt.isAfter(serverTime) ||
          (reason == OrderCancellationReason.passenger &&
              !cancelledAt.isBefore(expiresAt)) ||
          (reason == OrderCancellationReason.searchTimeout &&
              cancelledAt != expiresAt)) {
        throw const OrderFailure(OrderFailureKind.invalidResponse);
      }
    }
    return PassengerOrder._(
      id: id,
      passengerId: passengerId,
      requestId: requestId,
      pickup: pickup,
      destination: destination,
      status: status,
      cancellationReason: reason,
      createdAt: createdAt,
      expiresAt: expiresAt,
      cancelledAt: cancelledAt,
      version: version,
    );
  }
}

class OrderEnvelope {
  const OrderEnvelope._(this.serverTime, this.order);

  factory OrderEnvelope.fromJson(
    Object? value, {
    required String expectedUserId,
    required OrderOperation operation,
    String? expectedRequestId,
    String? expectedOrderId,
  }) {
    final actor = _uuid(expectedUserId, OrderFailureKind.invalidResponse);
    final request = expectedRequestId == null
        ? null
        : _uuid(expectedRequestId, OrderFailureKind.invalidResponse);
    final orderId = expectedOrderId == null
        ? null
        : _uuid(expectedOrderId, OrderFailureKind.invalidResponse);
    if ((operation == OrderOperation.create && request == null) ||
        ((operation == OrderOperation.get ||
                operation == OrderOperation.cancel) &&
            orderId == null)) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    final data = _object(value, const {
      'contract_version',
      'server_time',
      'order',
    });
    if (data['contract_version'] is! int || data['contract_version'] != 1) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    final serverTime = _utcTime(data['server_time']);
    if (data['order'] == null) {
      if (operation != OrderOperation.getCurrent) {
        throw const OrderFailure(OrderFailureKind.invalidResponse);
      }
      return OrderEnvelope._(serverTime, null);
    }
    final order = PassengerOrder._fromJson(
      data['order'],
      serverTime: serverTime,
      expectedUserId: actor,
      expectedRequestId: request,
      expectedOrderId: orderId,
    );
    if (operation == OrderOperation.cancel &&
        order.status != OrderStatus.cancelled) {
      throw const OrderFailure(OrderFailureKind.invalidResponse);
    }
    return OrderEnvelope._(serverTime, order);
  }

  final DateTime serverTime;
  final PassengerOrder? order;
  int get contractVersion => 1;
}

final _uuidPattern = RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
);
final _utcPattern = RegExp(
  r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,6}))?(?:Z|\+00:00)$',
);
// Explicit API v1 whitelist, shared with SQL instead of locale-dependent \s/trim.
final _addressWhitespacePattern = RegExp(
  r'[\u0009-\u000D\u0020\u0085\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]+',
);
final _addressEdgeSpacesPattern = RegExp(r'^ +| +$');

String _uuid(Object? value, OrderFailureKind kind) {
  if (value is! String || _uuidPattern.firstMatch(value)?.end != value.length) {
    throw OrderFailure(kind);
  }
  return value.toLowerCase();
}

Map<String, dynamic> _object(Object? value, Set<String> keys) {
  if (value is! Map<String, dynamic> ||
      value.length != keys.length ||
      !keys.every(value.containsKey)) {
    throw const OrderFailure(OrderFailureKind.invalidResponse);
  }
  return value;
}

String _normalizeAddress(String value) => value
    .replaceAll(_addressWhitespacePattern, ' ')
    .replaceAll(_addressEdgeSpacesPattern, '');

bool _validAddress(String value) =>
    value.isNotEmpty && value.runes.length <= 500;

// Order coordinates use geographic bounds, independently of map projection limits.
bool _validPoint(GeoPoint point) =>
    point.latitude.isFinite &&
    point.longitude.isFinite &&
    point.latitude.abs() <= 90 &&
    point.longitude.abs() <= 180;

bool _samePoint(GeoPoint a, GeoPoint b) =>
    a.latitude == b.latitude && a.longitude == b.longitude;

DateTime _utcTime(Object? value) {
  if (value is! String) {
    throw const OrderFailure(OrderFailureKind.invalidResponse);
  }
  final match = _utcPattern.firstMatch(value);
  final parsed = DateTime.tryParse(value);
  if (match == null ||
      match.end != value.length ||
      parsed == null ||
      !parsed.isUtc) {
    throw const OrderFailure(OrderFailureKind.invalidResponse);
  }
  // DateTime.parse normalizes dates such as February 30; the contract does not.
  final components = [for (var i = 1; i <= 6; i++) int.parse(match.group(i)!)];
  if (parsed.year < 1 ||
      parsed.year != components[0] ||
      parsed.month != components[1] ||
      parsed.day != components[2] ||
      parsed.hour != components[3] ||
      parsed.minute != components[4] ||
      parsed.second != components[5]) {
    throw const OrderFailure(OrderFailureKind.invalidResponse);
  }
  return parsed;
}
