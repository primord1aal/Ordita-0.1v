abstract interface class TripHistoryApi {
  Future<Object?> loadTripHistory({
    required bool driver,
    HistoryTrip? before,
    String? status,
  });
}

class HistoryTrip {
  const HistoryTrip({
    required this.id,
    required this.completed,
    required this.createdAt,
    required this.finishedAt,
    required this.pickup,
    required this.destination,
  });

  factory HistoryTrip.fromJson(Object? value) {
    final row = value as Map<String, dynamic>;
    final id = row['id'] as String;
    final status = row['status'];
    if ((status != 'completed' && status != 'cancelled') ||
        !_uuid.hasMatch(id)) {
      throw const FormatException();
    }
    return HistoryTrip(
      id: id,
      completed: status == 'completed',
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      finishedAt: DateTime.parse(row['finished_at'] as String).toUtc(),
      pickup: row['pickup_address'] as String,
      destination: row['destination_address'] as String,
    );
  }

  static final _uuid = RegExp(r'^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$');

  final String id, pickup, destination;
  final bool completed;
  final DateTime createdAt, finishedAt;
}

class TripHistoryPage {
  TripHistoryPage.parse(
    Object? value, {
    required String userId,
    required bool driver,
  }) {
    final reply = value as Map<String, dynamic>;
    if (reply['contract_version'] != 1 ||
        reply['user_id'] != userId ||
        reply['role'] != (driver ? 'driver' : 'passenger')) {
      throw const FormatException();
    }
    final rows = reply['items'] as List<dynamic>;
    hasMore = reply['has_more'] as bool;
    if (rows.length > 30 || (hasMore && rows.length != 30)) {
      throw const FormatException();
    }
    items = List.unmodifiable(rows.map(HistoryTrip.fromJson));
  }

  late final List<HistoryTrip> items;
  late final bool hasMore;
}
