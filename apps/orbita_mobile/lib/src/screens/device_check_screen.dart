import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../platform/device_gateway.dart';
import '../services/device_check_controller.dart';
import '../ui/components.dart';
import '../ui/theme.dart';
import 'location_permissions_screen.dart';

enum DeviceCheckSection { all, notifications, location }

class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({
    required this.device,
    this.section = DeviceCheckSection.all,
    super.key,
  });
  final DeviceGateway device;
  final DeviceCheckSection section;
  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen> {
  late final DeviceCheckController _controller;
  @override
  void initState() {
    super.initState();
    _controller = DeviceCheckController(widget.device);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action,
    String failure, [
    String? success,
  ]) async {
    final done = await _controller.run(action, failure: failure);
    if (done && mounted && success != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(success)));
    }
  }

  Future<void> _permissions() async {
    await Navigator.push(
      context,
      MaterialPageRoute<void>(
        builder: (_) => LocationPermissionsScreen(controller: _controller),
      ),
    );
    if (mounted) await _controller.refresh();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final title = switch (widget.section) {
        DeviceCheckSection.all => 'Проверка устройства',
        DeviceCheckSection.notifications => 'Уведомления',
        DeviceCheckSection.location => 'Геолокация',
      };
      return Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                PageHeader(
                  title,
                  onRefresh: _controller.busy ? null : _controller.refresh,
                ),
                if (_controller.loading)
                  const LinearProgressIndicator(minHeight: 2),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (_controller.readError != null ||
                          _controller.actionError != null) ...[
                        DiagnosticError(
                          message:
                              _controller.readError ?? _controller.actionError!,
                          onRetry: () {
                            _controller.dismissError();
                            _controller.refresh();
                          },
                        ),
                        const SizedBox(height: 16),
                      ],
                      if (widget.section != DeviceCheckSection.location) ...[
                        _notifications(),
                        const SizedBox(height: 16),
                      ],
                      if (widget.section !=
                          DeviceCheckSection.notifications) ...[
                        _location(),
                        const SizedBox(height: 16),
                        _service(),
                      ],
                      if (kDebugMode &&
                          widget.section == DeviceCheckSection.all) ...[
                        const SizedBox(height: 16),
                        SurfaceCard(
                          child: ExpansionTile(
                            key: const Key('advanced-diagnostics'),
                            tilePadding: EdgeInsets.zero,
                            title: const Text('Расширенная диагностика'),
                            subtitle: const Text(
                              'Для проверки тестовой версии',
                            ),
                            children: [
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: FullWidthAction(
                                  'Настройка карт',
                                  secondary: true,
                                  onPressed: () => Navigator.pushNamed(
                                    context,
                                    '/map-settings',
                                  ),
                                ),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: FullWidthAction(
                                  'Проверка API',
                                  secondary: true,
                                  onPressed: () => Navigator.pushNamed(
                                    context,
                                    '/api-check',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  Widget _notifications() {
    final state = _controller.state;
    final enabled = _controller.available && !_controller.busy;
    return DiagnosticCard(
      key: const Key('notifications-card'),
      icon: Icons.notifications_outlined,
      title: 'Уведомления',
      children: [
        StateBadge(
          _controller.loading
              ? 'Проверка…'
              : !_controller.available
              ? 'Нет данных'
              : state.notifications
              ? 'Разрешены'
              : 'Отключены',
          good: _controller.available && state.notifications,
        ),
        const SizedBox(height: 16),
        if (state.notifications)
          FullWidthAction(
            'Показать тестовое уведомление',
            key: const Key('notification-test'),
            onPressed: enabled
                ? () => _run(
                    widget.device.showLocalNotification,
                    'Не удалось показать тестовое уведомление.',
                    'Уведомление отправлено в шторку.',
                  )
                : null,
          )
        else
          FullWidthAction(
            'Разрешить уведомления',
            key: const Key('notification-permission'),
            onPressed: enabled
                ? () => _run(
                    widget.device.requestNotifications,
                    'Не удалось запросить уведомления.',
                  )
                : null,
          ),
        DiagnosticDetails(
          children: [
            const Text(
              'Это локальное уведомление. Серверный Push и реальные заказы ещё не подключены. Если запрос разрешения не появляется, проверьте доступ и каналы в системных настройках.',
            ),
            const SizedBox(height: 12),
            FullWidthAction(
              'Открыть настройки',
              secondary: true,
              onPressed: _controller.busy
                  ? null
                  : () => _run(
                      widget.device.openSettings,
                      'Не удалось открыть настройки приложения.',
                    ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _location() {
    final state = _controller.state;
    final ready =
        state.location == 'precise' &&
        state.backgroundLocation &&
        state.locationEnabled;
    return DiagnosticCard(
      key: const Key('location-card'),
      icon: Icons.location_on_outlined,
      title: 'Геолокация',
      children: [
        _StatusLine(
          'Местоположение',
          !_controller.available
              ? 'Нет данных'
              : switch (state.location) {
                  'precise' => 'Точное',
                  'approximate' => 'Приблизительное',
                  _ => 'Нет доступа',
                },
        ),
        const SizedBox(height: 10),
        _StatusLine(
          'Фоновый доступ',
          !_controller.available
              ? 'Нет данных'
              : state.backgroundLocation
              ? 'Разрешён'
              : 'Не предоставлен',
        ),
        if (!state.locationEnabled && _controller.available)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              'Геопозиция устройства выключена.',
              style: TextStyle(color: OrbitaColors.warning),
            ),
          ),
        if (!ready) ...[
          const SizedBox(height: 16),
          FullWidthAction(
            'Настроить разрешения',
            key: const Key('location-permissions'),
            secondary: true,
            onPressed: _controller.available && !_controller.busy
                ? _permissions
                : null,
          ),
        ],
        DiagnosticDetails(
          children: [
            const Text(
              'Для ручного запуска диагностической службы достаточно «Только при использовании». Постоянный доступ необязателен. Координаты не сохраняются и не отправляются.',
            ),
            const SizedBox(height: 12),
            FullWidthAction(
              'Управление разрешениями',
              secondary: true,
              onPressed: _controller.available && !_controller.busy
                  ? _permissions
                  : null,
            ),
          ],
        ),
      ],
    );
  }

  Widget _service() {
    final state = _controller.state;
    final allowed = _controller.available && !_controller.busy;
    return DiagnosticCard(
      key: const Key('service-card'),
      icon: Icons.sensors_outlined,
      title: 'Фоновая служба',
      children: [
        StateBadge(
          _controller.loading
              ? 'Проверка…'
              : !_controller.available
              ? 'Нет данных'
              : state.serviceRunning
              ? 'Работает'
              : 'Остановлена',
          key: const Key('service-state'),
          good: _controller.available && state.serviceRunning,
        ),
        const SizedBox(height: 16),
        _MetricGrid(
          metrics: [
            _Metric(
              'Обновления позиции',
              _controller.available ? '${state.fixCount}' : '—',
              _controller.available
                  ? 'Получено обновлений позиции: ${state.fixCount}'
                  : 'Обновлений позиции: нет данных',
              emphasis: true,
            ),
            _Metric(
              'Последняя позиция',
              _controller.available ? _time(state.lastFix) : '—',
              'Последняя позиция: ${_controller.available ? _spokenTime(state.lastFix) : 'нет данных'}',
            ),
            _Metric(
              'Сигнал службы',
              _controller.available ? _time(state.lastHeartbeat) : '—',
              'Последний сигнал службы: ${_controller.available ? _spokenTime(state.lastHeartbeat) : 'нет данных'}',
            ),
          ],
        ),
        const SizedBox(height: 16),
        if (state.serviceRunning)
          FullWidthAction(
            'Остановить диагностику',
            key: const Key('stop-diagnostic'),
            secondary: true,
            onPressed: allowed
                ? () => _run(
                    widget.device.stopLocationDiagnostic,
                    'Не удалось остановить диагностику.',
                  )
                : null,
          )
        else
          FullWidthAction(
            'Запустить диагностику',
            key: const Key('start-diagnostic'),
            onPressed: allowed && state.canStartDiagnostic
                ? () => _run(
                    widget.device.startLocationDiagnostic,
                    'Не удалось запустить диагностику.',
                    'Команда запуска отправлена.',
                  )
                : null,
          ),
        if (!state.serviceRunning &&
            !state.canStartDiagnostic &&
            _controller.available)
          const Padding(
            padding: EdgeInsets.only(top: 10),
            child: Text(
              'Для запуска нужны уведомления и включённая геопозиция.',
            ),
          ),
        DiagnosticDetails(
          children: [
            _StatusLine('Запущена', _time(state.startedAt)),
            const SizedBox(height: 10),
            _StatusLine('Android API', '${state.sdk}'),
            const SizedBox(height: 12),
            const Text(
              'Локальная проверка, не выход на линию. После испытания остановите службу. Автоматическое восстановление после перезагрузки или уничтожения процесса не подключено.',
            ),
            const SizedBox(height: 10),
            const Text(
              'Отсутствие свежей позиции в помещении не означает остановку службы. Длительная работа под блокировкой проверяется отдельно на каждом устройстве.',
            ),
          ],
        ),
      ],
    );
  }
}

String _time(int value) {
  if (value == 0) return '—';
  final t = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
  return '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
}

String _spokenTime(int value) => value == 0 ? 'пока нет данных' : _time(value);

class DiagnosticCard extends StatelessWidget {
  const DiagnosticCard({
    required this.icon,
    required this.title,
    required this.children,
    super.key,
  });
  final IconData icon;
  final String title;
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 24, color: OrbitaColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                title,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        ...children,
      ],
    ),
  );
}

class DiagnosticDetails extends StatelessWidget {
  const DiagnosticDetails({required this.children, super.key});
  final List<Widget> children;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    tilePadding: EdgeInsets.zero,
    childrenPadding: const EdgeInsets.only(top: 4, bottom: 8),
    shape: const Border(),
    collapsedShape: const Border(),
    title: const Text('Подробнее', style: TextStyle(fontSize: 13)),
    children: [
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    ],
  );
}

class DiagnosticError extends StatelessWidget {
  const DiagnosticError({
    required this.message,
    required this.onRetry,
    super.key,
  });
  final String message;
  final VoidCallback onRetry;
  @override
  Widget build(BuildContext context) => Semantics(
    liveRegion: true,
    child: SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            message,
            key: const Key('device-message'),
            style: const TextStyle(color: OrbitaColors.warning),
          ),
          const SizedBox(height: 12),
          FullWidthAction(
            'Повторить проверку',
            secondary: true,
            onPressed: onRetry,
          ),
        ],
      ),
    ),
  );
}

class _StatusLine extends StatelessWidget {
  const _StatusLine(this.label, this.value);
  final String label, value;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        label,
        style: const TextStyle(fontSize: 12, color: OrbitaColors.muted),
      ),
      const SizedBox(height: 3),
      Text(
        value,
        style: const TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: OrbitaColors.text,
        ),
      ),
    ],
  );
}

