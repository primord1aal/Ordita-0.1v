import 'dart:async';

import 'package:flutter/material.dart';

import '../platform/device_gateway.dart';
import 'preview_screens.dart';

class DeviceCheckScreen extends StatefulWidget {
  const DeviceCheckScreen({required this.device, super.key});
  final DeviceGateway device;
  @override
  State<DeviceCheckScreen> createState() => _DeviceCheckScreenState();
}

class _DeviceCheckScreenState extends State<DeviceCheckScreen>
    with WidgetsBindingObserver {
  DeviceState _state = const DeviceState();
  Timer? _timer;
  bool _busy = false, _loaded = false, _reading = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        _refresh();
      }
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _refresh();
  }

  Future<void> _refresh() async {
    if (_reading) return;
    _reading = true;
    try {
      final state = await widget.device.read();
      if (mounted) {
        setState(() {
          _state = state;
          _loaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _loaded = true;
          _message = 'Не удалось прочитать состояние Android. Проверка доступна в Android-приложении.';
        });
      }
    } finally {
      _reading = false;
    }
  }

  Future<void> _perform(
    Future<void> Function() action, [
    String? success,
  ]) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
      await _refresh();
      if (mounted && success != null) setState(() => _message = success);
    } catch (_) {
      if (mounted) {
        setState(
          () => _message = 'Действие не выполнено. Проверьте разрешения, включённую геопозицию и настройки приложения.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _backgroundAccess() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Дополнительный фоновый доступ'),
        content: const Text(
          'Сначала разрешите геопозицию при использовании приложения. Для проверки службы, запущенной с этого экрана, этого достаточно. Постоянный доступ необязателен. Если вы хотите проверить отдельный второй шаг, откройте системные настройки доступа к геопозиции. Выбор зависит от версии Android.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Отмена'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Продолжить'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await _perform(widget.device.requestBackgroundLocation);
    }
  }

  String _time(int value) {
    if (value == 0) return 'Ещё нет';
    final time = DateTime.fromMillisecondsSinceEpoch(value).toLocal();
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Проверка телефона')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Notice(
          'Проверка выполняется только на телефоне. Координаты не сохраняются и не отправляются. Это не выход водителя на линию.',
          icon: Icons.info_outline,
        ),
        const SizedBox(height: 20),
        if (!_loaded) const LinearProgressIndicator(),
        if (_message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Text(_message!, key: const Key('device-message')),
          ),
        const SectionTitle('Уведомления'),
        const SizedBox(height: 8),
        Text(
          _state.notifications
              ? 'Разрешены'
              : 'Не разрешены или канал отключён',
        ),
        const SizedBox(height: 8),
        OutlinedButton(
          onPressed: _busy || !_loaded
              ? null
              : () => _perform(widget.device.requestNotifications),
          child: const Text('Разрешить уведомления'),
        ),
        OutlinedButton(
          onPressed: _busy || !_state.notifications
              ? null
              : () => _perform(
                  widget.device.showLocalNotification,
                  'Локальное уведомление отправлено в систему. Проверьте шторку уведомлений.',
                ),
          child: const Text('Показать тестовое уведомление'),
        ),
        const Text(
          'Это локальная проверка Android. Доставка Push с сервера ещё не подключена.',
        ),
        const SizedBox(height: 24),
        const SectionTitle('Геопозиция'),
        const SizedBox(height: 8),
        Text(switch (_state.location) {
          'precise' => 'Разрешена точная позиция',
          'approximate' => 'Разрешена приблизительная позиция',
          _ => 'Доступ не предоставлен',
        }),
        Text(
          _state.locationEnabled
              ? 'Геопозиция телефона включена'
              : 'Геопозиция телефона выключена',
        ),
        OutlinedButton(
          onPressed: _busy || !_loaded
              ? null
              : () => _perform(widget.device.requestForegroundLocation),
          child: const Text('Шаг 1. Разрешить геопозицию'),
        ),
        OutlinedButton(
          onPressed: _busy || !_state.hasForegroundLocation
              ? null
              : _backgroundAccess,
          child: const Text('Шаг 2. Дополнительный доступ в фоне'),
        ),
        Text(
          _state.backgroundLocation ? 'Постоянный доступ разрешён' : '«Только при использовании» подходит для ручного запуска этой службы. Постоянный доступ необязателен.',
        ),
        const SizedBox(height: 24),
        const SectionTitle('Фоновая проверка'),
        const SizedBox(height: 8),
        Text(
          _state.serviceRunning ? 'Служба работает' : 'Служба остановлена',
          key: const Key('service-state'),
        ),
        Text('Запущена: ${_time(_state.startedAt)}'),
        Text('Последний сигнал службы: ${_time(_state.lastHeartbeat)}'),
        Text('Последнее определение позиции: ${_time(_state.lastFix)}'),
        Text('Получено обновлений позиции: ${_state.fixCount}'),
        const SizedBox(height: 12),
        FilledButton(
          onPressed:
              _busy || !_state.canStartDiagnostic || _state.serviceRunning
              ? null
              : () => _perform(
                  widget.device.startLocationDiagnostic,
                  'Запрос запуска отправлен. Обновите состояние через несколько секунд и проверьте постоянное уведомление.',
                ),
          child: const Text('Запустить проверку в фоне'),
        ),
        OutlinedButton(
          onPressed: _busy || !_state.serviceRunning
              ? null
              : () => _perform(widget.device.stopLocationDiagnostic),
          child: const Text('Остановить проверку'),
        ),
        const SizedBox(height: 8),
        const Text(
          'Перед блокировкой экрана убедитесь, что служба запущена. После проверки обязательно остановите её. Работа на HiOS требует испытания на вашем телефоне.',
        ),
        const SizedBox(height: 20),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _perform(widget.device.openSettings),
          icon: const Icon(Icons.settings_outlined),
          label: const Text('Настройки приложения'),
        ),
        TextButton(
          onPressed: _busy ? null : _refresh,
          child: const Text('Обновить состояние'),
        ),
        const SizedBox(height: 16),
        const Text(
          'Автоматический запуск после перезагрузки и восстановления убитого процесса не реализован. Полноэкранное окно поверх блокировки не используется.',
        ),
      ],
    ),
  );
}
