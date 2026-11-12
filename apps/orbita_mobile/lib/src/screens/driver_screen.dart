import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../maps/map_settings.dart';
import '../maps/map_location_action.dart';
import '../maps/address_models.dart';
import '../platform/device_gateway.dart';
import '../maps/map_tiles.dart';
import '../ui/components.dart' hide ShiftControl;
import '../ui/driver_demo_access.dart';
import '../ui/driver_map.dart';
import '../ui/shift_control.dart';
import '../ui/theme.dart';

class DriverScreen extends StatefulWidget {
  const DriverScreen({
    required this.mapSettings,
    this.device,
    this.enabled = true,
    this.foreground = true,
    this.tileSessionFactory,
    super.key,
  });

  final MapSettings mapSettings;
  final DeviceGateway? device;
  final bool enabled, foreground;
  final MapTileSession Function(String)? tileSessionFactory;

  @override
  State<DriverScreen> createState() => _DriverScreenState();
}

class _DriverScreenState extends State<DriverScreen> {
  MapLocationAction? _location;
  GeoPoint? _position;

  @override
  void initState() {
    super.initState();
    if (widget.device case final device?) {
      _location = MapLocationAction(
        device: device,
        isAllowed: () =>
            mounted &&
            widget.enabled &&
            widget.foreground &&
            widget.mapSettings.configured,
        onLocation: (point) => setState(() => _position = point),
        onError: (message) {
          if (mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(message)));
          }
        },
      );
    }
  }

  @override
  void didUpdateWidget(covariant DriverScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || !widget.foreground) _location?.cancel(notify: false);
  }

  @override
  void dispose() {
    _location?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _location ?? const AlwaysStoppedAnimation<double>(0),
    builder: (context, _) => _DriverBody(
      mapSettings: widget.mapSettings,
      enabled: widget.enabled,
      foreground: widget.foreground,
      tileSessionFactory: widget.tileSessionFactory,
      focusPoint: _position,
      onLocate: _location?.locate,
      locating: _location?.busy ?? false,
      slider: const ShiftControl(),
      panel: const _EmptyPanel(online: false),
      panelHeight: _EmptyPanel.height(context),
    ),
  );
}

enum DriverDemoScenario { offline, online, pending, error, offer, journey }

enum _DemoPhase {
  empty,
  offer,
  declined,
  expired,
  accepted,
  toPickup,
  arrived,
  riding,
  complete,
}

/// Только диагностическая имитация. Доступ не принимается параметром виджета.
class DriverDiagnosticView extends StatefulWidget {
  const DriverDiagnosticView({
    this.mapSettings,
    this.tileSessionFactory,
    super.key,
  });
  final MapSettings? mapSettings;
  final MapTileSession Function(String)? tileSessionFactory;
  @override
  State<DriverDiagnosticView> createState() => _DriverDiagnosticViewState();
}

class _DriverDiagnosticViewState extends State<DriverDiagnosticView> {
  late final _maps = widget.mapSettings ?? MapSettings();
  DriverDemoScenario _scenario = DriverDemoScenario.offline;
  _DemoPhase _phase = _DemoPhase.empty;
  bool _online = false;
  int _revision = 0, _seconds = 25;
  DateTime? _deadline;
  Timer? _timer;
  Completer<void>? _confirmation;

  bool get _allowed => mounted && DriverDemoAccess.allowed(context);

  @override
  void dispose() {
    ++_revision;
    _timer?.cancel();
    _completeConfirmation();
    if (widget.mapSettings == null) _maps.dispose();
    super.dispose();
  }

  void _completeConfirmation({bool fail = false}) {
    final confirmation = _confirmation;
    _confirmation = null;
    if (confirmation == null || confirmation.isCompleted) return;
    if (fail) {
      confirmation.completeError(
        StateError('Искусственная ошибка подтверждения'),
      );
    } else {
      confirmation.complete();
    }
  }

