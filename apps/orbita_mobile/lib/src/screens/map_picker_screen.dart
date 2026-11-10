import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../maps/map_tiles.dart';
import '../maps/passenger_address_controller.dart';
import '../ui/components.dart';
import '../ui/orbita_map.dart';

class MapPickerScreen extends StatefulWidget {
  const MapPickerScreen({
    required this.controller,
    required this.session,
    required this.field,
    super.key,
  });
  final PassengerAddressController controller;
  final MapTileSession session;
  final AddressField field;
  @override
  State<MapPickerScreen> createState() => _MapPickerScreenState();
}

class _MapPickerScreenState extends State<MapPickerScreen> {
  late GeoPoint _point =
      widget.controller.draft(widget.field).place?.point ?? localMapCenter;
  late final _initial = _point;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(
        title: Text(widget.field == AddressField.pickup ? 'Откуда' : 'Куда'),
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Text('Передвиньте карту или нажмите на нужную точку.'),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: OrbitaMap(
                    height: (constraints.maxHeight * 0.60).clamp(240, 640),
                    session: widget.session,
                    enabled: widget.controller.enabled,
                    initialCenter: _initial,
                    picking: true,
                    onCenterChanged: (point) {
                      if (point.valid) setState(() => _point = point);
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const MapAttribution(),
                      Text(
                        'Выбранная точка: ${_point.caption}',
                        style: const TextStyle(fontSize: 12),
                      ),
                      const SizedBox(height: 10),
                      FullWidthAction(
                        'Выбрать точку',
                        key: const Key('confirm-map-point'),
                        onPressed: widget.controller.enabled && _point.valid
                            ? () => Navigator.pop(context, _point)
                            : null,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}
