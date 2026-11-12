import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../maps/address_models.dart';
import '../maps/map_tiles.dart';
import 'theme.dart';

enum MapControls { passenger, driver }

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
    this.borderRadius = const BorderRadius.all(Radius.circular(18)),
    this.controls = MapControls.passenger,
    super.key,
  });
  final MapTileSession? session;
  final double height;
  final bool enabled, picking;
  final AddressPlace? pickup, destination;
  final GeoPoint initialCenter;
  final GeoPoint? focusPoint;
  final ValueChanged<GeoPoint>? onCenterChanged;
  final BorderRadiusGeometry borderRadius;
  final MapControls controls;
  @override
  State<OrbitaMap> createState() => _OrbitaMapState();
}

class _OrbitaMapState extends State<OrbitaMap> {
  final _camera = MapController();
  bool _ready = false, _tileError = false;
  MapFailureKind _tileFailure = MapFailureKind.unavailable;
  int _reload = 0;
  void _matchTheme() => widget.session?.setStyle(
    Theme.of(context).brightness == Brightness.dark
        ? MapTileStyle.darkMatter
        : MapTileStyle.positron,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _matchTheme();
  }

  @override
  void didUpdateWidget(covariant OrbitaMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) _matchTheme();
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
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final attributionBelow =
          MapAttribution.measuredHeight(
            context,
            (constraints.maxWidth - 70).clamp(1, double.infinity),
          ) >
          (widget.height * 0.25).clamp(48, 100);
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: widget.height,
            child: ClipRRect(
              borderRadius: widget.borderRadius,
              child: widget.session == null
                  ? ColoredBox(
                      color: OrbitaPalette.of(context).mapLand,
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            'Карта недоступна. Адреса можно ввести вручную.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: OrbitaPalette.of(context).text,
                            ),
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
                            backgroundColor: OrbitaPalette.of(context).mapLand,
                            onMapReady: () => _ready = true,
                            interactionOptions: InteractionOptions(
                              flags:
                                  widget.enabled &&
                                      (widget.picking ||
                                          widget.controls == MapControls.driver)
                                  ? InteractiveFlag.all &
                                        ~InteractiveFlag.rotate
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
                              if (widget.picking &&
                                  widget.enabled &&
                                  hasGesture) {
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
                                key: ValueKey((
                                  widget.session,
                                  widget.session!.style,
                                  _reload,
                                )),
                                tileProvider: OrbitaTileProvider(
                                  widget.session!,
                                ),
                                userAgentPackageName: 'ru.orbita.taxi.dev',
                                maxNativeZoom: 18,
                                panBuffer: 0,
                                keepBuffer: 0,
                                errorTileCallback: (_, error, _) =>
                                    _failed(error),
                              ),
                            MarkerLayer(
                              markers: [
                                for (final entry in [
                                  (
                                    widget.pickup,
                                    'Откуда',
                                    OrbitaPalette.of(context).text,
                                  ),
                                  (
                                    widget.destination,
                                    'Куда',
                                    OrbitaPalette.of(context).accent,
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
                                        child: entry.$2 == 'Откуда'
                                            ? Center(
                                                child: Container(
                                                  width: 32,
                                                  height: 32,
                                                  alignment: Alignment.center,
                                                  decoration: BoxDecoration(
                                                    color: entry.$3,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          9,
                                                        ),
                                                    border: Border.all(
                                                      color: OrbitaPalette.of(
                                                        context,
                                                      ).surface,
                                                      width: 2,
                                                    ),
                                                  ),
                                                  child: Text(
                                                    'А',
                                                    style: TextStyle(
                                                      color: OrbitaPalette.of(
                                                        context,
                                                      ).surface,
                                                      fontWeight:
                                                          FontWeight.w700,
                                                    ),
                                                  ),
                                                ),
                                              )
                                            : Stack(
                                                alignment: Alignment.topCenter,
                                                children: [
                                                  Icon(
                                                    Icons.location_pin,
                                                    color: entry.$3,
                                                    size: 44,
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                          top: 8,
                                                        ),
                                                    child: Text(
                                                      'Б',
                                                      style: TextStyle(
                                                        color: OrbitaPalette.of(
                                                          context,
                                                        ).onAccent,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                      ),
                                    ),
                              ],
                            ),
                          ],
                        ),
                        if (widget.picking)
                          IgnorePointer(
                            child: Center(
                              child: Icon(
                                Icons.center_focus_strong,
                                color: OrbitaPalette.of(context).text,
                                size: 46,
                              ),
                            ),
                          ),
                        Positioned(
                          top: widget.picking ? 8 : null,
                          bottom: widget.picking
                              ? null
                              : widget.controls == MapControls.driver
                              ? 12
                              : 8,
                          right: widget.controls == MapControls.driver ? 16 : 8,
                          child: Material(
                            color: OrbitaPalette.of(context).surface,
                            borderRadius: BorderRadius.circular(14),
                            child: widget.controls == MapControls.driver
                                ? SizedBox(
                                    width: 48,
                                    height: 48,
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(
                                        border: Border.all(
                                          color: OrbitaPalette.of(context)
                                              .outline,
                                        ),
                                        borderRadius: BorderRadius.circular(17),
                                      ),
                                      child: IconButton(
                                        tooltip: 'Моё местоположение',
                                        onPressed: null,
                                        icon: const Icon(Icons.my_location),
                                      ),
                                    ),
                                  )
                                : Column(
                                    children: [
                                      IconButton(
                                        tooltip: 'Приблизить карту',
                                        onPressed: widget.enabled
                                            ? () => _camera.move(
                                                _camera.camera.center,
                                                (_camera.camera.zoom + 1).clamp(
                                                  4,
                                                  18,
                                                ),
                                              )
                                            : null,
                                        icon: const Icon(Icons.add),
                                      ),
                                      IconButton(
                                        tooltip: 'Отдалить карту',
                                        onPressed: widget.enabled
                                            ? () => _camera.move(
                                                _camera.camera.center,
                                                (_camera.camera.zoom - 1).clamp(
                                                  4,
                                                  18,
                                                ),
                                              )
                                            : null,
                                        icon: const Icon(Icons.remove),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                        if (!attributionBelow)
                          Positioned(
                            left: 8,
                            right: 62,
                            bottom: 8,
                            child: const MapAttribution(),
                          ),
                      ],
                    ),
            ),
          ),
          if (widget.session != null && attributionBelow)
            const Padding(
              padding: EdgeInsets.only(top: 4, bottom: 16),
              child: MapAttribution(compact: true),
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
    },
  );
}

class MapAttribution extends StatelessWidget {
  const MapAttribution({this.compact = false, super.key});
  final bool compact;
  static const _links = [
    ('© OpenStreetMap', 'https://www.openstreetmap.org/copyright'),
    ('© OpenMapTiles', 'https://openmaptiles.org/'),
    ('© CARTO', 'https://carto.com/attributions'),
    ('Powered by Geoapify', 'https://www.geoapify.com/'),
  ];

  /// Измерение фактической высоты Wrap. При крупном тексте ссылки располагаются
  /// под картой и не закрывают её кнопки, маркеры или центральный прицел.
  static double measuredHeight(BuildContext context, double width) {
    final style = Theme.of(context).textTheme.labelSmall!
        .copyWith(fontSize: 11);
    double runWidth = 0, runHeight = 0, height = 0;
    for (final item in _links) {
      final painter = TextPainter(
        text: TextSpan(text: item.$1, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: (width - 8).clamp(1, double.infinity));
      final childWidth = painter.width + 8;
      final childHeight = painter.height + 6;
      painter.dispose();
      if (runWidth > 0 && runWidth + childWidth > width) {
        height += runHeight;
        runWidth = 0;
        runHeight = 0;
      }
      runWidth += childWidth;
      if (childHeight > runHeight) runHeight = childHeight;
    }
    return height + runHeight;
  }

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
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      color: OrbitaPalette.of(context).surface.withValues(alpha: 0.92),
      borderRadius: BorderRadius.circular(9),
    ),
    child: Wrap(
      alignment: WrapAlignment.start,
      children: [
        for (final item in _links)
          TextButton(
            key: ValueKey('attribution-${item.$2}'),
            style: TextButton.styleFrom(
              textStyle: Theme.of(context).textTheme.labelSmall!
                  .copyWith(fontSize: 11),
              minimumSize: compact ? const Size(48, 48) : Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
            ),
            onPressed: () => unawaited(_open(context, item.$2)),
            child: Text(item.$1),
          ),
      ],
    ),
  );
}