  void _select(DriverDemoScenario scenario) {
    if (!_allowed) return;
    ++_revision;
    _timer?.cancel();
    _completeConfirmation();
    setState(() {
      _scenario = scenario;
      _online =
          scenario == DriverDemoScenario.online ||
          scenario == DriverDemoScenario.offer ||
          scenario == DriverDemoScenario.journey;
      _phase = scenario == DriverDemoScenario.offer
          ? _DemoPhase.offer
          : scenario == DriverDemoScenario.journey
          ? _DemoPhase.accepted
          : _DemoPhase.empty;
      _seconds = 25;
      _deadline = scenario == DriverDemoScenario.offer
          ? DateTime.now().add(const Duration(seconds: 25))
          : null;
    });
    if (_deadline != null) {
      _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (!_allowed || _phase != _DemoPhase.offer) {
          _timer?.cancel();
          return;
        }
        final remaining = math.max(
          0,
          math.min(
            25 - timer.tick,
            (_deadline!.difference(DateTime.now()).inMilliseconds / 1000)
                .ceil(),
          ),
        );
        setState(() {
          _seconds = remaining;
          if (remaining == 0) _phase = _DemoPhase.expired;
        });
        if (remaining == 0) _timer?.cancel();
      });
    }
  }

  Future<void> _change(bool target) async {
    if (!_allowed) return;
    final revision = _revision;
    if (_scenario == DriverDemoScenario.error) {
      throw StateError('Искусственная ошибка подтверждения');
    }
    if (_scenario == DriverDemoScenario.pending) {
      _confirmation = Completer<void>();
      setState(() {});
      await _confirmation!.future;
    }
    if (!_allowed || revision != _revision) return;
    setState(() => _online = target);
  }

  void _answer(bool accept) {
    if (!_allowed || _phase != _DemoPhase.offer) return;
    _timer?.cancel();
    setState(() {
      if (_deadline == null || !DateTime.now().isBefore(_deadline!)) {
        _seconds = 0;
        _phase = _DemoPhase.expired;
      } else {
        _phase = accept ? _DemoPhase.accepted : _DemoPhase.declined;
      }
    });
  }

  void _advance(_DemoPhase phase) {
    if (_allowed) setState(() => _phase = phase);
  }

  void _tools() {
    if (!_allowed) return;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<DriverDemoScenario>(
                key: const Key('driver-demo-scenario'),
                initialValue: _scenario,
                isExpanded: true,
                itemHeight: null,
                decoration: const InputDecoration(labelText: 'Сценарий'),
                items: [
                  for (final item in const [
                    (DriverDemoScenario.offline, 'Вне линии'),
                    (DriverDemoScenario.online, 'На линии'),
                    (DriverDemoScenario.pending, 'Ожидание подтверждения'),
                    (DriverDemoScenario.error, 'Ошибка подтверждения'),
                    (DriverDemoScenario.offer, 'Предложение на 25 секунд'),
                    (DriverDemoScenario.journey, 'Этапы поездки'),
                  ])
                    DropdownMenuItem(value: item.$1, child: Text(item.$2)),
                ],
                onChanged: (value) {
                  if (value != null && _allowed) _select(value);
                  Navigator.pop(sheet);
                },
              ),
              if (_confirmation != null) ...[
                const SizedBox(height: 12),
                FullWidthAction(
                  'Подтвердить',
                  key: const Key('demo-confirm-pending'),
                  onPressed: () {
                    _completeConfirmation();
                    Navigator.pop(sheet);
                  },
                ),
                const SizedBox(height: 8),
                FullWidthAction(
                  'Вернуть ошибку',
                  key: const Key('demo-fail-pending'),
                  secondary: true,
                  onPressed: () {
                    _completeConfirmation(fail: true);
                    Navigator.pop(sheet);
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!DriverDemoAccess.allowed(context)) {
      return const DriverDemoDeniedScreen();
    }
    final offer = _phase == _DemoPhase.offer;
    return LayoutBuilder(
      builder: (context, constraints) => Scaffold(
        body: SafeArea(
          bottom: false,
          child: _DriverBody(
            mapSettings: _maps,
            tileSessionFactory: widget.tileSessionFactory,
            onTools: _tools,
            slider: offer
                ? null
                : ShiftControl(
                    key: ValueKey(_revision),
                    available: true,
                    confirmedOnline: _online,
                    requestChange: _change,
                  ),
            panel: offer
                ? _OfferPanel(
                    seconds: _seconds,
                    onAccept: () => _answer(true),
                    onDecline: () => _answer(false),
                  )
                : _panel(),
            panelHeight: offer
                ? _OfferPanel.height(context, constraints.maxWidth)
                : _EmptyPanel.height(context),
          ),
        ),
        bottomNavigationBar: AdaptiveNavigation(
          driver: true,
          selected: 0,
          availableHeight:
              constraints.maxHeight - MediaQuery.paddingOf(context).vertical,
          onSelected: (index) {
            if (index != 0) Navigator.pop(context, index);
          },
        ),
      ),
    );
  }

  Widget _panel() {
    final (title, message, action, next) = switch (_phase) {
      _DemoPhase.accepted => (
        'Заказ принят',
        'Учебная улица, 12',
        'Ехать к пассажиру',
        _DemoPhase.toPickup,
      ),
      _DemoPhase.toPickup => (
        'В пути к пассажиру',
        'Учебная улица, 12',
        'Прибыл',
        _DemoPhase.arrived,
      ),
      _DemoPhase.arrived => (
        'Прибыл',
        'Ожидание посадки пассажира',
        'Начать поездку',
        _DemoPhase.riding,
      ),
      _DemoPhase.riding => (
        'Поездка выполняется',
        'Примерная улица, 7',
        'Завершить поездку',
        _DemoPhase.complete,
      ),
      _DemoPhase.complete => ('Поездка завершена', '', '', _DemoPhase.empty),
      _DemoPhase.declined => (
        'Предложение отклонено',
        '',
        '',
        _DemoPhase.empty,
      ),
      _DemoPhase.expired => ('Время ответа истекло', '', '', _DemoPhase.empty),
      _ => ('', '', '', _DemoPhase.empty),
    };
    if (title.isEmpty) return _EmptyPanel(online: _online);
    return _DriverPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (message.isNotEmpty) ...[const SizedBox(height: 8), Text(message)],
          if (action.isNotEmpty) ...[
            const SizedBox(height: 12),
            FullWidthAction(
              action,
              key: const Key('demo-journey-action'),
              onPressed: () => _advance(next),
            ),
          ],
        ],
      ),
    );
  }
}

