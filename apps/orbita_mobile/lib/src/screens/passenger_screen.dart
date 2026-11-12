import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../maps/geoapify_service.dart';
import '../maps/map_settings.dart';
import '../maps/map_location_action.dart';
import '../maps/route_preview.dart';
import '../ui/orbita_brand.dart';
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
    this.enabled = true,
    this.foreground = true,
    this.serviceFactory,
    this.routeServiceFactory,
    this.tileSessionFactory,
    super.key,
  });
  final MapSettings mapSettings;
  final DeviceGateway? device;
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
  @override
  void initState() {
    super.initState();
    _controller.setEnabled(widget.enabled, foreground: widget.foreground);
    _controller.addListener(_changed);
    _pickupFocus.addListener(_focusChanged);
    _destinationFocus.addListener(_focusChanged);
    if (widget.device case final device?) {
      _location = MapLocationAction(
        device: device,
        isAllowed: () => mounted && _controller.enabled && !_choosing,
        onLocation: (point) =>
            _controller.choosePoint(AddressField.pickup, point),
        onError: (message) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          }
        },
      );
    }
    _changed();
  }

  void _focusChanged() {
    if ((_pickupFocus.hasFocus || _destinationFocus.hasFocus) && !_searching) {
      setState(() => _searching = true);
    }
  }

  void _closeSearch() {
    _pickupFocus.unfocus();
    _destinationFocus.unfocus();
    if (_searching) setState(() => _searching = false);
  }

  void _changed() {
    _route.update(
      _controller.pickup.place?.point,
      _controller.destination.place?.point,
      enabled: _controller.enabled && !_choosing,
    );
    for (final entry in [
      (AddressField.pickup, _pickup),
      (AddressField.destination, _destination),
    ]) {
      final value = _controller.draft(entry.$1).text;
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
          : (widget.tileSessionFactory ?? (key) => MapTileSession(key))(key);
    }
  }

  @override
  void didUpdateWidget(covariant PassengerScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
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
    _controller.removeListener(_changed);
    _controller.dispose();
    _tiles?.close();
    _pickup.dispose();
    _destination.dispose();
    super.dispose();
  }

  Future<void> _choosePoint(AddressField field) async {
    final session = _tiles;
    if (!_controller.enabled || session == null || _choosing) return;
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
        enabled: _controller.enabled,
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
            onPressed: _tiles == null || !_controller.enabled
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

  void _addressPrivacy() => showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Поиск и маршрут'),
      content: const Text(
        'Для поиска адресов введённый текст и выбранные точки передаются Geoapify. Обе точки используются для построения маршрута. Черновик не отправляется в службу такси.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Понятно'),
        ),
      ],
    ),
  );

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
    listenable: Listenable.merge([_controller, _route, ?_location]),
    builder: (context, _) {
      final palette = OrbitaPalette.of(context);
      final scaler = MediaQuery.textScalerOf(context);
      final width = MediaQuery.sizeOf(context).width;
      var extraHeight = 0.0;
      for (final draft in [_controller.pickup, _controller.destination]) {
        final painter = TextPainter(
          text: TextSpan(
            text: draft.text.isEmpty ? 'Введите адрес' : draft.text,
            style: DefaultTextStyle.of(context).style.merge(
              const TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: 2,
        )..layout(maxWidth: (width - 132).clamp(1, double.infinity));
        extraHeight += (painter.height - scaler.scale(15) * 1.2).clamp(
          0,
          double.infinity,
        );
        painter.dispose();
      }
      if (_route.busy || _route.route != null || _route.message != null) {
        extraHeight += scaler.scale(16) * 1.4 + 24;
      }
      final compactHeight = 330 + (scaler.scale(15) - 15) * 7;
      return PopScope(
        canPop: !_searching,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _closeSearch();
        },
        child: MapPanelLayout(
          expanded: _searching,
          compactHeight: compactHeight,
          preferredHeight: compactHeight + extraHeight,
          onCollapsed: _closeSearch,
          overlay: Positioned(
            top: 12,
            left: 14,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.sizeOf(context).width - 28,
              ),
              child: Material(
                color: palette.surface,
                borderRadius: BorderRadius.circular(16),
                elevation: 0,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(8, 6, 12, 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const OrbitaLogo(size: 32),
                      if (_route.route == null) ...[
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            'орбита.',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                              color: palette.text,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ),
          mapBuilder: (context, covered) => LayoutBuilder(
            builder: (context, area) => OrbitaMap(
              key: const Key('passenger-map'),
              height: area.maxHeight,
              fitHeight: true,
              coveredHeight: covered,
              borderRadius: BorderRadius.zero,
              session: _tiles,
              enabled: _controller.enabled && !_choosing,
              pickup: _controller.pickup.place,
              destination: _controller.destination.place,
              route: _route.route,
              focusPoint: _controller
                  .draft(_controller.activeField)
                  .place
                  ?.point,
              onLocate: _location?.locate,
              locating: _location?.busy ?? false,
            ),
          ),
          panelBuilder: (context, scroll, visibleMapHeight) => CustomScrollView(
            key: const Key('passenger-scroll'),
            controller: scroll,
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 16),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          decoration: BoxDecoration(
                            color: palette.outline,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
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
                      if (_searching)
                        _results()
                      else ...[
                        _routeStatus(),
                        const FullWidthAction(
                          'Заказать такси',
                          key: Key('create-order'),
                          onPressed: null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Заказ недоступен.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                      TextButton.icon(
                        onPressed: _addressPrivacy,
                        icon: const Icon(Icons.info_outline, size: 18),
                        label: const Text('Как используются адреса'),
                      ),
                      if (_tiles != null && visibleMapHeight < 180)
                        const MapAttribution(compact: true),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
