import 'package:flutter/material.dart';

import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import 'orbita_map.dart';
import 'theme.dart';

/// Водительская карта не подписывается на геолокацию и не рисует позицию авто.
/// Скрытый IndexedStack содержит только этот лёгкий lifecycle-контейнер.
class DriverMap extends StatefulWidget {
  const DriverMap({
    required this.mapSettings,
    this.enabled = true,
    this.foreground = true,
    this.height = 300,
    this.tileSessionFactory,
    super.key,
  });

  final MapSettings mapSettings;
  final bool enabled, foreground;
  final double height;
  final MapTileSession Function(String)? tileSessionFactory;

  @override
  State<DriverMap> createState() => _DriverMapState();
}

class _DriverMapState extends State<DriverMap> {
  final _cache = MapTileCache();
  MapTileSession? _session;
  String _key = '';
  bool _active = false;

  bool get _requested => widget.enabled && widget.foreground;

  @override
  void initState() {
    super.initState();
    widget.mapSettings.addListener(_settingsChanged);
    _sync();
  }

  void _settingsChanged() {
    _sync();
    if (mounted) setState(() {});
  }

  void _sync() {
    final key = widget.mapSettings.clientKey;
    if (_key != key) {
      _session?.close();
      _session = null;
      _key = key;
    }
    final active = _requested && key.isNotEmpty;
    if (!active && _active) _session?.cancel();
    if (active && _session == null) {
      _session =
          widget.tileSessionFactory?.call(key) ??
          MapTileSession(key, cache: _cache);
    }
    _active = active;
  }

  @override
  void didUpdateWidget(covariant DriverMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.mapSettings != widget.mapSettings) {
      oldWidget.mapSettings.removeListener(_settingsChanged);
      widget.mapSettings.addListener(_settingsChanged);
    }
    _sync();
  }

  @override
  void dispose() {
    widget.mapSettings.removeListener(_settingsChanged);
    _session?.close();
    _cache.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_active) {
      return SizedBox(
        key: const Key('driver-map-idle'),
        height: widget.height,
        width: double.infinity,
        child: ColoredBox(
          color: OrbitaPalette.of(context).mapLand,
          child: _requested
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Text(
                      'Карта не подключена. Ключ можно задать в диагностике.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: OrbitaPalette.of(context).muted),
                    ),
                  ),
                )
              : null,
        ),
      );
    }
    return OrbitaMap(
      key: ValueKey(_session),
      height: widget.height,
      session: _session,
      borderRadius: BorderRadius.zero,
    );
  }
}
