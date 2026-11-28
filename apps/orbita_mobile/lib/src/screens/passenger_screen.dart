import 'dart:async';

import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../orders/dispatch_controller.dart';
import '../orders/dispatch_panel.dart';
import '../maps/geoapify_service.dart';
import '../maps/map_settings.dart';
import '../maps/map_location_action.dart';
import '../maps/route_preview.dart';
import '../platform/device_gateway.dart';
import '../ui/map_panel_layout.dart';
import '../maps/map_tiles.dart';
import '../maps/passenger_address_controller.dart';
import '../ui/components.dart';
import '../ui/orbita_map.dart';
import '../ui/theme.dart';
import 'map_picker_screen.dart';

class PassengerScreen extends StatefulWidget {
  const PassengerScreen({
    required this.mapSettings,
    this.device,
    this.dispatch,
    this.enabled = true,
    this.foreground = true,
    this.serviceFactory,
    this.routeServiceFactory,
    this.tileSessionFactory,
    super.key,
  });
  final MapSettings mapSettings;
  final DeviceGateway? device;
  final DispatchController? dispatch;
  final bool enabled;
  final bool foreground;
  final AddressService Function(String)? serviceFactory;
  final RouteService Function(String)? routeServiceFactory;
  final MapTileSession Function(String)? tileSessionFactory;
  @override
  State<PassengerScreen> createState() => _PassengerScreenState();
}

