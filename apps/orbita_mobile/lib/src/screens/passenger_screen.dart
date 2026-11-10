import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../maps/geoapify_service.dart';
import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import '../maps/passenger_address_controller.dart';
import '../ui/components.dart';
import '../ui/orbita_map.dart';
import '../ui/theme.dart';
import 'map_picker_screen.dart';

class PassengerScreen extends StatefulWidget {
  const PassengerScreen({
    required this.mapSettings,
    this.enabled = true,
    this.foreground = true,
    this.serviceFactory,
    this.tileSessionFactory,
    super.key,
  });
  final MapSettings mapSettings;
  final bool enabled;
  final bool foreground;
  final AddressService Function(String)? serviceFactory;
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
  MapTileSession? _tiles;
  String _tileKey = '';
  bool _choosing = false;
  @override
  void initState() {
    super.initState();
    _controller.setEnabled(widget.enabled, foreground: widget.foreground);
    _controller.addListener(_changed);
    _changed();
  }

  void _changed() {
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
      if (!_controller.enabled) _tiles?.cancel();
    }
  }

  @override
  void dispose() {
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
    FocusScope.of(context).unfocus();
    setState(() => _choosing = true);
    final point = await Navigator.of(context).push<GeoPoint>(
      MaterialPageRoute(
        builder: (_) => MapPickerScreen(
          controller: _controller,
          session: session,
          field: field,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _choosing = false);
    if (point != null && _controller.enabled) {
      await _controller.choosePoint(field, point);
    }
  }

  Widget _field(AddressField field) {
    final pickup = field == AddressField.pickup;
    final item = _controller.draft(field);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: Key(pickup ? 'pickup' : 'destination'),
          controller: pickup ? _pickup : _destination,
          maxLines: null,
          maxLength: 250,
          enabled: _controller.enabled,
          onTap: () => _controller.focus(field),
          onChanged: (value) => _controller.edit(field, value),
          onSubmitted: (_) => _controller.searchNow(field),
          textInputAction: TextInputAction.search,
          decoration: InputDecoration(
            labelText: pickup ? 'Откуда' : 'Куда',
            prefixIcon: Icon(pickup ? Icons.trip_origin : Icons.place_outlined),
            counterText: '',
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
        if (item.place case final place?)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              'Точка выбрана: ${place.point.caption}',
              style: const TextStyle(fontSize: 12),
            ),
          ),
        if (_controller.activeField == field) ...[
          if (item.busy)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: LinearProgressIndicator(minHeight: 2),
            ),
          for (final place in item.suggestions)
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 4,
                vertical: 4,
              ),
              title: Text(place.label),
              leading: const Icon(
                Icons.place_outlined,
                color: OrbitaColors.accent,
              ),
              onTap: !_controller.enabled
                  ? null
                  : () {
                      _controller.select(field, place);
                      FocusScope.of(context).unfocus();
                    },
            ),
          if (item.message != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Semantics(liveRegion: true, child: Text(item.message!)),
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
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) => CustomScrollView(
      key: const Key('passenger-scroll'),
      slivers: [
        const SliverToBoxAdapter(child: BrandHeader()),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
          sliver: SliverList.list(
            children: [
              OrbitaMap(
                key: const Key('passenger-map'),
                height: (MediaQuery.sizeOf(context).height * 0.36).clamp(
                  230,
                  420,
                ),
                session: _tiles,
                enabled: _controller.enabled && !_choosing,
                pickup: _controller.pickup.place,
                destination: _controller.destination.place,
                focusPoint: _controller
                    .draft(_controller.activeField)
                    .place
                    ?.point,
              ),
              if (_tiles != null) const MapAttribution(),
              const SizedBox(height: 16),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _field(AddressField.pickup),
                    const SizedBox(height: 12),
                    _field(AddressField.destination),
                    const SizedBox(height: 16),
                    const FullWidthAction(
                      'Заказать такси',
                      key: Key('create-order'),
                      onPressed: null,
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Создание заказов ещё не подключено.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (_tiles != null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Для поиска адресов введённый текст и выбранная точка передаются Geoapify. Черновик не отправляется в службу такси.',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}
