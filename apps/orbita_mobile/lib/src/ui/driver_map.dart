import 'package:flutter/material.dart';

import '../maps/map_settings.dart';
import '../maps/address_models.dart';
import '../maps/map_tiles.dart';
import 'orbita_map.dart';
import 'theme.dart';

/// Показывает координату, полученную от рабочего экрана. Загрузка тайлов
/// останавливается, когда водительская вкладка скрыта или приложение в фоне.
class DriverMap extends StatefulWidget {
  const DriverMap({
    required this.mapSettings,
    this.enabled = true,
    this.foreground = true,
    this.height = 300,
    this.workSurface = false,
    this.tileSessionFactory,
    this.focusPoint,
    this.tripId,
    this.pickup,
    this.destination,
    this.onLocate,
    this.locating = false,
    super.key,
  });

  final MapSettings mapSettings;
  final bool enabled, foreground, workSurface;
  final double height;
  final MapTileSession Function(String)? tileSessionFactory;
  final GeoPoint? focusPoint;
  final String? tripId;
  final AddressPlace? pickup, destination;
  final VoidCallback? onLocate;
  final bool locating;

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
          MapTileSession(
            key,
            cache: _cache,
            transport: widget.mapSettings.transport(),
          );
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
    if (_session == null) {
      return SizedBox(
        key: const Key('driver-map-idle'),
        height: widget.height,
        width: double.infinity,
        child: ColoredBox(
          color: OrbitaPalette.of(context).mapLand,
          child: Align(
            alignment: Alignment.bottomRight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 0, 16, 12),
              child: SizedBox.square(
                dimension: 48,
                child: IconButton(
                  tooltip: 'Моё местоположение',
                  onPressed: _requested && !widget.locating
                      ? widget.onLocate
                      : null,
                  icon: widget.locating
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            semanticsLabel: 'Определяем местоположение',
                          ),
                        )
                      : const Icon(Icons.my_location),
                ),
              ),
            ),
          ),
        ),
      );
    }
    return OrbitaMap(
      key: ValueKey(_session),
      height: widget.height,
      workSurface: widget.workSurface,
      session: _session,
      enabled: _active,
      borderRadius: BorderRadius.zero,
      controls: MapControls.driver,
      focusPoint: widget.focusPoint,
      selectionId: widget.tripId,
      pickup: widget.pickup,
      destination: widget.destination,
      userPosition: widget.focusPoint,
      onLocate: widget.onLocate,
      locating: widget.locating,
    );
  }
}
