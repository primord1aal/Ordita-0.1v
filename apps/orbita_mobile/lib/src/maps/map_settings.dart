import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'address_models.dart';
import 'geoapify_service.dart';

abstract interface class MapKeyStore {
  Future<String?> read();
  Future<void> write(String value);
  Future<void> delete();
}

class SecureMapKeyStore implements MapKeyStore {
  final _storage = const FlutterSecureStorage();
  static const _key = 'orbita_geoapify_client_key_v1';
  @override
  Future<String?> read() => _storage.read(key: _key);
  @override
  Future<void> write(String value) => _storage.write(key: _key, value: value);
  @override
  Future<void> delete() => _storage.delete(key: _key);
}

class MapSettings extends ChangeNotifier {
  MapSettings({this.store, String initialKey = '', this.transportFactory})
    : _key = initialKey;
  MapSettings.managed(MapRequestProxy proxy)
    : store = null,
      _key = 'orbita_managed_maps_v1',
      transportFactory = (() => GeoapifyTransport(proxy: proxy));
  final GeoapifyTransport Function()? transportFactory;
  GeoapifyTransport transport() =>
      transportFactory?.call() ?? GeoapifyTransport();
  final MapKeyStore? store;
  String _key;
  bool _disposed = false;
  bool storageUnavailable = false;
  bool get configured => validKey(_key);
  String get clientKey => configured ? _key : '';
  static bool validKey(String value) =>
      !value.startsWith('sb_') &&
      !value.startsWith('eyJ') &&
      RegExp(r'^[A-Za-z0-9_-]{16,128}$').hasMatch(value);
  Future<void> load() async {
    try {
      final saved = await store?.read();
      if (_disposed) return;
      if (saved != null && validKey(saved)) _key = saved;
    } catch (_) {
      if (!_disposed) storageUnavailable = true;
    }
    if (!_disposed) notifyListeners();
  }

  Future<void> save(String value) async {
    final key = value.trim();
    if (!validKey(key)) throw const MapFailure(MapFailureKind.configuration);
    try {
      await store?.write(key);
    } catch (_) {
      throw const MapFailure(MapFailureKind.storage);
    }
    if (_disposed) return;
    _key = key;
    storageUnavailable = false;
    notifyListeners();
  }

  Future<void> clear() async {
    try {
      await store?.delete();
    } catch (_) {
      throw const MapFailure(MapFailureKind.storage);
    }
    if (_disposed) return;
    _key = '';
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
