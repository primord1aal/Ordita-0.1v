import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import '../ui/components.dart' hide ShiftControl;
import '../ui/driver_demo_access.dart';
import '../ui/driver_map.dart';
import '../ui/shift_control.dart';
import '../ui/theme.dart';

class DriverScreen extends StatelessWidget {
  const DriverScreen({
    required this.mapSettings,
    this.enabled = true,
    this.foreground = true,
    this.tileSessionFactory,
    super.key,
  });

  final MapSettings mapSettings;
  final bool enabled, foreground;
  final MapTileSession Function(String)? tileSessionFactory;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => CustomScrollView(
      key: const Key('driver-scroll'),
      slivers: [
        const SliverToBoxAdapter(child: BrandHeader()),
        const SliverPadding(
          padding: EdgeInsets.fromLTRB(18, 0, 18, 12),
          sliver: SliverToBoxAdapter(child: ShiftControl()),
        ),
        SliverToBoxAdapter(
          child: DriverMap(
            key: const Key('driver-map'),
            mapSettings: mapSettings,
            enabled: enabled,
            foreground: foreground,
            height: (constraints.maxHeight - 270).clamp(220.0, 1100.0),
            tileSessionFactory: tileSessionFactory,
          ),
        ),
        const SliverToBoxAdapter(
          child: _DriverPanel(
            title: 'Заказы',
            children: [Text('Нет активных заказов')],
          ),
        ),
      ],
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
  const DriverDiagnosticView({super.key});
  @override
  State<DriverDiagnosticView> createState() => _DriverDiagnosticViewState();
}

class _DriverDiagnosticViewState extends State<DriverDiagnosticView> {
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

