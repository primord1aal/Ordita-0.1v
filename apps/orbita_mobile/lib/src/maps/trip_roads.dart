import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import '../orders/dispatch_controller.dart';
import 'address_models.dart';
import 'map_settings.dart';
import 'route_preview.dart';

/// The active road leg has its own traffic estimate and refresh budget.
class TripRoads {
  TripRoads(MapSettings settings, {RouteService Function(String)? factory})
    : preview = RoutePreviewController(settings, serviceFactory: factory);

  final RoutePreviewController preview;
  (String, bool)? _leg;
  GeoPoint? _origin, _target;
  DateTime? _requestedAt;
  bool get toPickup => _leg?.$2 == false;

  void update(
    Trip? trip,
    GeoPoint? position, {
    required bool enabled,
    required bool stale,
  }) {
    final riding = trip?.status == 'riding';
    final approaching =
        trip?.status == 'accepted' || trip?.status == 'to_pickup';
    if (!enabled ||
        trip == null ||
        !(riding || approaching) ||
        position == null ||
        stale) {
      _leg = null;
      _origin = null;
      _target = null;
      _requestedAt = null;
      preview.update(null, null, enabled: false);
      return;
    }

    final leg = (trip.id, riding);
    final target = riding ? trip.destination.point : trip.pickup.point;
    final now = DateTime.now();
    if (_leg == leg &&
        _target?.latitude == target.latitude &&
        _target?.longitude == target.longitude &&
        _origin != null) {
      final age = now.difference(_requestedAt!);
      if (age < const Duration(seconds: 30)) return;
      if (preview.route == null &&
          !preview.busy &&
          age >= const Duration(seconds: 60)) {
        _requestedAt = now;
        preview.retry();
        return;
      }
      const distance = Distance();
      final movement = distance(_asLatLng(_origin!), _asLatLng(position));
      final deviated = _offRoute(position, preview.route);
      if (movement < 15 ||
          (!deviated && movement < 200 && age < const Duration(seconds: 60))) {
        return;
      }
    }

    _leg = leg;
    _target = target;
    _origin = position;
    _requestedAt = now;
    preview.update(position, target, enabled: true);
  }

  static LatLng _asLatLng(GeoPoint point) =>
      LatLng(point.latitude, point.longitude);

  bool _offRoute(GeoPoint position, RoutePreview? route) {
    if (route == null) return true;
    final lonScale = math.cos(position.latitude * math.pi / 180) * 111320;
    for (final line in route.lines) {
      for (var i = 1; i < line.length; i++) {
        final a = line[i - 1], b = line[i];
        final ax = (a.longitude - position.longitude) * lonScale;
        final ay = (a.latitude - position.latitude) * 111320;
        final dx = (b.longitude - a.longitude) * lonScale;
        final dy = (b.latitude - a.latitude) * 111320;
        final lengthSquared = dx * dx + dy * dy;
        final fraction = lengthSquared == 0
            ? 0.0
            : (-(ax * dx + ay * dy) / lengthSquared).clamp(0.0, 1.0);
        final x = ax + fraction * dx, y = ay + fraction * dy;
        if (x * x + y * y <= 65 * 65) return false;
      }
    }
    return true;
  }

  void dispose() => preview.dispose();
}
