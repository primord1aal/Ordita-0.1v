import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';

import '../maps/address_models.dart';
import '../maps/map_tiles.dart';
import '../maps/route_preview.dart';
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
    this.onLocate,
    this.locating = false,
    this.fitHeight = false,
    this.initialZoom = 16,
    this.userPosition,
    this.route,
    this.coveredHeight = 0,
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
  final VoidCallback? onLocate;
  final bool locating, fitHeight;
  final double initialZoom;
  final GeoPoint? userPosition;
  final RoutePreview? route;
  final double coveredHeight;

  static double minimumFittedHeight(BuildContext context, double width) {
    final measured = MapAttribution.measuredHeight(
      context,
      (width - 70).clamp(1, double.infinity),
    );
    return 180 +
        (measured > 48
            ? MapAttribution.measuredHeight(context, width, compact: true) + 20
            : 0);
  }

  @override
  State<OrbitaMap> createState() => _OrbitaMapState();
}

class _OrbitaMapState extends State<OrbitaMap> {
  final _camera = MapController();
  bool _ready = false, _tileError = false;
  MapFailureKind _tileFailure = MapFailureKind.unavailable;
  int _reload = 0;
  Timer? _cameraTimer;
  GeoPoint? _pickingPoint;
  double _visibleHeight = 0, _mapWidth = 0;

  Offset get _pinOffset => Offset(_mapWidth / 2, _visibleHeight / 2);

  void _focus(GeoPoint point, {double? zoom}) => _camera.move(
    LatLng(point.latitude, point.longitude),
    zoom ?? _camera.camera.zoom,
    offset: Offset(0, -widget.coveredHeight / 2),
  );

  void _frameSelection() {
    if (!_ready || !widget.enabled || _visibleHeight < 140) return;
    final route = widget.route;
    final points = [
      if (route != null) ...route.points,
      if (widget.pickup != null) widget.pickup!.point,
      if (widget.destination != null) widget.destination!.point,
    ];
    if (widget.pickup != null &&
        widget.destination != null &&
        points.length >= 2) {
      _camera.fitCamera(
        CameraFit.coordinates(
          coordinates: [
            for (final point in points) LatLng(point.latitude, point.longitude),
          ],
          padding: EdgeInsets.fromLTRB(
            widget.coveredHeight > 0 ? 84 : 46,
            widget.coveredHeight > 0 ? 84 : 40,
            70,
            widget.coveredHeight +
                (widget.coveredHeight > 0
                    ? MapAttribution.measuredHeight(
                            context,
                            (_mapWidth - 70).clamp(1, double.infinity),
                          ) +
                          50
                    : 54),
          ),
          maxZoom: 17,
          minZoom: 4,
        ),
      );
    } else if (widget.focusPoint case final point?) {
      _focus(point, zoom: 17);
    } else if (widget.picking) {
      _focus(_pickingPoint ?? widget.focusPoint ?? widget.initialCenter);
    }
  }

  void _scheduleFrame() {
    _cameraTimer?.cancel();
    _cameraTimer = Timer(const Duration(milliseconds: 300), () {
      if (mounted) _frameSelection();
    });
  }

