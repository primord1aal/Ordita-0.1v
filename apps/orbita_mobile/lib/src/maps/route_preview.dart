import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import 'address_models.dart';
import 'geoapify_service.dart';
import 'map_settings.dart';

/// Geometry returned by the road-routing provider, never an invented A–B line.
class RoutePreview {
  RoutePreview({
    required List<List<GeoPoint>> lines,
    this.distanceMeters,
    this.durationSeconds,
  }) : lines = List.unmodifiable(
         lines.map((line) => List<GeoPoint>.unmodifiable(line)),
       );

  final List<List<GeoPoint>> lines;
  List<GeoPoint> get points => [for (final line in lines) ...line];
  final double? distanceMeters, durationSeconds;
}

abstract interface class RouteService {
  Future<RoutePreview?> route(GeoPoint pickup, GeoPoint destination);
  void cancel();
  void close();
}

/// Two-waypoint passenger-car preview; no alternatives or extra paid details.
class GeoapifyRouteService implements RouteService {
  GeoapifyRouteService(this._key, {GeoapifyTransport? transport})
    : _transport = transport ?? GeoapifyTransport();

  final String _key;
  final GeoapifyTransport _transport;
  static const _maxPoints = 10000;

  @override
  Future<RoutePreview?> route(GeoPoint pickup, GeoPoint destination) async {
    if (!MapSettings.validKey(_key)) {
      throw const MapFailure(MapFailureKind.configuration);
    }
    if (!pickup.valid || !destination.valid) {
      throw const MapFailure(MapFailureKind.invalid);
    }
    final bytes = await _transport.get(
      Uri.https('api.geoapify.com', '/v1/routing', {
        'waypoints':
            '${pickup.latitude},${pickup.longitude}|'
            '${destination.latitude},${destination.longitude}',
        'mode': 'drive',
        'format': 'geojson',
        'units': 'metric',
        'lang': 'ru',
        'apiKey': _key,
      }),
      maxBytes: 1024 * 1024,
    );
    try {
      final body = jsonDecode(utf8.decode(bytes));
      if (body is! Map ||
          body['type'] != 'FeatureCollection' ||
          body['features'] is! List) {
        throw const FormatException();
      }
      final features = body['features'] as List;
      if (features.isEmpty) return null;
      final feature = features.first;
      if (feature is! Map || feature['type'] != 'Feature') {
        throw const FormatException();
      }
      final geometry = feature['geometry'];
      if (geometry is! Map) throw const FormatException();
      final coordinates = geometry['coordinates'];
      final rawLines = switch (geometry['type']) {
        'LineString' => [coordinates],
        'MultiLineString' => coordinates,
        _ => null,
      };
      if (rawLines is! List || rawLines.isEmpty || rawLines.length > 64) {
        throw const FormatException();
      }
      var count = 0;
      final lines = <List<GeoPoint>>[];
      for (final rawLine in rawLines) {
        if (rawLine is! List || rawLine.length < 2) {
          throw const FormatException();
        }
        count += rawLine.length;
        if (count > _maxPoints) throw const FormatException();
        final line = <GeoPoint>[];
        for (final rawPoint in rawLine) {
          if (rawPoint is! List ||
              rawPoint.length < 2 ||
              rawPoint[0] is! num ||
              rawPoint[1] is! num) {
            throw const FormatException();
          }
          // GeoJSON uses longitude, latitude; requests use latitude, longitude.
          final point = GeoPoint(
            (rawPoint[1] as num).toDouble(),
            (rawPoint[0] as num).toDouble(),
          );
          if (!point.valid) throw const FormatException();
          line.add(point);
        }
        lines.add(line);
      }
      final properties = feature['properties'];
      return RoutePreview(
        lines: lines,
        distanceMeters: _measure(properties, 'distance'),
        durationSeconds: _measure(properties, 'time'),
      );
    } catch (_) {
      throw const MapFailure(MapFailureKind.invalid);
    }
  }

  static double? _measure(dynamic properties, String name) {
    final value = properties is Map ? properties[name] : null;
    if (value == null) return null;
    if (value is! num || !value.isFinite || value < 0) {
      throw const FormatException();
    }
    return value.toDouble();
  }

  @override
  void cancel() => _transport.cancel();
  @override
  void close() => _transport.close();
}

