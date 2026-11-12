import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';
import 'package:orbita_mobile/src/orders/order_models.dart';

const _actor = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
const _otherActor = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
const _orderId = '11111111-1111-4111-8111-111111111111';
const _otherOrderId = '22222222-2222-4222-8222-222222222222';
const _requestId = 'cccccccc-cccc-4ccc-8ccc-cccccccccccc';
const _otherRequestId = 'dddddddd-dddd-4ddd-8ddd-dddddddddddd';
const _created = '2026-11-12T15:00:00.123456+00:00';
const _expires = '2026-11-12T15:05:00.123456Z';
const _server = '2026-11-12T15:01:00.123456Z';
const _cancelled = '2026-11-12T15:00:30.123456Z';

Map<String, dynamic> _receipt() => {
  'id': _orderId,
  'passenger_id': _actor,
  'request_id': _requestId,
  'pickup': {'address': 'Чик, Ленина, 1', 'latitude': 55.0, 'longitude': 82.4},
  'destination': {
    'address': 'Прокудское, Советская, 2',
    'latitude': 55.1,
    'longitude': 82.5,
  },
  'status': 'created',
  'cancellation_reason': null,
  'created_at': _created,
  'expires_at': _expires,
  'cancelled_at': null,
  'version': 1,
};

Map<String, dynamic> _cancelledReceipt({bool timeout = false}) => {
  ..._receipt(),
  'status': 'cancelled',
  'cancellation_reason': timeout ? 'search_timeout' : 'passenger',
  'cancelled_at': timeout ? _expires : _cancelled,
  'version': 2,
};

Map<String, dynamic> _envelope(Object? order, {String serverTime = _server}) =>
    {'contract_version': 1, 'server_time': serverTime, 'order': order};

OrderEnvelope _decodeCreate(Object? data) => OrderEnvelope.fromJson(
  data,
  expectedUserId: _actor,
  operation: OrderOperation.create,
  expectedRequestId: _requestId,
);

final _invalidResponse = throwsA(
  isA<OrderFailure>().having(
    (failure) => failure.kind,
    'kind',
    OrderFailureKind.invalidResponse,
  ),
);
final _invalidRequest = throwsA(
  isA<OrderFailure>().having(
    (failure) => failure.kind,
    'kind',
    OrderFailureKind.invalidRequest,
  ),
);

