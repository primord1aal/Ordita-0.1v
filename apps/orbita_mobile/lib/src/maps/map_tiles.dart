import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'address_models.dart';
import 'geoapify_service.dart';

/// Geoapify raster styles: https://apidocs.geoapify.com/docs/maps/map-tiles/
enum MapTileStyle {
  positron('positron'),
  darkMatter('dark-matter');

  const MapTileStyle(this.id);
  final String id;
}

/// Только завершённые тайлы в памяти. Запросы принадлежат сессиям, а не кэшу.
/// Закрытие одной сессии не отменяет работу другой с тем же кэшем.
class MapTileCache {
  final _entries = <_TileCacheKey, Uint8List>{};
  int _bytes = 0;

  Uint8List? _read(String key, MapTileStyle style, String tile) {
    final id = _TileCacheKey(key, style, tile);
    final bytes = _entries.remove(id);
    if (bytes != null) _entries[id] = bytes;
    return bytes;
  }

  void _put(String key, MapTileStyle style, String tile, Uint8List bytes) {
    final id = _TileCacheKey(key, style, tile);
    final previous = _entries.remove(id);
    if (previous != null) _bytes -= previous.length;
    _entries[id] = bytes;
    _bytes += bytes.length;
    while (_entries.length > 96 || _bytes > 12 * 1024 * 1024) {
      _bytes -= _entries.remove(_entries.keys.first)!.length;
    }
  }

  void _remove(String key, MapTileStyle style, String tile) {
    final bytes = _entries.remove(_TileCacheKey(key, style, tile));
    if (bytes != null) _bytes -= bytes.length;
  }

  void clear() {
    _entries.clear();
    _bytes = 0;
  }

  @override
  String toString() => 'OrbitaTileCache';
}

/// Контекст ключа существует только в ограниченном RAM-кэше. Он не выдаётся
/// через API кэша, diagnostics, логи или постоянный идентификатор.
class _TileCacheKey {
  const _TileCacheKey(this._keyContext, this.style, this.tile);
  static const provider = 'geoapify';
  final String _keyContext;
  final MapTileStyle style;
  final String tile;

  @override
  bool operator ==(Object other) =>
      other is _TileCacheKey &&
      _keyContext == other._keyContext &&
      style == other.style &&
      tile == other.tile;
  @override
  int get hashCode => Object.hash(provider, _keyContext, style, tile);
  @override
  String toString() => 'OrbitaTileCacheKey';
}

/// Ограниченные запросы одной карты; нет фоновой предзагрузки или дискового кэша.
class MapTileSession {
  MapTileSession(
    this._key, {
    GeoapifyTransport? transport,
    MapTileCache? cache,
    this.minimumInterval = const Duration(milliseconds: 100),
  }) : _transport = transport ?? GeoapifyTransport(),
       _cache = cache ?? MapTileCache(),
       _ownsCache = cache == null;
  final String _key;
  final GeoapifyTransport _transport;
  final Duration minimumInterval;
  MapTileStyle _style = MapTileStyle.darkMatter;
  MapTileStyle get style => _style;
  final MapTileCache _cache;
  final bool _ownsCache;
  final _inflight = <String, Future<Uint8List>>{};
  int _generation = 0;
  int _active = 0;
  final _waiters = <Completer<void>>[];
  DateTime _nextStart = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  MapFailure? _failure;
  void setStyle(MapTileStyle style) {
    if (_style == style) return;
    cancel();
    _failure = null;
    _style = style;
  }

  Future<Uint8List> tile(TileCoordinates coordinate) async {
    if (_closed) throw const MapFailure(MapFailureKind.cancelled);
    if (_key.isEmpty) throw const MapFailure(MapFailureKind.configuration);
    final id = '${coordinate.z}/${coordinate.x}/${coordinate.y}';
    final style = _style;
    final cached = _cache._read(_key, style, id);
    if (cached != null) return cached;
    final existing = _inflight[id];
    if (existing != null) return existing;
    if (_failure case final failure?) throw failure;
    if (_inflight.length >= 64) throw const MapFailure(MapFailureKind.limit);
    final generation = _generation;
    final request = _fetch(id, generation, style);
    _inflight[id] = request;
    try {
      final bytes = await request;
      if (_closed || generation != _generation) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      _cache._put(_key, style, id, bytes);
      return bytes;
    } finally {
      if (identical(_inflight[id], request)) _inflight.remove(id);
    }
  }

  Future<Uint8List> _fetch(
    String id,
    int generation,
    MapTileStyle style,
  ) async {
    void check() {
      if (_closed || _generation != generation) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      if (_failure case final failure?) throw failure;
    }

    while (_active >= 4) {
      final waiter = Completer<void>();
      _waiters.add(waiter);
      await waiter.future;
      check();
    }
    check();
    _active++;
    try {
      final now = DateTime.now();
      final start = _nextStart.isAfter(now) ? _nextStart : now;
      _nextStart = start.add(minimumInterval);
      final delay = start.difference(now);
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      check();
      return await _transport.get(
        Uri.https('maps.geoapify.com', '/v1/tile/${style.id}/$id.png', {
          'apiKey': _key,
        }),
        maxBytes: 512 * 1024,
      );
    } on MapFailure catch (failure) {
      if (generation == _generation &&
          failure.kind != MapFailureKind.cancelled) {
        _failure ??= failure;
      }
      rethrow;
    } finally {
      _active--;
      for (final waiter in _waiters) {
        waiter.complete();
      }
      _waiters.clear();
    }
  }

  void retry() {
    cancel();
    _failure = null;
  }

  void rejectImage(TileCoordinates coordinate, {MapTileStyle? style}) {
    final id = '${coordinate.z}/${coordinate.x}/${coordinate.y}';
    final rejectedStyle = style ?? _style;
    _cache._remove(_key, rejectedStyle, id);
    if (rejectedStyle == _style) {
      _failure ??= const MapFailure(MapFailureKind.invalid);
    }
  }

  void cancel() {
    _generation++;
    _transport.cancel();
    _inflight.clear();
    for (final waiter in _waiters) {
      waiter.complete();
    }
    _waiters.clear();
  }

  void close() {
    _closed = true;
    cancel();
    _transport.close();
    if (_ownsCache) _cache.clear();
  }
}

class OrbitaTileProvider extends TileProvider {
  OrbitaTileProvider(this.session);
  final MapTileSession session;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _SafeTileImage(session, coordinates, session.style);
}

/// В ImageProvider/Flutter error diagnostics не попадает URL с apiKey.
class _SafeTileImage extends ImageProvider<_SafeTileImage> {
  const _SafeTileImage(this.session, this.coordinates, this.style);
  final MapTileSession session;
  final TileCoordinates coordinates;
  final MapTileStyle style;
  @override
  Future<_SafeTileImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);
  @override
  ImageStreamCompleter loadImage(
    _SafeTileImage key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _decode(decode),
    scale: 1,
    debugLabel: 'Фрагмент карты Орбиты',
  );
  Future<ui.Codec> _decode(ImageDecoderCallback decode) async {
    try {
      if (session.style != style) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      final bytes = await session.tile(coordinates);
      if (session.style != style) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      return await decode(await ui.ImmutableBuffer.fromUint8List(bytes));
    } on MapFailure {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } catch (_) {
      session.rejectImage(coordinates, style: style);
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      throw const MapFailure(MapFailureKind.unavailable);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _SafeTileImage &&
      identical(session, other.session) &&
      style == other.style &&
      coordinates == other.coordinates;
  @override
  int get hashCode =>
      Object.hash(identityHashCode(session), style, coordinates);
  @override
  String toString() => 'OrbitaMapTile';
}