/// Holds only the current in-memory route, independent of address lookups.
class RoutePreviewController extends ChangeNotifier {
  RoutePreviewController(
    this.settings, {
    RouteService Function(String)? serviceFactory,
    this.debounce = const Duration(milliseconds: 350),
  }) : _factory = serviceFactory ?? ((key) => GeoapifyRouteService(key)) {
    _key = settings.clientKey;
    _service = _factory(_key);
    settings.addListener(_configurationChanged);
  }

  final MapSettings settings;
  final RouteService Function(String) _factory;
  final Duration debounce;
  late String _key;
  late RouteService _service;
  GeoPoint? _pickup, _destination;
  RoutePreview? _route;
  String? _message;
  bool _enabled = false, _disposed = false, _busy = false;
  int _generation = 0;
  Timer? _timer;

  RoutePreview? get route => _route;
  String? get message => _message;
  bool get busy => _busy;

  void update(
    GeoPoint? pickup,
    GeoPoint? destination, {
    required bool enabled,
  }) {
    if (_disposed ||
        (_same(_pickup, pickup) &&
            _same(_destination, destination) &&
            _enabled == enabled)) {
      return;
    }
    _pickup = pickup;
    _destination = destination;
    _enabled = enabled;
    _resetAndSchedule();
  }

  void retry() {
    if (_disposed || _busy || !_canRequest) return;
    _cancel();
    _route = null;
    _message = null;
    _busy = true;
    _notify();
    unawaited(_load(_generation));
  }

  bool get _canRequest =>
      _enabled &&
      !_disposed &&
      settings.configured &&
      (_pickup?.valid ?? false) &&
      (_destination?.valid ?? false) &&
      !_same(_pickup, _destination);

  void _resetAndSchedule() {
    _cancel();
    _route = null;
    _message = null;
    if (_enabled && _pickup != null && _destination != null) {
      if (!_pickup!.valid || !_destination!.valid) {
        _message = 'Не удалось построить маршрут. Выберите адреса ещё раз.';
      } else if (_same(_pickup, _destination)) {
        _message = 'Начало и конец маршрута совпадают.';
      } else if (!settings.configured) {
        _message = 'Настройте карту, чтобы увидеть маршрут.';
      } else {
        _busy = true;
        final generation = _generation;
        _timer = Timer(debounce, () => unawaited(_load(generation)));
      }
    }
    _notify();
  }

  Future<void> _load(int generation) async {
    if (!_current(generation)) return;
    try {
      final result = await _service.route(_pickup!, _destination!);
      if (!_current(generation)) return;
      _route = result;
      if (result == null) {
        _message = 'Маршрут по дорогам не найден. Уточните выбранные точки.';
      }
    } on MapFailure catch (failure) {
      if (!_current(generation)) return;
      _message = switch (failure.kind) {
        MapFailureKind.configuration =>
          'Маршрут недоступен: проверьте настройку карт.',
        MapFailureKind.limit =>
          'Сервис карт временно ограничил запросы. Повторите позже.',
        MapFailureKind.network || MapFailureKind.timeout =>
          'Не удалось загрузить маршрут. Проверьте связь и повторите.',
        _ => 'Не удалось построить маршрут. Уточните точки или повторите.',
      };
    } catch (_) {
      if (_current(generation)) {
        _message = 'Не удалось построить маршрут. Попробуйте ещё раз.';
      }
    } finally {
      if (_current(generation)) {
        _busy = false;
        _notify();
      }
    }
  }

  bool _current(int generation) => generation == _generation && _canRequest;

  static bool _same(GeoPoint? a, GeoPoint? b) =>
      a?.latitude == b?.latitude && a?.longitude == b?.longitude;

  void _cancel() {
    ++_generation;
    _timer?.cancel();
    _timer = null;
    _service.cancel();
    _busy = false;
  }

  void _configurationChanged() {
    if (_disposed || settings.clientKey == _key) return;
    _cancel();
    _service.close();
    _key = settings.clientKey;
    _service = _factory(_key);
    _resetAndSchedule();
  }

  void _notify() {
    if (_disposed) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
    } else {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    settings.removeListener(_configurationChanged);
    _cancel();
    _service.close();
    super.dispose();
  }
}