void main() {
  test(
    'Команда сохраняет переданный ключ и отправляет только согласованные поля',
    () {
      final command = CreateOrderCommand(
        requestId: _requestId.toUpperCase(),
        pickup: OrderPoint(
          address: '  Чик,\n  Ленина,\t1  ',
          point: const GeoPoint(55, 82.4),
        ),
        destination: OrderPoint(
          address: 'Прокудское, Советская, 2',
          point: const GeoPoint(55.1, 82.5),
        ),
      );
      final first = command.toRpcParameters();
      expect(first, {
        'p_request_id': _requestId,
        'p_pickup': {
          'address': 'Чик, Ленина, 1',
          'latitude': 55.0,
          'longitude': 82.4,
        },
        'p_destination': {
          'address': 'Прокудское, Советская, 2',
          'latitude': 55.1,
          'longitude': 82.5,
        },
      });
      final encoded = jsonEncode(first);
      expect(jsonEncode(command.toRpcParameters()), encoded);
      (first['p_pickup'] as Map)['latitude'] = 0;
      expect(jsonEncode(command.toRpcParameters()), encoded);
      expect(command.requestId, _requestId);
    },
  );

  test('Команда отклоняет пустые адреса, плохой UUID и совпадающие точки', () {
    for (final address in ['', ' \t\n ', 'я' * 501]) {
      expect(
        () => OrderPoint(address: address, point: const GeoPoint(55, 82.4)),
        _invalidRequest,
      );
    }
    final pickup = OrderPoint(
      address: 'Чик, Ленина, 1',
      point: const GeoPoint(55, 82.4),
    );
    for (final requestId in ['not-a-uuid', '$_requestId\n']) {
      expect(
        () => CreateOrderCommand(
          requestId: requestId,
          pickup: pickup,
          destination: OrderPoint(
            address: 'Чик, Ленина, 2',
            point: const GeoPoint(55.1, 82.5),
          ),
        ),
        _invalidRequest,
      );
    }
    expect(
      () => CreateOrderCommand(
        requestId: _requestId,
        pickup: pickup,
        destination: pickup,
      ),
      _invalidRequest,
    );
  });

  test('API v1 одинаково нормализует NBSP и явные Unicode-разделители', () {
    final point = OrderPoint(
      address: '\uFEFF\u0085\u00A0Чик,\u2007\u202F Ленина,\u2028\u2029\u3000 1\u205F\u1680',
      point: const GeoPoint(55, 82.4),
    );
    expect(point.address, 'Чик, Ленина, 1');
    final receipt = {..._receipt(), 'pickup': point.toJson()};
    expect(
      _decodeCreate(_envelope(receipt)).order!.pickup.address,
      point.address,
    );
  });

  test('Географические пределы отличаются от пределов проекции карты', () {
    final pole = OrderPoint(address: 'Полюс', point: const GeoPoint(90, -180));
    expect(pole.point.valid, isFalse);
    expect(pole.toJson()['latitude'], 90);
    expect(
      OrderPoint(
        address: '😀' * 500,
        point: const GeoPoint(55, 82),
      ).address.runes.length,
      500,
    );
    for (final point in [
      const GeoPoint(90.0001, 0),
      const GeoPoint(0, -180.0001),
      const GeoPoint(double.nan, 0),
      const GeoPoint(0, double.infinity),
    ]) {
      expect(() => OrderPoint(address: 'Адрес', point: point), _invalidRequest);
    }
  });

  test('Квитанция JSON декодируется с owner, request и серверным сроком', () {
    final decoded = jsonDecode(jsonEncode(_envelope(_receipt())));
    final envelope = _decodeCreate(decoded);
    final order = envelope.order!;
    expect(envelope.contractVersion, 1);
    expect(envelope.serverTime.isUtc, isTrue);
    expect(order.id, _orderId);
    expect(order.passengerId, _actor);
    expect(order.requestId, _requestId);
    expect(order.pickup.address, 'Чик, Ленина, 1');
    expect(order.destination.point.longitude, 82.5);
    expect(order.status, OrderStatus.created);
    expect(order.version, 1);
    expect(order.cancellationReason, isNull);
    expect(order.cancelledAt, isNull);
    expect(order.createdAt.microsecond, 456);
    expect(
      order.expiresAt.difference(order.createdAt),
      const Duration(minutes: 5),
    );
  });

  test('Повтор create может вернуть исходную отменённую квитанцию', () {
    final passenger = _decodeCreate(_envelope(_cancelledReceipt())).order!;
    final timeout = _decodeCreate(
      _envelope(_cancelledReceipt(timeout: true), serverTime: _expires),
    ).order!;
    expect(passenger.id, _orderId);
    expect(passenger.cancellationReason, OrderCancellationReason.passenger);
    expect(passenger.version, 2);
    expect(timeout.cancellationReason, OrderCancellationReason.searchTimeout);
    expect(timeout.cancelledAt, timeout.expiresAt);
  });

  test(
    'getCurrent возвращает последнюю отменённую квитанцию или null без истории',
    () {
      final empty = OrderEnvelope.fromJson(
        _envelope(null),
        expectedUserId: _actor,
        operation: OrderOperation.getCurrent,
      );
      expect(empty.order, isNull);
      final terminal = OrderEnvelope.fromJson(
        _envelope(_cancelledReceipt()),
        expectedUserId: _actor,
        operation: OrderOperation.getCurrent,
      );
      expect(terminal.order!.status, OrderStatus.cancelled);
      for (final operation in [
        OrderOperation.create,
        OrderOperation.get,
        OrderOperation.cancel,
      ]) {
        expect(
          () => OrderEnvelope.fromJson(
            _envelope(null),
            expectedUserId: _actor,
            operation: operation,
            expectedRequestId: _requestId,
            expectedOrderId: _orderId,
          ),
          _invalidResponse,
        );
      }
    },
  );

  test('Другой owner, request или order ID не проходит границу разбора', () {
    expect(
      () => _decodeCreate(
        _envelope({..._receipt(), 'passenger_id': _otherActor}),
      ),
      _invalidResponse,
    );
    expect(
      () => _decodeCreate(
        _envelope({..._receipt(), 'request_id': _otherRequestId}),
      ),
      _invalidResponse,
    );
    for (final operation in [OrderOperation.get, OrderOperation.cancel]) {
      expect(
        () => OrderEnvelope.fromJson(
          _envelope(_cancelledReceipt()),
          expectedUserId: _actor,
          operation: operation,
          expectedOrderId: _otherOrderId,
        ),
        _invalidResponse,
      );
    }
    expect(
      () => OrderEnvelope.fromJson(
        _envelope(null),
        expectedUserId: 'missing-actor',
        operation: OrderOperation.getCurrent,
      ),
      _invalidResponse,
    );
  });

  test('Ожидаемые ID обязательны для create, get и cancel', () {
    for (final operation in [
      OrderOperation.create,
      OrderOperation.get,
      OrderOperation.cancel,
    ]) {
      expect(
        () => OrderEnvelope.fromJson(
          _envelope(_receipt()),
          expectedUserId: _actor,
          operation: operation,
        ),
        _invalidResponse,
      );
    }
    final cancelled = OrderEnvelope.fromJson(
      _envelope(_cancelledReceipt()),
      expectedUserId: _actor,
      operation: OrderOperation.cancel,
      expectedOrderId: _orderId,
    );
    expect(cancelled.order!.status, OrderStatus.cancelled);
    expect(
      () => OrderEnvelope.fromJson(
        _envelope(_receipt()),
        expectedUserId: _actor,
        operation: OrderOperation.cancel,
        expectedOrderId: _orderId,
      ),
      _invalidResponse,
    );
  });

  test(
    'Неизвестный контракт, будущие поля и повреждённые формы отклоняются',
    () {
      final missing = _receipt()..remove('request_id');
      for (final response in [
        null,
        [],
        {..._envelope(_receipt()), 'contract_version': 2},
        {..._envelope(_receipt()), 'contract_version': 1.0},
        {..._envelope(_receipt()), 'price': 100},
        _envelope({..._receipt(), 'driver_id': _otherActor}),
        _envelope({..._receipt(), 'id': 'not-a-uuid'}),
        _envelope(missing),
      ]) {
        expect(() => _decodeCreate(response), _invalidResponse);
      }
    },
  );

  test('Неверные координаты, ненормализованный адрес и одинаковые точки отклоняются', () {
    final pickup = Map<String, dynamic>.from(_receipt()['pickup'] as Map);
    for (final patch in [
      {'latitude': '55'},
      {'latitude': 91},
      {'latitude': double.nan},
      {'longitude': -181},
      {'longitude': double.infinity},
      {'address': '  Чик, Ленина, 1 '},
      {'address': ''},
      {'address': 'я' * 501},
      {'price': 100},
    ]) {
      expect(
        () => _decodeCreate(
          _envelope({
            ..._receipt(),
            'pickup': {...pickup, ...patch},
          }),
        ),
        _invalidResponse,
      );
    }
    expect(
      () => _decodeCreate(_envelope({..._receipt(), 'destination': pickup})),
      _invalidResponse,
    );
  });

  test(
    'Статус, причина отмены и version образуют только согласованные состояния',
    () {
      for (final patch in [
        {'status': 'assigned'},
        {'version': 3},
        {'version': 1.0},
        {'cancellation_reason': 'driver'},
        {'cancellation_reason': 'passenger'},
        {'cancelled_at': _cancelled},
        {'status': 'cancelled', 'version': 2},
        {
          'status': 'cancelled',
          'cancellation_reason': 'passenger',
          'cancelled_at': _cancelled,
        },
      ]) {
        expect(
          () => _decodeCreate(_envelope({..._receipt(), ...patch})),
          _invalidResponse,
        );
      }
    },
  );

  test('Срок неизменен, UTC обязателен, невозможные даты не нормализуются', () {
    for (final response in [
      _envelope(_receipt(), serverTime: _expires),
      _envelope(_receipt(), serverTime: '2026-11-12T14:59:59Z'),
      _envelope({..._receipt(), 'expires_at': '2026-11-12T15:05:00.123457Z'}),
      _envelope({..._receipt(), 'created_at': '2026-02-30T15:00:00Z'}),
      _envelope(_receipt(), serverTime: '2026-11-12T15:01:00'),
      _envelope(_receipt(), serverTime: '2026-11-12T18:01:00+03:00'),
      _envelope({
        ..._cancelledReceipt(),
        'cancelled_at': _expires,
      }, serverTime: _expires),
      _envelope({
        ..._cancelledReceipt(),
        'cancelled_at': '2026-11-12T14:59:00Z',
      }),
      _envelope({
        ..._cancelledReceipt(),
        'cancelled_at': '2026-11-12T15:02:00Z',
      }),
      _envelope(_cancelledReceipt(timeout: true)),
      _envelope({
        ..._cancelledReceipt(timeout: true),
        'cancelled_at': _cancelled,
      }, serverTime: _expires),
    ]) {
      expect(() => _decodeCreate(response), _invalidResponse);
    }
  });

  test(
    'Ошибки содержат безопасный русский текст без исходного ответа и ID',
    () {
      expect(
        OrderFailure.fromServerMessage('ORB_ORDER_IDEMPOTENCY_CONFLICT').kind,
        OrderFailureKind.idempotencyConflict,
      );
      final privateBody = 'secret $_actor 55.12345 ORB_ORDER_NOT_FOUND';
      final failure = OrderFailure.fromServerMessage(privateBody);
      expect(failure.kind, OrderFailureKind.unavailable);
      expect(
        failure.message,
        'Не удалось получить данные заказа. Повторите попытку.',
      );
      expect(failure.toString(), 'OrderFailure(unavailable)');
      expect(failure.message, isNot(contains(_actor)));
      expect(failure.toString(), isNot(contains(privateBody)));
    },
  );
}