double _textHeight(
  BuildContext context,
  String text,
  TextStyle style,
  double width,
) {
  final p = TextPainter(
    text: TextSpan(
      text: text,
      style: Theme.of(context).textTheme.bodyMedium!.merge(style),
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: math.max(1, width));
  final height = p.height;
  p.dispose();
  return height;
}

// CSS: header74, shift64+12, sheet8/4/12/content/13, map min140.
class _DriverBody extends StatelessWidget {
  const _DriverBody({
    required this.mapSettings,
    required this.panel,
    required this.panelHeight,
    this.slider,
    this.onTools,
    this.enabled = true,
    this.foreground = true,
    this.tileSessionFactory,
    this.focusPoint,
    this.onLocate,
    this.locating = false,
  });
  final GeoPoint? focusPoint;
  final VoidCallback? onLocate;
  final bool locating;
  final MapSettings mapSettings;
  final Widget panel;
  final double panelHeight;
  final Widget? slider;
  final VoidCallback? onTools;
  final bool enabled, foreground;
  final MapTileSession Function(String)? tileSessionFactory;
  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const Key('driver-scroll'),
    slivers: [
      SliverToBoxAdapter(
        child: GestureDetector(
          key: const Key('driver-tools'),
          onLongPress: onTools,
          child: const BrandHeader(driverTypography: true),
        ),
      ),
      if (slider != null)
        SliverToBoxAdapter(
          child: ColoredBox(
            color: OrbitaPalette.of(context).mapLand,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 12),
              child: slider,
            ),
          ),
        ),
      SliverLayoutBuilder(
        builder: (context, constraints) {
          final height = math.max(
            140.0,
            constraints.viewportMainAxisExtent -
                constraints.precedingScrollExtent -
                panelHeight,
          );
          return SliverToBoxAdapter(
            child: Column(
              children: [
                DriverMap(
                  key: const Key('driver-map'),
                  mapSettings: mapSettings,
                  enabled: enabled,
                  foreground: foreground,
                  height: height,
                  tileSessionFactory: tileSessionFactory,
                  focusPoint: focusPoint,
                  onLocate: onLocate,
                  locating: locating,
                ),
                panel,
              ],
            ),
          );
        },
      ),
    ],
  );
}

