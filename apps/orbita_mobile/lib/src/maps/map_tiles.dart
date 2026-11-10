import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';

import 'address_models.dart';
import 'geoapify_service.dart';

/// Общий ограниченный RAM-кэш. Нет фонового скачивания, дискового журнала URI или ключей.
class MapTileSession {
  MapTileSession(
    this._key, {
    GeoapifyTransport? transport,
    this.minimumInterval = const Duration(milliseconds: 100),
  }) : _transport = transport ?? GeoapifyTransport();
  final String _key;
  final GeoapifyTransport _transport;
  final Duration minimumInterval;
  final _cache = <String, Uint8List>{};
  final _inflight = <String, Future<Uint8List>>{};
  int _bytes = 0, _generation = 0;
  int _active = 0;
  final _waiters = <Completer<void>>[];
  DateTime _nextStart = DateTime.fromMillisecondsSinceEpoch(0);
  bool _closed = false;
  MapFailure? _failure;
  Future<Uint8List> tile(TileCoordinates coordinate) async {
    if (_closed) throw const MapFailure(MapFailureKind.cancelled);
    final id = '${coordinate.z}/${coordinate.x}/${coordinate.y}';
    final cached = _cache.remove(id);
    if (cached != null) {
      _cache[id] = cached;
      return cached;
    }
    final existing = _inflight[id];
    if (existing != null) return existing;
    if (_failure case final failure?) throw failure;
    if (_inflight.length >= 64) throw const MapFailure(MapFailureKind.limit);
    final generation = _generation;
    final request = _fetch(id, generation);
    _inflight[id] = request;
    try {
      final bytes = await request;
      if (_closed || generation != _generation) {
        throw const MapFailure(MapFailureKind.cancelled);
      }
      _cache[id] = bytes;
      _bytes += bytes.length;
      while (_cache.length > 96 || _bytes > 12 * 1024 * 1024) {
        _bytes -= _cache.remove(_cache.keys.first)!.length;
      }
      return bytes;
    } finally {
      if (identical(_inflight[id], request)) _inflight.remove(id);
    }
  }

  Future<Uint8List> _fetch(String id, int generation) async {
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
        Uri.https('maps.geoapify.com', '/v1/tile/dark-matter/$id.png', {
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

  void rejectImage(TileCoordinates coordinate) {
    final id = '${coordinate.z}/${coordinate.x}/${coordinate.y}';
    final removed = _cache.remove(id);
    if (removed != null) _bytes -= removed.length;
    _failure ??= const MapFailure(MapFailureKind.invalid);
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
    _cache.clear();
    _bytes = 0;
  }
}

class OrbitaTileProvider extends TileProvider {
  OrbitaTileProvider(this.session);
  final MapTileSession session;
  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _SafeTileImage(session, coordinates);
}

/// В ImageProvider/Flutter error diagnostics не попадает URL с apiKey.
class _SafeTileImage extends ImageProvider<_SafeTileImage> {
  const _SafeTileImage(this.session, this.coordinates);
  final MapTileSession session;
  final TileCoordinates coordinates;
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
      return await decode(
        await ui.ImmutableBuffer.fromUint8List(await session.tile(coordinates)),
      );
    } on MapFailure {
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      rethrow;
    } catch (_) {
      session.rejectImage(coordinates);
      scheduleMicrotask(() => PaintingBinding.instance.imageCache.evict(this));
      throw const MapFailure(MapFailureKind.unavailable);
    }
  }

  @override
  bool operator ==(Object other) =>
      other is _SafeTileImage &&
      identical(session, other.session) &&
      coordinates == other.coordinates;
  @override
  int get hashCode => Object.hash(identityHashCode(session), coordinates);
  @override
  String toString() => 'OrbitaMapTile';
}