class _PassengerScreenState extends State<PassengerScreen> {
  late final _controller = PassengerAddressController(
    widget.mapSettings,
    serviceFactory: widget.serviceFactory,
  );
  final _pickup = TextEditingController(),
      _destination = TextEditingController();
  final _pickupFocus = FocusNode(), _destinationFocus = FocusNode();
  late final _route = RoutePreviewController(
    widget.mapSettings,
    serviceFactory: widget.routeServiceFactory,
  );
  bool _searching = false;
  MapTileSession? _tiles;
  String _tileKey = '';
  bool _choosing = false;
  MapLocationAction? _location;
  GeoPoint? _position;
  int? _pickupRevisionWhenLocating;
  String? _gpsMessage;
  String? _lastActiveOrder;
  @override
  void initState() {
    super.initState();
    _controller.setEnabled(widget.enabled, foreground: widget.foreground);
    _controller.addListener(_changed);
    _lastActiveOrder = widget.dispatch?.hasActiveTrip == true
        ? widget.dispatch?.state?.trip?.id
        : null;
    widget.dispatch?.addListener(_dispatchChanged);
    _pickupFocus.addListener(_focusChanged);
    _destinationFocus.addListener(_focusChanged);
    if (widget.device case final device?) {
      _location = MapLocationAction(
        device: device,
        isAllowed: () =>
            mounted && _controller.enabled && !_choosing && !_orderLocked,
        onLocation: (point) async {
          setState(() {
            _position = point;
            _gpsMessage = null;
          });
          if (_pickupRevisionWhenLocating != _controller.pickupInputRevision) {
            return;
          }
          await _controller.useCurrentLocation(
            point,
            replace: _location?.automaticRequest != true,
          );
        },
        onError: (message) {
          if (_location?.automaticRequest == true) {
            if (mounted) setState(() => _gpsMessage = message);
            return;
          }
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(message),
                action: _location?.needsSettings == true
                    ? SnackBarAction(
                        label: 'Настройки',
                        onPressed: () => unawaited(_location!.openSettings()),
                      )
                    : null,
              ),
            );
          }
        },
      );
    }
    _changed();
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLocate());
  }

  void _autoLocate() {
    if (mounted && widget.enabled && widget.foreground && !_orderLocked) {
      unawaited(_locatePickup(automatic: true));
    }
  }

  Future<void> _locatePickup({bool automatic = false}) async {
    final location = _location;
    if (location == null || location.busy) return;
    _pickupRevisionWhenLocating = _controller.pickupInputRevision;
    if (automatic) {
      await location.locateAutomatically();
    } else {
      await location.locate();
    }
  }

  void _focusChanged() {
    final field = _pickupFocus.hasFocus
        ? AddressField.pickup
        : _destinationFocus.hasFocus
        ? AddressField.destination
        : null;
    if (field == null) return;
    if (_controller.activeField != field) _controller.focus(field);
    if (!_searching) setState(() => _searching = true);
  }

  void _closeSearch() {
    _pickupFocus.unfocus();
    _destinationFocus.unfocus();
    if (_searching) setState(() => _searching = false);
  }

  bool get _orderLocked =>
      widget.dispatch?.hasActiveTrip == true ||
      widget.dispatch?.pending != null;
  AddressPlace? _place(AddressField field) {
    final trip = widget.dispatch?.state?.trip;
    if (trip?.active == true) {
      final point = field == AddressField.pickup
          ? trip!.pickup
          : trip!.destination;
      return AddressPlace(point.address, point.point);
    }
    return _controller.draft(field).place;
  }

  void _dispatchChanged() {
    if (!mounted) return;
    final dispatch = widget.dispatch;
    final trip = dispatch?.state?.trip;
    if (dispatch?.hasCurrentSnapshot == true) {
      if (trip?.active == true) {
        _lastActiveOrder = trip!.id;
      } else if (_lastActiveOrder != null && _lastActiveOrder == trip?.id) {
        _lastActiveOrder = null;
        if (trip!.status == 'completed') _controller.clearTripDraft();
        if (widget.enabled) {
          ScaffoldMessenger.maybeOf(context)?.showSnackBar(
            SnackBar(
              content: Text(trip.label),
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    }
    if (_orderLocked) {
      _location?.cancel(notify: false);
      _closeSearch();
    }
    _changed();
  }

  void _changed() {
    _route.update(
      _place(AddressField.pickup)?.point,
      _place(AddressField.destination)?.point,
      enabled: _controller.enabled && !_choosing,
    );
    for (final entry in [
      (AddressField.pickup, _pickup),
      (AddressField.destination, _destination),
    ]) {
      final value = widget.dispatch?.hasActiveTrip == true
          ? _place(entry.$1)!.label
          : _controller.draft(entry.$1).text;
      if (entry.$2.text != value) {
        entry.$2.value = TextEditingValue(
          text: value,
          selection: TextSelection.collapsed(offset: value.length),
        );
      }
    }
    final key = widget.mapSettings.clientKey;
    if (_tileKey != key) {
      _tiles?.close();
      _tileKey = key;
      _tiles = key.isEmpty
          ? null
          : (widget.tileSessionFactory ??
                (key) => MapTileSession(
                  key,
                  transport: widget.mapSettings.transport(),
                ))(key);
    }
  }

  @override
  void didUpdateWidget(covariant PassengerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoLocate());
    if (oldWidget.dispatch != widget.dispatch) {
      oldWidget.dispatch?.removeListener(_dispatchChanged);
      _lastActiveOrder = widget.dispatch?.hasActiveTrip == true
          ? widget.dispatch?.state?.trip?.id
          : null;
      widget.dispatch?.addListener(_dispatchChanged);
      _changed();
    }
    if (oldWidget.enabled != widget.enabled ||
        oldWidget.foreground != widget.foreground) {
      _controller.setEnabled(widget.enabled, foreground: widget.foreground);
      if (!_controller.enabled) {
        _tiles?.cancel();
        _location?.cancel(notify: false);
      }
    }
  }

  @override
  void dispose() {
    _location?.dispose();
    _route.dispose();
    _pickupFocus.dispose();
    _destinationFocus.dispose();
    widget.dispatch?.removeListener(_dispatchChanged);
    _controller.removeListener(_changed);
    _controller.dispose();
    _tiles?.close();
    _pickup.dispose();
    _destination.dispose();
    super.dispose();
  }

  Future<void> _choosePoint(AddressField field) async {
    final session = _tiles;
    if (!_controller.enabled || session == null || _choosing || _orderLocked) {
      return;
    }
    _closeSearch();
    _location?.cancel(notify: false);
    setState(() => _choosing = true);
    _changed();
    final selection = await Navigator.of(context).push<MapPointSelection>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          controller: _controller,
          session: session,
          field: field,
          device: widget.device,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _choosing = false);
    _changed();
    if (selection != null && _controller.enabled) {
      await _controller.choosePoint(
        field,
        selection.point,
        address: selection.address,
      );
    }
  }

  Widget _field(AddressField field) {
    final pickup = field == AddressField.pickup;
    final palette = OrbitaPalette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Color.lerp(palette.surface, palette.surfaceVariant, .22),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Color.lerp(palette.outline, palette.surface, .52)!,
        ),
      ),
      child: TextField(
        key: Key(pickup ? 'pickup' : 'destination'),
        controller: pickup ? _pickup : _destination,
        focusNode: pickup ? _pickupFocus : _destinationFocus,
        minLines: 1,
        maxLines: 2,
        maxLength: 250,
        enabled:
            _controller.enabled &&
            widget.dispatch?.hasActiveTrip != true &&
            widget.dispatch?.pending == null,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: palette.text,
        ),
        onTap: () => _controller.focus(field),
        onChanged: (value) => _controller.edit(field, value),
        onSubmitted: (_) => _controller.searchNow(field),
        textInputAction: TextInputAction.search,
        decoration: InputDecoration(
          labelText: pickup ? 'Откуда' : 'Куда',
          labelStyle: TextStyle(fontSize: 12, color: palette.muted),
          floatingLabelStyle: TextStyle(fontSize: 12, color: palette.muted),
          hintText: 'Введите адрес',
          floatingLabelBehavior: FloatingLabelBehavior.always,
          prefixIcon: Icon(
            pickup ? Icons.trip_origin : Icons.place_outlined,
            color: pickup ? palette.text : palette.accent,
          ),
          counterText: '',
          border: InputBorder.none,
          enabledBorder: InputBorder.none,
          focusedBorder: InputBorder.none,
          filled: false,
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
          suffixIcon: IconButton(
            key: Key(pickup ? 'pickup-on-map' : 'destination-on-map'),
            tooltip: pickup
                ? 'Выбрать отправление на карте'
                : 'Выбрать назначение на карте',
            onPressed: _tiles == null || !_controller.enabled || _orderLocked
                ? null
                : () => _choosePoint(field),
            icon: const Icon(Icons.map_outlined),
          ),
        ),
      ),
    );
  }

  Widget _results() {
    final field = _controller.activeField;
    final item = _controller.draft(field);
    final palette = OrbitaPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (item.busy) const LinearProgressIndicator(minHeight: 2),
        for (final place in item.suggestions)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 2,
              vertical: 4,
            ),
            title: Text(place.label),
            leading: Icon(Icons.place_outlined, color: palette.accent),
            onTap: !_controller.enabled
                ? null
                : () {
                    _controller.select(field, place);
                    _closeSearch();
                  },
          ),
        if (item.message != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Semantics(
              liveRegion: true,
              child: Text(
                item.message!,
                style: TextStyle(color: palette.muted),
              ),
            ),
          ),
        if (item.message != null &&
            item.place == null &&
            widget.mapSettings.configured)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: _controller.enabled
                  ? () => _controller.searchNow(field)
                  : null,
              child: const Text('Повторить поиск'),
            ),
          ),
        if (!item.busy && item.suggestions.isEmpty && item.message == null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 18),
            child: Text(
              'Введите населённый пункт, улицу и дом или выберите точку на карте.',
              style: TextStyle(color: palette.muted),
            ),
          ),
      ],
    );
  }

  Widget _routeStatus() {
    if (_route.busy) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Semantics(
          liveRegion: true,
          child: const Text('Строим маршрут…'),
        ),
      );
    }
    if (_route.message case final message?) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(message),
          TextButton(
            onPressed: _controller.enabled ? _route.retry : null,
            child: const Text('Повторить маршрут'),
          ),
        ],
      );
    }
    final route = _route.route;
    if (route == null) return const SizedBox.shrink();
    final distance = route.distanceMeters;
    final duration = route.durationSeconds;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        [
          'Маршрут',
          if (distance != null)
            '${(distance / 1000).toStringAsFixed(1).replaceAll('.', ',')} км',
          if (duration != null) '≈ ${(duration / 60).ceil()} мин',
        ].join(' · '),
        key: const Key('route-summary'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([
      _controller,
      _route,
      ?_location,
      ?widget.dispatch,
    ]),
    builder: (context, _) {
      return PopScope(
        canPop: !_searching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeSearch();
        },
        child: MapWorkLayout(
          searching: _searching,
          scrollKey: const Key('passenger-scroll'),
          map: (context, height) => OrbitaMap(
            key: const Key('passenger-map'),
            height: height,
            workSurface: true,
            borderRadius: BorderRadius.zero,
            session: _tiles,
            enabled: _controller.enabled && !_choosing,
            pickup: _place(AddressField.pickup),
            destination: _place(AddressField.destination),
            route: _route.route,
            focusPoint: _place(_controller.activeField)?.point,
            userPosition: _position,
            onLocate: _orderLocked || _location == null ? null : _locatePickup,
            locating: _location?.busy ?? false,
          ),
          panel: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.dispatch?.hasActiveTrip != true) ...[
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Куда едем?',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    if (_searching)
                      IconButton(
                        tooltip: 'Свернуть поиск',
                        onPressed: _closeSearch,
                        icon: const Icon(Icons.keyboard_arrow_down),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                _field(AddressField.pickup),
                const SizedBox(height: 8),
                _field(AddressField.destination),
                const SizedBox(height: 12),
              ],
              if (_searching)
                _results()
              else ...[
                if (!_orderLocked &&
                    _gpsMessage != null &&
                    _controller.pickup.place == null)
                  Text(
                    _gpsMessage!,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                if (!_orderLocked) _routeStatus(),
                if (widget.dispatch case final dispatch?) ...[
                  PassengerDispatchPanel(
                    controller: dispatch,
                    tripRoute: _route.route,
                  ),
                  if (!dispatch.hasActiveTrip && dispatch.pending == null)
                    FullWidthAction(
                      'Заказать такси',
                      key: const Key('create-order'),
                      onPressed:
                          dispatch.canAct &&
                              _controller.enabled &&
                              _controller.pickup.place != null &&
                              _controller.destination.place != null
                          ? () => dispatch.create(
                              _controller.pickup.place!,
                              _controller.destination.place!,
                            )
                          : null,
                    ),
                ] else ...[
                  const FullWidthAction(
                    'Заказать такси',
                    key: Key('create-order'),
                    onPressed: null,
                  ),
                  const Text('Заказ недоступен.'),
                ],
              ],
            ],
          ),
        ),
      );
    },
  );
}