class _DriverPanel extends StatelessWidget {
  const _DriverPanel({required this.child});
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final p = OrbitaPalette.of(context);
    return Container(
      key: const Key('current-order'),
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 13),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: p.divider)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 34,
              height: 4,
              decoration: BoxDecoration(
                color: p.outline.withValues(alpha: .65),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _EmptyPanel extends StatelessWidget {
  const _EmptyPanel({required this.online});
  final bool online;
  static double height(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width - 74;
    final text =
        _textHeight(
          context,
          'Предложения',
          const TextStyle(fontSize: 16, height: 1.2),
          width,
        ) +
        3 +
        _textHeight(
          context,
          'Новых предложений пока нет',
          const TextStyle(fontSize: 13, height: 1.4),
          width,
        );
    return 8 + 4 + 12 + math.max(26, text) + 4 + 13 + 1;
  }

  @override
  Widget build(BuildContext context) {
    final p = OrbitaPalette.of(context);
    return _DriverPanel(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    online ? 'Предложения' : 'Заказы',
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.2,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    online
                        ? 'Новых предложений пока нет'
                        : 'Активных поездок нет',
                    style: TextStyle(fontSize: 13, height: 1.4, color: p.muted),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox.square(
              dimension: 26,
              child: CustomPaint(painter: _RouteIcon(p.muted)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Геометрия symbol#i-route из утверждённого HTML (viewBox 0 0 24 24).
class _RouteIcon extends CustomPainter {
  const _RouteIcon(this.color);
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    canvas.scale(size.width / 24, size.height / 24);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(const Offset(5, 18), 2, paint);
    canvas.drawCircle(const Offset(19, 6), 2, paint);
    canvas.drawPath(
      Path()
        ..moveTo(7, 18)
        ..cubicTo(16, 18, 9, 6, 17, 6),
      paint,
    );
  }

  @override
  bool shouldRepaint(_RouteIcon oldDelegate) => color != oldDelegate.color;
}

class _OfferPanel extends StatelessWidget {
  const _OfferPanel({
    required this.seconds,
    required this.onAccept,
    required this.onDecline,
  });
  final int seconds;
  final VoidCallback onAccept, onDecline;
  static double height(BuildContext context, double width) {
    final available = width - 36;
    final header = math.max(
      _textHeight(
        context,
        'Новый заказ',
        const TextStyle(fontSize: 22, height: 1.2),
        available - 85,
      ),
      _textHeight(
        context,
        '25 с',
        const TextStyle(fontSize: 25, height: 1.4),
        85,
      ),
    );
    final rows =
        2 *
        math.max(
          57,
          _textHeight(
                context,
                'Учебная улица, 12',
                const TextStyle(fontSize: 15, height: 1.28),
                available - 66,
              ) +
              _textHeight(
                context,
                'Откуда',
                const TextStyle(fontSize: 11, height: 1.2),
                available - 66,
              ) +
              16,
        );
    final button = math.max(
      52,
      _textHeight(
            context,
            'Отказаться',
            const TextStyle(fontSize: 15, height: 1.3),
            (available - 10) / 2.2 - 32,
          ) +
          28,
    );
    return 8 + 4 + 12 + header + 10 + 4 + 10 + rows + 1 + 10 + button + 13 + 1;
  }

  @override
  Widget build(BuildContext context) {
    final p = OrbitaPalette.of(context);
    return _DriverPanel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  'Новый заказ',
                  style: TextStyle(
                    fontSize: 22,
                    height: 1.2,
                    fontWeight: FontWeight.w600,
                    color: p.text,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Text(
                '$seconds с',
                key: const Key('demo-offer-countdown'),
                style: TextStyle(
                  fontSize: 25,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: p.accent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: seconds / 25,
            minHeight: 4,
            color: p.accent,
            backgroundColor: p.accentSoft,
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: Color.lerp(p.surface, p.surfaceVariant, .22),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                _address(context, true, 'Учебная улица, 12'),
                Divider(height: 1, color: p.divider),
                _address(context, false, 'Примерная улица, 7'),
              ],
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (context, constraints) {
              final style = Theme.of(context).textTheme.labelLarge!;
              final fits =
                  textWidth(context, 'Отказаться', style) +
                      textWidth(context, 'Принять', style) +
                      80 <=
                  constraints.maxWidth;
              final decline = FullWidthAction(
                'Отказаться',
                key: const Key('demo-offer-decline'),
                secondary: true,
                onPressed: onDecline,
              );
              final accept = FullWidthAction(
                'Принять',
                key: const Key('demo-offer-accept'),
                onPressed: onAccept,
              );
              return OutlinedButtonTheme(
                data: OutlinedButtonThemeData(
                  style: Theme.of(context).outlinedButtonTheme.style?.copyWith(
                    foregroundColor: WidgetStatePropertyAll(p.text),
                  ),
                ),
                child: fits
                    ? Row(
                        children: [
                          Expanded(flex: 10, child: decline),
                          const SizedBox(width: 10),
                          Expanded(flex: 12, child: accept),
                        ],
                      )
                    : Column(
                        children: [decline, const SizedBox(height: 8), accept],
                      ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _address(BuildContext context, bool pickup, String address) {
    final p = OrbitaPalette.of(context);
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 57),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(
          children: [
            Icon(
              pickup ? Icons.trip_origin : Icons.place_outlined,
              color: pickup ? p.text : p.accent,
              size: 20,
            ),
            const SizedBox(width: 11),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    pickup ? 'Откуда' : 'Куда',
                    style: TextStyle(fontSize: 11, height: 1.2, color: p.muted),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    address,
                    style: TextStyle(
                      fontSize: 15,
                      height: 1.28,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
