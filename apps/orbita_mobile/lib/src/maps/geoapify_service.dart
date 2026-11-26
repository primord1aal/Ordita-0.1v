import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'address_models.dart';
import 'geoapify_address_formatter.dart';

enum AddressLookup { form, location }

abstract interface class AddressService {
  Future<List<AddressPlace>> search(String query);
  Future<String?> reverse(
    GeoPoint point, {
    AddressLookup lookup = AddressLookup.form,
  });
  void cancel([AddressLookup? lookup]);
  void close();
}

/// Только Geoapify, HTTPS, без переходов, повторов, логирования или Auth-заголовков.
typedef MapRequestProxy =
    Future<({Uri uri, Map<String, String> headers})> Function(Uri source);

class GeoapifyTransport {
  GeoapifyTransport({
    http.Client Function()? clientFactory,
    this.proxy,
    this.timeout = const Duration(seconds: 8),
  }) : _factory =
           clientFactory ??
           (() => IOClient(
             HttpClient()..connectionTimeout = const Duration(seconds: 8),
           ));
  final http.Client Function() _factory;
  final MapRequestProxy? proxy;
  final Duration timeout;
  final _pending = <http.Client, Object?>{};
  bool _closed = false;
  Future<Uint8List> get(
    Uri uri, {
    int maxBytes = 256 * 1024,
    Object? requestGroup,
  }) async {
    if (_closed) throw const MapFailure(MapFailureKind.cancelled);
    if (uri.scheme != 'https' ||
        uri.userInfo.isNotEmpty ||
        uri.hasPort ||
        !((uri.host == 'api.geoapify.com' &&
                const [
                  '/v1/geocode/autocomplete',
                  '/v1/geocode/reverse',
                  '/v1/routing',
                ].contains(uri.path)) ||
            (uri.host == 'maps.geoapify.com' &&
                RegExp(
                  r'^/v1/tile/(osm-carto|positron|dark-matter)/\d{1,2}/\d+/\d+\.png$',
                ).hasMatch(uri.path)))) {
      throw const MapFailure(MapFailureKind.configuration);
    }
    final client = _factory();
    _pending[client] = requestGroup;
    try {
      final payload = await (() async {
        final forwarded = await proxy?.call(uri);
        if (!_pending.containsKey(client)) {
          throw const MapFailure(MapFailureKind.cancelled);
        }
        final request = http.Request('GET', forwarded?.uri ?? uri)
          ..followRedirects = false;
        if (forwarded != null) request.headers.addAll(forwarded.headers);
        request.headers['User-Agent'] =
            'Orbita/0.6.1 (Android; ru.orbita.taxi.dev)';
        final response = await client.send(request);
        if (response.statusCode != 200) {
          throw MapFailure(switch (response.statusCode) {
            401 || 403 => MapFailureKind.configuration,
            429 => MapFailureKind.limit,
            504 => MapFailureKind.timeout,
            _ => MapFailureKind.unavailable,
          });
        }
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in response.stream) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const MapFailure(MapFailureKind.invalid);
          }
          bytes.add(chunk);
        }
        return bytes.takeBytes();
      })().timeout(timeout);
      if (!_pending.containsKey(client)) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      return payload;
    } catch (error) {
      if (!_pending.containsKey(client)) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      if (error is MapFailure) rethrow;
      if (error is TimeoutException) {
        throw const MapFailure(MapFailureKind.timeout);
      }
      throw const MapFailure(MapFailureKind.network);
    } finally {
      if (_pending.containsKey(client)) {
        _pending.remove(client);
        client.close();
      }
    }
  }

  void cancel({Object? requestGroup}) {
    for (final entry in _pending.entries.toList()) {
      if (requestGroup == null || entry.value == requestGroup) {
        _pending.remove(entry.key);
        entry.key.close();
      }
    }
  }

  void close() {
    _closed = true;
    cancel();
  }
}

class GeoapifyAddressService implements AddressService {
  GeoapifyAddressService(this._key, {GeoapifyTransport? transport})
    : _transport = transport ?? GeoapifyTransport();
  final String _key;
  final GeoapifyTransport _transport;
  @override
  Future<List<AddressPlace>> search(String query) async {
    query = query.trim();
    if (query.length < 3 || query.length > 250) return [];
    final rows = await _rows('/v1/geocode/autocomplete', {
      'text': query,
      'lang': 'ru',
      'limit': '5',
      'filter': 'countrycode:ru',
      'bias':
          'proximity:${localMapCenter.longitude},${localMapCenter.latitude}',
    });
    final places = <AddressPlace>[];
    for (final row in rows.take(5)) {
      if (row is! Map) continue;
      final lat = row['lat'], lon = row['lon'];
      final label = formatGeoapifyAddress(row);
      if (lat is! num || lon is! num || label == null) {
        continue;
      }
      final point = GeoPoint(lat.toDouble(), lon.toDouble());
      if (point.valid) places.add(AddressPlace(label, point));
    }
    if (rows.isNotEmpty && places.isEmpty) {
      throw const MapFailure(MapFailureKind.invalid);
    }
    return places;
  }

  @override
  Future<String?> reverse(
    GeoPoint point, {
    AddressLookup lookup = AddressLookup.form,
  }) async {
    if (!point.valid) throw const MapFailure(MapFailureKind.invalid);
    final rows = await _rows('/v1/geocode/reverse', {
      'lat': '${point.latitude}',
      'lon': '${point.longitude}',
      'lang': 'ru',
      'limit': '1',
    }, lookup: lookup);
    if (rows.isEmpty) return null;
    final first = rows.first;
    final label = first is Map ? formatGeoapifyAddress(first) : null;
    if (label == null) {
      throw const MapFailure(MapFailureKind.invalid);
    }
    return label;
  }

  Future<List<dynamic>> _rows(
    String path,
    Map<String, String> parameters, {
    AddressLookup lookup = AddressLookup.form,
  }) async {
    if (_key.isEmpty) throw const MapFailure(MapFailureKind.configuration);
    final bytes = await _transport.get(
      Uri.https('api.geoapify.com', path, {
        ...parameters,
        'format': 'json',
        'apiKey': _key,
      }),
      requestGroup: lookup,
    );
    try {
      final decoded = jsonDecode(utf8.decode(bytes));
      if (decoded is! Map || decoded['results'] is! List) {
        throw const FormatException();
      }
      return decoded['results'] as List<dynamic>;
    } catch (_) {
      throw const MapFailure(MapFailureKind.invalid);
    }
  }

  @override
  void cancel([AddressLookup? lookup]) =>
      _transport.cancel(requestGroup: lookup);
  @override
  void close() => _transport.close();
}
