import 'dart:async';

import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../maps/map_location_action.dart';
import '../maps/map_tiles.dart';
import '../maps/passenger_address_controller.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import '../ui/map_panel_layout.dart';
import '../ui/orbita_map.dart';
import '../ui/theme.dart';

class MapPointSelection {
  const MapPointSelection(this.point, this.address);
  final GeoPoint point;
  final String? address;
}

class MapPickerScreen extends StatefulWidget {
  const MapPickerScreen({
    required this.controller,
    required this.session,
    required this.field,
    this.device,
    super.key,
  });
  final PassengerAddressController controller;
  final MapTileSession session;
  final AddressField field;
  final DeviceGateway? device;
  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  late GeoPoint _point =
      widget.controller.draft(widget.field).place?.point ?? localMapCenter;
  late final _initial = _point;
  GeoPoint? _focus;
  String? _address, _message;
  Timer? _debounce;
  int _revision = 0;
  bool _loading = false, _paused = false;
  late String _lookupKey;
  MapLocationAction? _location;

  @override
  void initState() {
    super.initState();
    _lookupKey = widget.controller.settings.clientKey;
    widget.controller.addListener(_controllerChanged);
    if (widget.device case final device?) {
      _location = MapLocationAction(
        device: device,
        isAllowed: () => mounted && widget.controller.enabled,
        onLocation: (point) => _pointChanged(point, focus: true),
        onError: _showError,
      );
    }
    unawaited(_lookup(++_revision, _point));
  }

  void _showError(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  void _controllerChanged() {
    final paused = !widget.controller.enabled;
    final key = widget.controller.settings.clientKey;
    if (_paused == paused && _lookupKey == key) return;
    _paused = paused;
    _lookupKey = key;
    ++_revision;
    _debounce?.cancel();
    _location?.cancel(notify: false);
    _loading = false;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {});
      if (!_paused) unawaited(_lookup(_revision, _point));
    });
  }

  void _pointChanged(GeoPoint point, {bool focus = false}) {
    if (!widget.controller.enabled || !point.valid) return;
    if (point.latitude == _point.latitude &&
        point.longitude == _point.longitude &&
        !focus) {
      return;
    }
    final revision = ++_revision;
    _debounce?.cancel();
    widget.controller.cancelPointPreview();
    setState(() {
      _point = point;
      _focus = focus ? point : null;
      _address = null;
      _message = null;
      _loading = true;
    });
    _debounce = Timer(
      const Duration(milliseconds: 450),
      () => unawaited(_lookup(revision, point)),
    );
  }

  bool _current(int revision) =>
      mounted && revision == _revision && widget.controller.enabled;

  Future<void> _lookup(int revision, GeoPoint point) async {
    if (!_current(revision)) return;
    _loading = true;
    try {
      final address = await widget.controller.previewPoint(point);
      if (!_current(revision)) return;
      setState(() {
        _address = address;
        _message = address == null
            ? 'Адрес у точки не найден. Можно уточнить его вручную.'
            : null;
      });
    } on MapFailure catch (failure) {
      if (_current(revision) && failure.kind != MapFailureKind.cancelled) {
        setState(() => _message = failure.message);
      }
    } catch (_) {
      if (_current(revision)) {
        setState(() => _message = 'Не удалось определить адрес точки.');
      }
    } finally {
      if (_current(revision)) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    ++_revision;
    _debounce?.cancel();
    widget.controller.removeListener(_controllerChanged);
    if (_loading) widget.controller.cancelPointPreview();
    _location?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([widget.controller, ?_location]),
    builder: (context, _) => Stack(
      fit: StackFit.expand,
      children: [
        ExcludeSemantics(
          excluding: !widget.controller.foreground,
          child: Scaffold(
            appBar: AppBar(
              title: const Text('Выбор точки'),
              backgroundColor: OrbitaPalette.of(context).surface,
            ),
            body: SafeArea(
              child: MapPanelLayout(
                compactHeight:
                    255 + (MediaQuery.textScalerOf(context).scale(14) - 14) * 5,
                mapBuilder: (context, covered) => LayoutBuilder(
                  builder: (context, area) => OrbitaMap(
                    height: area.maxHeight,
                    coveredHeight: covered,
                    fitHeight: true,
                    borderRadius: BorderRadius.zero,
                    session: widget.session,
                    enabled: widget.controller.enabled,
                    initialCenter: _initial,
                    initialZoom: 17,
                    focusPoint: _focus,
                    picking: true,
                    onLocate: _location?.locate,
                    locating: _location?.busy ?? false,
                    onCenterChanged: _pointChanged,
                  ),
                ),
                panelBuilder: (context, scroll, visibleMapHeight) =>
                    CustomScrollView(
                      controller: scroll,
                      slivers: [
                        SliverPadding(
                          padding: const EdgeInsets.fromLTRB(18, 10, 18, 16),
                          sliver: SliverToBoxAdapter(
                            child: Column(
                              key: const Key('map-point-panel'),
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Center(
                                  child: Container(
                                    width: 36,
                                    height: 4,
                                    decoration: BoxDecoration(
                                      color: OrbitaPalette.of(context).outline,
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  widget.field == AddressField.pickup
                                      ? 'Адрес подачи'
                                      : 'Пункт назначения',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const SizedBox(height: 8),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    _loading
                                        ? 'Определяем адрес…'
                                        : _address ?? _message ?? 'Передвиньте карту или нажмите на нужную точку.',
                                    key: const Key('map-point-address'),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                FullWidthAction(
                                  'Выбрать точку',
                                  key: const Key('confirm-map-point'),
                                  onPressed:
                                      widget.controller.enabled &&
                                          _point.valid &&
                                          !_loading
                                      ? () => Navigator.pop(
                                          context,
                                          MapPointSelection(_point, _address),
                                        )
                                      : null,
                                ),
                                TextButton(
                                  onPressed: () => Navigator.pop(context),
                                  child: const Text('Вернуться к адресу'),
                                ),
                                if (visibleMapHeight < 180)
                                  const MapAttribution(compact: true),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
              ),
            ),
          ),
        ),
        if (!widget.controller.foreground)
          ColoredBox(
            key: const Key('map-background-cover'),
            color: OrbitaPalette.of(context).background,
          ),
      ],
    ),
  );
}