class _Metric {
  const _Metric(
    this.label,
    this.value,
    this.semantics, {
    this.emphasis = false,
  });
  final String label, value, semantics;
  final bool emphasis;
}

class _MetricGrid extends StatelessWidget {
  const _MetricGrid({required this.metrics});
  final List<_Metric> metrics;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      var requiredWidth = 0.0;
      for (final m in metrics) {
        requiredWidth = math.max(
          requiredWidth,
          math.max(
                textWidth(
                  context,
                  m.value,
                  TextStyle(
                    fontSize: m.emphasis ? 24 : 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                textWidth(context, m.label, const TextStyle(fontSize: 12)),
              ) +
              20,
        );
      }
      final columns = ((constraints.maxWidth + 8) / (requiredWidth + 8))
          .floor()
          .clamp(1, 3);
      final width = (constraints.maxWidth - (columns - 1) * 8) / columns;
      return Wrap(
        spacing: 8,
        runSpacing: 10,
        children: [
          for (final m in metrics)
            SizedBox(
              width: width,
              child: Semantics(
                label: m.semantics,
                excludeSemantics: true,
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: const Color(0xff16232b),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(m.label, style: const TextStyle(fontSize: 12)),
                      const SizedBox(height: 6),
                      Text(
                        m.value,
                        style: TextStyle(
                          fontSize: m.emphasis ? 24 : 16,
                          color: OrbitaColors.text,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      );
    },
  );
}