  // Detailed, readable cartography in both app themes. The map palette is
  // independent of the controls; dark-matter hides useful address detail.
  void _matchTheme() => widget.session?.setStyle(MapTileStyle.osmCarto);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _matchTheme();
  }

  @override
  void didUpdateWidget(covariant OrbitaMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.session != widget.session) _matchTheme();
    if (widget.picking &&
        widget.focusPoint != null &&
        widget.focusPoint != oldWidget.focusPoint) {
      _pickingPoint = widget.focusPoint;
    }
    if (widget.focusPoint != oldWidget.focusPoint ||
        widget.route != oldWidget.route ||
        widget.coveredHeight != oldWidget.coveredHeight ||
        widget.height != oldWidget.height ||
        widget.enabled != oldWidget.enabled) {
      _scheduleFrame();
    }
    if (oldWidget.session != widget.session) _tileError = false;
  }

  @override
  void dispose() {
    _cameraTimer?.cancel();
    _camera.dispose();
    super.dispose();
  }

  void _failed(Object error) {
    if (_tileError ||
        !widget.enabled ||
        (error is MapFailure && error.kind == MapFailureKind.cancelled)) {
      return;
    }
    final session = widget.session;
    final style = session?.style;
    final revision = _reload;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          widget.enabled &&
          !_tileError &&
          identical(widget.session, session) &&
          session?.style == style &&
          revision == _reload) {
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
      final session = widget.session;
      final style = session?.style;
      final revision = _reload;
      final attributionBelow =
          widget.coveredHeight == 0 &&
          MapAttribution.measuredHeight(
                context,
                (constraints.maxWidth - 70).clamp(1, double.infinity),
              ) >
              (widget.height * 0.25).clamp(48, 100);
      final canvasHeight =
          widget.fitHeight && attributionBelow && session != null
          ? (widget.height -
                    MapAttribution.measuredHeight(
                      context,
                      constraints.maxWidth,
                      compact: true,
                    ) -
                    20)
                .clamp(140.0, widget.height)
          : widget.height;
      _visibleHeight = (canvasHeight - widget.coveredHeight).clamp(
        0.0,
        canvasHeight,
      );
      _mapWidth = constraints.maxWidth;
      final showControls = _visibleHeight >= 180;
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: canvasHeight,
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
                            initialZoom: widget.initialZoom,
                            minZoom: 4,
                            maxZoom: 18,
                            backgroundColor: OrbitaPalette.of(context).mapLand,
                            onMapReady: () {
                              _ready = true;
                              WidgetsBinding.instance.addPostFrameCallback((_) {
                                if (mounted) _frameSelection();
                              });
                            },
                            interactionOptions: InteractionOptions(
                              flags: widget.enabled
                                  ? InteractiveFlag.all &
                                        ~InteractiveFlag.rotate
                                  : InteractiveFlag.none,
                            ),
                            onTap: !widget.picking || !widget.enabled
                                ? null
                                : (_, point) {
                                    _pickingPoint = GeoPoint(
                                      point.latitude,
                                      point.longitude,
                                    );
                                    _focus(_pickingPoint!);
                                    widget.onCenterChanged?.call(
                                      GeoPoint(point.latitude, point.longitude),
                                    );
                                  },
                            onPositionChanged: (camera, hasGesture) {
                              if (widget.picking &&
                                  widget.enabled &&
                                  hasGesture) {
                                final selected = camera.screenOffsetToLatLng(
                                  _pinOffset,
                                );
                                _pickingPoint = GeoPoint(
                                  selected.latitude,
                                  selected.longitude,
                                );
                                widget.onCenterChanged?.call(_pickingPoint!);
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
                                errorTileCallback: (_, error, _) {
                                  if (identical(widget.session, session) &&
                                      session?.style == style &&
                                      _reload == revision) {
                                    _failed(error);
                                  }
                                },
                              ),
                            if (widget.route case final route?)
                              PolylineLayer(
                                key: const Key('road-route'),
                                polylines: [
                                  for (final line in route.lines)
                                    Polyline(
                                      points: [
                                        for (final point in line)
                                          LatLng(
                                            point.latitude,
                                            point.longitude,
                                          ),
                                      ],
                                      color: const Color(0xffA6533A),
                                      strokeWidth: 5,
                                      borderColor: const Color(0xffFAFAF4),
                                      borderStrokeWidth: 2,
                                    ),
                                ],
                              ),
                            MarkerLayer(
                              markers: [
                                if (widget.userPosition case final position?)
                                  Marker(
                                    point: LatLng(
                                      position.latitude,
                                      position.longitude,
                                    ),
                                    width: 24,
                                    height: 24,
                                    child: Tooltip(
                                      message: 'Моё местоположение',
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          color: OrbitaPalette.of(context)
                                              .accent,
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: OrbitaPalette.of(context)
                                                .onAccent,
                                            width: 3,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
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
                            child: Align(
                              alignment: Alignment.topCenter,
                              child: SizedBox(
                                height: _visibleHeight,
                                child: Center(
                                  child: Icon(
                                    Icons.center_focus_strong,
                                    color: OrbitaPalette.of(context).text,
                                    size: 46,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        if (showControls)
                          Positioned(
                            top: widget.picking ? 12 : null,
                            bottom: widget.picking
                                ? null
                                : widget.controls == MapControls.driver
                                ? 12
                                : widget.coveredHeight + 8,
                            right: widget.controls == MapControls.driver
                                ? 16
                                : 8,
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
                                          borderRadius: BorderRadius.circular(
                                            17,
                                          ),
                                        ),
                                        child: IconButton(
                                          tooltip: 'Моё местоположение',
                                          onPressed:
                                              widget.enabled && !widget.locating
                                              ? widget.onLocate
                                              : null,
                                          icon: _locationIcon(),
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
                                                  (_camera.camera.zoom + 1)
                                                      .clamp(4, 18),
                                                )
                                              : null,
                                          icon: const Icon(Icons.add),
                                        ),
                                        IconButton(
                                          tooltip: 'Отдалить карту',
                                          onPressed: widget.enabled
                                              ? () => _camera.move(
                                                  _camera.camera.center,
                                                  (_camera.camera.zoom - 1)
                                                      .clamp(4, 18),
                                                )
                                              : null,
                                          icon: const Icon(Icons.remove),
                                        ),
                                        if (widget.onLocate != null)
                                          IconButton(
                                            tooltip: 'Моё местоположение',
                                            onPressed:
                                                widget.enabled &&
                                                    !widget.locating
                                                ? widget.onLocate
                                                : null,
                                            icon: _locationIcon(),
                                          ),
                                      ],
                                    ),
                            ),
                          ),
                        if (!attributionBelow && _visibleHeight >= 180)
                          Positioned(
                            left: 8,
                            right: 62,
                            bottom: widget.coveredHeight + 8,
                            child: const MapAttribution(),
                          ),
                        if (_tileError)
                          Positioned(
                            top:
                                widget.coveredHeight > 0 &&
                                    _visibleHeight >= 180
                                ? 64
                                : 8,
                            left: 8,
                            right: 72,
                            child: Material(
                              color: OrbitaPalette.of(context).surface,
                              borderRadius: BorderRadius.circular(12),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: (_visibleHeight * .45).clamp(
                                    48,
                                    180,
                                  ),
                                ),
                                child: SingleChildScrollView(
                                  padding: const EdgeInsets.all(8),
                                  child: Wrap(
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(switch (_tileFailure) {
                                        MapFailureKind.configuration =>
                                          'Ключ карт не принят.',
                                        MapFailureKind.limit =>
                                          'Лимит сервиса карт.',
                                        MapFailureKind.network =>
                                          'Нет связи с картами.',
                                        MapFailureKind.timeout =>
                                          'Карты не ответили.',
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
                              ),
                            ),
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
        ],
      );
    },
  );

  Widget _locationIcon() => widget.locating
      ? const SizedBox.square(
          dimension: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            semanticsLabel: 'Определяем местоположение',
          ),
        )
      : const Icon(Icons.my_location);
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
  static double measuredHeight(
    BuildContext context,
    double width, {
    bool compact = false,
  }) {
    final style = Theme.of(context).textTheme.labelSmall!
        .copyWith(fontSize: 11);
    double runWidth = 0, runHeight = 0, height = 0;
    for (final item in _links) {
      final painter = TextPainter(
        text: TextSpan(text: item.$1, style: style),
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      )..layout(maxWidth: (width - 8).clamp(1, double.infinity));
      final childWidth = (painter.width + 8).clamp(
        compact ? 48.0 : 0.0,
        double.infinity,
      );
      final childHeight = (painter.height + 6).clamp(
        compact ? 48.0 : 0.0,
        double.infinity,
      );
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
