import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../maps/address_models.dart';
import '../maps/map_tiles.dart';
import 'theme.dart';

class OrbitaMap extends StatefulWidget {
  const OrbitaMap({
    required this.session,
    this.height = 300,
    this.enabled = true,
    this.pickup,
    this.destination,
    this.initialCenter = localMapCenter,
    this.focusPoint,
    this.picking = false,
    this.onCenterChanged,
    super.key,
  });
  final MapTileSession? session;
  final double height;
  final bool enabled, picking;
  final AddressPlace? pickup, destination;
  final GeoPoint initialCenter;
  final GeoPoint? focusPoint;
  final ValueChanged<GeoPoint>? onCenterChanged;
  @override
  State<OrbitaMap> createState() => _OrbitaMapState();
}

class _OrbitaMapState extends State<OrbitaMap> {
  final _camera = MapController();
  bool _ready = false, _tileError = false;
  MapFailureKind _tileFailure = MapFailureKind.unavailable;
  int _reload = 0;
  @override
  void didUpdateWidget(covariant OrbitaMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final point = widget.focusPoint;
    if (_ready && point != null && point != oldWidget.focusPoint) {
      _camera.move(LatLng(point.latitude, point.longitude), 16);
    }
    if (oldWidget.session != widget.session) _tileError = false;
  }

  @override
  void dispose() {
    _camera.dispose();
    super.dispose();
  }

  void _failed(Object error) {
    if (_tileError) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_tileError) {
        setState(() {
          _tileError = true;
          _tileFailure = error is MapFailure
              ? error.kind
              : MapFailureKind.unavailable;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      SizedBox(
        height: widget.height,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(18),
          child: widget.session == null
              ? const ColoredBox(
                  color: OrbitaColors.card,
                  child: Center(
                    child: Padding(
                      padding: EdgeInsets.all(20),
                      child: Text(
                        'Карта пока не подключена. Адреса можно ввести вручную.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              : Stack(
                  children: [
                    FlutterMap(
                      mapController: _camera,
                      options: MapOptions(
                        initialCenter: LatLng(
                          widget.initialCenter.latitude,
                          widget.initialCenter.longitude,
                        ),
                        initialZoom: 13,
                        minZoom: 4,
                        maxZoom: 18,
                        backgroundColor: OrbitaColors.card,
                        onMapReady: () => _ready = true,
                        interactionOptions: InteractionOptions(
                          flags: widget.enabled && widget.picking
                              ? InteractiveFlag.all & ~InteractiveFlag.rotate
                              : InteractiveFlag.none,
                        ),
                        onTap: !widget.picking || !widget.enabled
                            ? null
                            : (_, point) {
                                _camera.move(point, _camera.camera.zoom);
                                widget.onCenterChanged?.call(
                                  GeoPoint(point.latitude, point.longitude),
                                );
                              },
                        onPositionChanged: (camera, hasGesture) {
                          if (widget.picking && widget.enabled && hasGesture) {
                            widget.onCenterChanged?.call(
                              GeoPoint(
                                camera.center.latitude,
                                camera.center.longitude,
                              ),
                            );
                          }
                        },
                      ),
                      children: [
                        if (widget.enabled)
                          TileLayer(
                            key: ValueKey((widget.session, _reload)),
                            tileProvider: OrbitaTileProvider(widget.session!),
                            userAgentPackageName: 'ru.orbita.taxi.dev',
                            maxNativeZoom: 18,
                            panBuffer: 0,
                            keepBuffer: 0,
                            errorTileCallback: (_, error, _) => _failed(error),
                          ),
                        MarkerLayer(
                          markers: [
                            for (final entry in [
                              (widget.pickup, 'Откуда', OrbitaColors.accent),
                              (
                                widget.destination,
                                'Куда',
                                OrbitaColors.warning,
                              ),
                            ])
                              if (entry.$1 case final place?)
                                Marker(
                                  point: LatLng(
                                    place.point.latitude,
                                    place.point.longitude,
                                  ),
                                  width: 48,
                                  height: 48,
                                  alignment: Alignment.topCenter,
                                  child: Tooltip(
                                    message: '${entry.$2}: ${place.label}',
                                    child: Icon(
                                      Icons.location_pin,
                                      color: entry.$3,
                                      size: 44,
                                    ),
                                  ),
                                ),
                          ],
                        ),
                      ],
                    ),
                    if (widget.picking)
                      const IgnorePointer(
                        child: Center(
                          child: Icon(
                            Icons.add,
                            color: OrbitaColors.accent,
                            size: 46,
                          ),
                        ),
                      ),
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Material(
                        color: OrbitaColors.background,
                        borderRadius: BorderRadius.circular(14),
                        child: Column(
                          children: [
                            IconButton(
                              tooltip: 'Приблизить карту',
                              onPressed: widget.enabled
                                  ? () => _camera.move(
                                      _camera.camera.center,
                                      (_camera.camera.zoom + 1).clamp(4, 18),
                                    )
                                  : null,
                              icon: const Icon(Icons.add),
                            ),
                            IconButton(
                              tooltip: 'Отдалить карту',
                              onPressed: widget.enabled
                                  ? () => _camera.move(
                                      _camera.camera.center,
                                      (_camera.camera.zoom - 1).clamp(4, 18),
                                    )
                                  : null,
                              icon: const Icon(Icons.remove),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      ),
      if (_tileError)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(switch (_tileFailure) {
                MapFailureKind.configuration => 'Ключ карт не принят.',
                MapFailureKind.limit => 'Лимит сервиса карт.',
                MapFailureKind.network => 'Нет связи с картами.',
                MapFailureKind.timeout => 'Карты не ответили.',
                _ => 'Карта не загрузилась.',
              }),
              TextButton(
                onPressed: widget.enabled
                    ? () => setState(() {
                        widget.session?.retry();
                        _tileError = false;
                        _reload++;
                      })
                    : null,
                child: const Text('Повторить'),
              ),
            ],
          ),
        ),
    ],
  );
}

class MapAttribution extends StatelessWidget {
  const MapAttribution({super.key});
  Future<void> _open(BuildContext context, String address) async {
    try {
      if (await launchUrl(
        Uri.parse(address),
        mode: LaunchMode.externalApplication,
      )) {
        return;
      }
    } catch (_) {
      /* Внешняя ссылка не является обязательной рабочей операцией. */
    }
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Не удалось открыть ссылку.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    children: [
      for (final item in const [
        ('© OpenStreetMap', 'https://www.openstreetmap.org/copyright'),
        ('© OpenMapTiles', 'https://openmaptiles.org/'),
        ('© CARTO', 'https://carto.com/attributions'),
        ('Powered by Geoapify', 'https://www.geoapify.com/'),
      ])
        TextButton(
          style: TextButton.styleFrom(
            textStyle: Theme.of(context).textTheme.labelSmall!
                .copyWith(fontSize: 11),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          ),
          onPressed: () => unawaited(_open(context, item.$2)),
          child: Text(item.$1),
        ),
    ],
  );
}
