abstract interface class TripPeopleApi {
  Future<Object?> loadTripPeer(String orderId);
  Future<Object?> loadOwnVehicle();
}

class VehicleDetails {
  VehicleDetails.fromJson(Object? value) {
    final data = value as Map<String, dynamic>;
    make = data['make'] as String;
    model = data['model'] as String;
    color = data['color'] as String;
    plate = data['plate'] as String;
  }

  late final String make, model, color, plate;
}

class TripPeer {
  TripPeer.parse(Object? value, {required String orderId}) {
    final data = value as Map<String, dynamic>;
    if (data['order_id'] != orderId) throw const FormatException();
    name = data['display_name'] as String?;
    final raw = data['vehicle'];
    vehicle = raw == null ? null : VehicleDetails.fromJson(raw);
  }

  late final String? name;
  late final VehicleDetails? vehicle;
}
