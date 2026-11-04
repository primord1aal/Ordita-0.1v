import 'package:flutter/material.dart';

import '../backend/api_probe.dart';
import '../ui/components.dart';

class ApiCheckScreen extends StatefulWidget {
  const ApiCheckScreen({required this.probe, super.key});
  final ApiProbe probe;
  @override
  State<ApiCheckScreen> createState() => _ApiCheckScreenState();
}

class _ApiCheckScreenState extends State<ApiCheckScreen> {
  String? _network;
  bool _busy = false;
  final List<(String, ProbeResult)> _results = [];

  Future<void> _check() async {
    if (_busy || _network == null) return;
    final network = _network!;
    setState(() => _busy = true);
    final result = await widget.probe.check();
    if (!mounted) return;
    setState(() {
      _busy = false;
      _results.insert(0, (network, result));
      if (_results.length > 6) _results.removeLast();
    });
  }

  @override
  void dispose() {
    widget.probe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: SingleChildScrollView(
        child: Column(
          children: [
            const PageHeader('Проверка API'),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SurfaceCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Связь со службой входа',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Проверка из Android без входа в аккаунт. Данные базы не изменяются.',
                        ),
                        const SizedBox(height: 12),
                        StateBadge(
                          widget.probe.configured
                              ? 'Тестовый проект настроен'
                              : 'Нет конфигурации сборки',
                          good: widget.probe.configured,
                        ),
                        const SizedBox(height: 16),
                        const Text(
                          'Переключите сеть на телефоне, затем отметьте её здесь. VPN и прокси должны быть выключены.',
                        ),
                        const SizedBox(height: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final network in [
                              'Wi-Fi',
                              'Мобильная сеть',
                            ]) ...[
                              Semantics(
                                selected: _network == network,
                                child: OutlinedButton(
                                  onPressed: _busy
                                      ? null
                                      : () =>
                                            setState(() => _network = network),
                                  style: OutlinedButton.styleFrom(
                                    backgroundColor: _network == network
                                        ? Theme.of(context).colorScheme.primary
                                              .withValues(alpha: 0.12)
                                        : null,
                                  ),
                                  child: Text(
                                    network,
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 10),
                            ],
                          ],
                        ),
                        const SizedBox(height: 16),
                        FullWidthAction(
                          _busy ? 'Проверяем…' : 'Проверить связь',
                          key: const Key('check-api'),
                          onPressed:
                              !_busy &&
                                  _network != null &&
                                  widget.probe.configured
                              ? _check
                              : null,
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Ожидание — до 15 секунд. Успех этой проверки подтверждает связь со службой входа. Сам вход и права аккаунта проверяются отдельно.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  for (final (network, result) in _results) ...[
                    const SizedBox(height: 16),
                    SurfaceCard(
                      child: Semantics(
                        liveRegion: true,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              network,
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 10),
                            StateBadge(result.message, good: result.success),
                            const SizedBox(height: 10),
                            Text(
                              '${result.httpStatus == null ? 'HTTP-ответ не получен' : 'HTTP ${result.httpStatus}'} · ${result.elapsed.inMilliseconds} мс',
                            ),
                            const SizedBox(height: 6),
                            Text(
                              result.checkedAt
                                  .toLocal()
                                  .toString()
                                  .split('.')
                                  .first,
                              style: const TextStyle(fontSize: 12),
                            ),
                          ],
                        ),
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
}