  @override
  Widget build(BuildContext context) {
    if (!DriverDemoAccess.allowed(context)) {
      return const DriverDemoDeniedScreen();
    }
    final palette = OrbitaPalette.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('ДЕМО · Водитель')),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) => CustomScrollView(
            key: const Key('driver-demo-scroll'),
            slivers: [
              const SliverToBoxAdapter(child: BrandHeader()),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(18, 8, 18, 12),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'ДЕМО · Все события искусственные',
                        style: Theme.of(context).textTheme.labelMedium
                            ?.copyWith(
                              color: palette.accent,
                              fontWeight: FontWeight.w700,
                            ),
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<DriverDemoScenario>(
                        key: const Key('driver-demo-scenario'),
                        initialValue: _scenario,
                        isExpanded: true,
                        itemHeight: null,
                        decoration: const InputDecoration(
                          labelText: 'Диагностический сценарий',
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
                          ),
                        ),
                        items: [
                          for (final entry in const [
                            (DriverDemoScenario.offline, 'Вне линии'),
                            (DriverDemoScenario.online, 'На линии'),
                            (
                              DriverDemoScenario.pending,
                              'Ожидание подтверждения',
                            ),
                            (DriverDemoScenario.error, 'Ошибка подтверждения'),
                            (
                              DriverDemoScenario.offer,
                              'Предложение на 25 секунд',
                            ),
                            (DriverDemoScenario.journey, 'Этапы поездки'),
                          ])
                            DropdownMenuItem(
                              value: entry.$1,
                              child: Text(entry.$2),
                            ),
                        ],
                        onChanged: (value) {
                          if (value != null) _select(value);
                        },
                      ),
                      const SizedBox(height: 12),
                      ShiftControl(
                        key: ValueKey(_revision),
                        available: true,
                        confirmedOnline: _online,
                        requestChange: _change,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(
                child: Container(
                  key: const Key('driver-demo-map'),
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight * 0.38).clamp(
                      180.0,
                      550.0,
                    ),
                  ),
                  color: palette.mapLand,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.map_outlined, color: palette.muted, size: 36),
                      const SizedBox(height: 8),
                      const Text(
                        'ДЕМО · Карта — тестовая заглушка',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
              SliverToBoxAdapter(child: _panel(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context) {
    if (_phase == _DemoPhase.offer) {
      return _DriverPanel(
        title: 'ДЕМО · Новый заказ',
        children: [
          Text(
            '$_seconds с',
            key: const Key('demo-offer-countdown'),
            style: Theme.of(context).textTheme.headlineMedium
                ?.copyWith(color: OrbitaPalette.of(context).accent),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: _seconds / 25),
          const SizedBox(height: 12),
          const Text('Вымышленные адреса'),
          const SizedBox(height: 8),
          const Text('Откуда: Учебная улица, 12'),
          const SizedBox(height: 8),
          const Text('Куда: Примерная улица, 7'),
          const SizedBox(height: 16),
          _OfferActions(
            onAccept: () => _answer(true),
            onDecline: () => _answer(false),
          ),
        ],
      );
    }
    final (title, message, action, next) = switch (_phase) {
      _DemoPhase.accepted => (
        'Заказ принят',
        'Вымышленный заказ · Учебная улица, 12',
        'Ехать к пассажиру',
        _DemoPhase.toPickup,
      ),
      _DemoPhase.toPickup => (
        'В пути к пассажиру',
        'Вымышленный заказ · Учебная улица, 12',
        'Прибыл',
        _DemoPhase.arrived,
      ),
      _DemoPhase.arrived => (
        'Прибыл',
        'ДЕМО · Ожидание посадки пассажира',
        'Начать поездку',
        _DemoPhase.riding,
      ),
      _DemoPhase.riding => (
        'Поездка выполняется',
        'Вымышленный заказ · Примерная улица, 7',
        'Завершить поездку',
        _DemoPhase.complete,
      ),
      _DemoPhase.complete => (
        'Поездка завершена',
        'ДЕМО · Запись в историю не создаётся.',
        '',
        _DemoPhase.empty,
      ),
      _DemoPhase.declined => (
        'Предложение отклонено',
        'ДЕМО · Серверная очередь не изменена.',
        '',
        _DemoPhase.empty,
      ),
      _DemoPhase.expired => (
        'Время ответа истекло',
        'ДЕМО · Позднее принятие недоступно.',
        '',
        _DemoPhase.empty,
      ),
      _ => (
        _online ? 'Предложения' : 'Заказы',
        _online ? 'Новых предложений пока нет.' : 'Активных поездок нет.',
        '',
        _DemoPhase.empty,
      ),
    };
    return _DriverPanel(
      title: 'ДЕМО · $title',
      children: [
        Text(message),
        if (_confirmation != null) ...[
          const SizedBox(height: 12),
          FullWidthAction(
            'Подтвердить локально',
            key: const Key('demo-confirm-pending'),
            onPressed: () {
              if (_allowed) {
                _completeConfirmation();
                setState(() {});
              }
            },
          ),
          const SizedBox(height: 8),
          FullWidthAction(
            'Вернуть ошибку',
            key: const Key('demo-fail-pending'),
            secondary: true,
            onPressed: () {
              if (_allowed) {
                _completeConfirmation(fail: true);
                setState(() {});
              }
            },
          ),
        ],
        if (action.isNotEmpty) ...[
          const SizedBox(height: 16),
          FullWidthAction(
            action,
            key: const Key('demo-journey-action'),
            onPressed: () => _advance(next),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          'Имитируется только интерфейс. Серверные команды, геолокация и история не используются.',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

class _OfferActions extends StatelessWidget {
  const _OfferActions({required this.onAccept, required this.onDecline});
  final VoidCallback onAccept, onDecline;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final style = Theme.of(context).textTheme.labelLarge!;
      final requiredWidth =
          textWidth(context, 'Отказаться', style) +
          textWidth(context, 'Принять', style) +
          80;
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
      return requiredWidth <= constraints.maxWidth
          ? Row(
              children: [
                Expanded(child: decline),
                const SizedBox(width: 10),
                Expanded(child: accept),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [decline, const SizedBox(height: 8), accept],
            );
    },
  );
}

class _DriverPanel extends StatelessWidget {
  const _DriverPanel({required this.title, required this.children});
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    return Container(
      key: const Key('current-order'),
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 18),
      decoration: BoxDecoration(
        color: palette.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: palette.outline)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: palette.outline,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 14),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          ...children,
        ],
      ),
    );
  }
}
