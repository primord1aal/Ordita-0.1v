import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../maps/map_tiles.dart';
import '../maps/passenger_address_controller.dart';
import '../ui/components.dart';
import '../ui/orbita_map.dart';
import '../ui/theme.dart';

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
              child: LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                        child: Text(
                          'Передвиньте карту или нажмите на нужную точку.',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                      ),
                      OrbitaMap(
                        height: (constraints.maxHeight * 0.55).clamp(220, 640),
                        borderRadius: BorderRadius.zero,
                        session: widget.session,
                        enabled: widget.controller.enabled,
                        initialCenter: _initial,
                        picking: true,
                        onCenterChanged: (point) {
                          if (point.valid) setState(() => _point = point);
                        },
                      ),
                      Container(
                        width: double.infinity,
                        decoration: BoxDecoration(
                          color: OrbitaPalette.of(context).surface,
                          borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(24),
                          ),
                          border: Border(
                            top: BorderSide(
                              color: OrbitaPalette.of(context).divider,
                            ),
                          ),
                        ),
                        padding: const EdgeInsets.fromLTRB(18, 16, 18, 24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              widget.field == AddressField.pickup
                                  ? 'Адрес подачи'
                                  : 'Пункт назначения',
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Точка под прицелом: ${_point.caption}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                            const SizedBox(height: 16),
                            FullWidthAction(
                              'Выбрать точку',
                              key: const Key('confirm-map-point'),
                              onPressed:
                                  widget.controller.enabled && _point.valid
                                  ? () => Navigator.pop(context, _point)
                                  : null,
                            ),
                            const SizedBox(height: 8),
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Вернуться к адресу'),
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
