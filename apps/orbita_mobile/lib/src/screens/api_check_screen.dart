import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backend/api_probe.dart';
import '../backend/probe_journal.dart';
import '../platform/network_observer.dart';
import '../services/api_check_controller.dart';
import '../ui/components.dart';

class ApiCheckScreen extends StatefulWidget {
  const ApiCheckScreen({
    required this.probe,
    this.network,
    this.journal,
    super.key,
  });
  final ApiProbe probe;
  final NetworkObserver? network;
  final ProbeJournal? journal;
  @override
  State<ApiCheckScreen> createState() => _ApiCheckScreenState();
}

class _ApiCheckScreenState extends State<ApiCheckScreen> {
  late final ApiCheckController _controller;
  NetworkType? _expected;
  ProbeOperator? _operator;
  ProbeDns? _dns;
  int _window = 1;
  bool _confirmed = false, _manualNetwork = false;
  String? _copyMessage;

  @override
  void initState() {
    super.initState();
    _controller = ApiCheckController(
      probe: widget.probe,
      network: widget.network ?? const AndroidNetworkObserver(),
      journal: widget.journal ?? ProbeJournal(),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<T?> _select<T>(String title, Map<T, String> options) =>
      showModalBottomSheet<T>(
        context: context,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.85,
            ),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(title, style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 16),
                  for (final entry in options.entries) ...[
                    FullWidthAction(
                      entry.value,
                      secondary: true,
                      onPressed: () => Navigator.pop(context, entry.key),
                    ),
                    const SizedBox(height: 12),
                  ],
                ],
              ),
            ),
          ),
        ),
      );

  Widget _choice(String key, String label, VoidCallback action) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: FullWidthAction(
      label,
      key: Key(key),
      secondary: true,
      onPressed: _controller.busy ? null : action,
    ),
  );

  Future<void> _copy(String text) async {
    try {
      await Clipboard.setData(ClipboardData(text: text));
      if (mounted) {
        setState(() => _copyMessage = 'Диагностические сведения скопированы.');
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _copyMessage =
              'Не удалось скопировать. Результаты остаются в памяти.',
        );
      }
    }
  }

  Future<void> _clear() async {
    final clear = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Очистить серию?'),
        content: const Text(
          'Сначала скопируйте результаты. После очистки они не восстановятся.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Оставить'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Очистить'),
          ),
        ],
      ),
    );
    if (clear == true && mounted) {
      setState(() {
        _controller.journal.clear();
        _copyMessage = null;
      });
    }
  }

  Future<void> _check() async {
    if (_expected == null || _dns == null) return;
    setState(() => _copyMessage = null);
    await _controller.run(
      ProbeConditions(
        expectedNetwork: _expected!,
        dns: _dns!,
        window: _window,
        operator: _operator,
        ownerConfirmed: _confirmed,
        manualNetworkConfirmed: _manualNetwork,
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final current = _controller.current;
      final records = _controller.journal.records;
      final ready =
          widget.probe.configured &&
          widget.probe.domainMatches &&
          !_controller.busy &&
          !_controller.journal.full &&
          _confirmed &&
          _expected != null &&
          _dns != null &&
          (_expected != NetworkType.mobile || _operator != null) &&
          (current.type != NetworkType.unknown || _manualNetwork);
      return Scaffold(
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
                              'Запрос без аккаунта и записи в базу. Сам вход и права проверяются отдельно.',
                            ),
                            const SizedBox(height: 12),
                            Text(
                              'Домен запроса: ${widget.probe.targetUri?.host ?? 'Не определено'}',
                              key: const Key('target-domain'),
                            ),
                            const SizedBox(height: 10),
                            StateBadge(
                              widget.probe.domainMatches
                                  ? 'Домен соответствует конфигурации'
                                  : 'Домен не соответствует конфигурации',
                              good: widget.probe.domainMatches,
                            ),
                            const SizedBox(height: 10),
                            const Text(
                              'Совпадение проверяет настройки сборки, а не принадлежность облачного проекта.',
                              style: TextStyle(fontSize: 12),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              'Активная сеть Android: ${current.type.label}',
                              key: const Key('actual-network'),
                            ),
                            const SizedBox(height: 10),
                            FullWidthAction(
                              'Обновить сведения о сети',
                              secondary: true,
                              onPressed: _controller.busy
                                  ? null
                                  : _controller.refreshNetwork,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SurfaceCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Условия испытания',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Отметки ниже — сведения владельца. Они не переключают сеть и не подменяют снимок Android.',
                            ),
                            const SizedBox(height: 12),
                            _choice(
                              'expected-network',
                              'Сеть для серии: ${_expected?.label ?? 'Выбрать'}',
                              () async {
                                final value = await _select('Сеть для серии', {
                                  NetworkType.wifi: 'Wi-Fi',
                                  NetworkType.mobile: 'Мобильная сеть',
                                });
                                if (value != null && mounted) {
                                  setState(() {
                                    _expected = value;
                                    _manualNetwork = false;
                                  });
                                }
                              },
                            ),
                            if (_expected == NetworkType.mobile)
                              _choice(
                                'operator',
                                'Оператор: ${_operator?.label ?? 'Выбрать'}',
                                () async {
                                  final value = await _select(
                                    'Мобильный оператор',
                                    {
                                      for (final item in ProbeOperator.values)
                                        item: item.label,
                                    },
                                  );
                                  if (value != null && mounted) {
                                    setState(() => _operator = value);
                                  }
                                },
                              ),
                            _choice(
                              'dns',
                              'Частный DNS: ${_dns?.label ?? 'Выбрать'}',
                              () async {
                                final value = await _select(
                                  'Частный DNS — вручную',
                                  {
                                    for (final item in ProbeDns.values)
                                      item: item.label,
                                  },
                                );
                                if (value != null && mounted) {
                                  setState(() => _dns = value);
                                }
                              },
                            ),
                            _choice(
                              'test-window',
                              _window == 0
                                  ? 'Без сети / восстановление'
                                  : 'Окно испытания: $_window',
                              () async {
                                final value = await _select(
                                  'Метка окна — вручную',
                                  {
                                    1: 'Окно 1',
                                    2: 'Окно 2',
                                    0: 'Без сети / восстановление',
                                  },
                                );
                                if (value != null && mounted) {
                                  setState(() => _window = value);
                                }
                              },
                            ),
                            CheckboxListTile(
                              key: const Key('conditions-confirmed'),
                              contentPadding: EdgeInsets.zero,
                              title: const Text(
                                'VPN и прокси выключены',
                                style: TextStyle(fontSize: 14),
                              ),
                              value: _confirmed,
                              onChanged: _controller.busy
                                  ? null
                                  : (value) => setState(
                                      () => _confirmed = value ?? false,
                                    ),
                            ),
                            if (current.type == NetworkType.unknown)
                              CheckboxListTile(
                                key: const Key('manual-network'),
                                contentPadding: EdgeInsets.zero,
                                title: const Text(
                                  'Подтверждаю сеть вручную',
                                  style: TextStyle(fontSize: 14),
                                ),
                                value: _manualNetwork,
                                onChanged: _controller.busy
                                    ? null
                                    : (value) => setState(
                                        () => _manualNetwork = value ?? false,
                                      ),
                              ),
                            const SizedBox(height: 12),
                            FullWidthAction(
                              _controller.busy
                                  ? 'Проверяем…'
                                  : 'Проверить связь',
                              key: const Key('check-api'),
                              onPressed: ready ? _check : null,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Ожидание ограничено примерно 15 секундами. Запросы выполняются последовательно.',
                              style: TextStyle(fontSize: 12),
                            ),
                            if (_controller.journal.full)
                              const Text(
                                'Журнал заполнен. Скопируйте серию перед очисткой.',
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      SurfaceCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              'Результатов в памяти: ${records.length} / 100',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Перед холодным запуском скопируйте серию. После завершения процесса история обнулится. Файл журнала не создаётся.',
                            ),
                            const SizedBox(height: 12),
                            FullWidthAction(
                              'Скопировать текущую серию',
                              key: const Key('copy-series'),
                              secondary: true,
                              onPressed: records.isEmpty
                                  ? null
                                  : () => _copy(_controller.journal.export()),
                            ),
                            if (records.isNotEmpty)
                              TextButton(
                                onPressed: _controller.busy ? null : _clear,
                                child: const Text('Очистить серию'),
                              ),
                            if (_copyMessage != null)
                              Semantics(
                                liveRegion: true,
                                child: Text(_copyMessage!),
                              ),
                          ],
                        ),
                      ),
                      for (final (index, record)
                          in records.indexed.toList().reversed) ...[
                        const SizedBox(height: 16),
                        _resultCard(index + 1, record),
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

  Widget _resultCard(int number, ProbeRecord record) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Запрос $number · ${record.conditions.windowLabel}',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 12),
        StateBadge(record.result.message, good: record.result.success),
        const SizedBox(height: 12),
        Text(
          'Android: ${record.before.type.label} → ${record.after.type.label}',
        ),
        const SizedBox(height: 8),
        Text(record.networkEvidence),
        const SizedBox(height: 8),
        Text('Домен запроса: ${record.requestDomain ?? 'Не определено'}'),
        const SizedBox(height: 8),
        Text(record.domainLabel),
        const SizedBox(height: 8),
        Text(
          '${record.result.httpStatus == null ? 'HTTP-код не получен' : 'HTTP ${record.result.httpStatus}'} · ${record.result.elapsedMilliseconds} мс',
        ),
        const SizedBox(height: 8),
        Text(diagnosticTime(record.result.checkedAt.toLocal())),
        const SizedBox(height: 8),
        Text(
          record.coldFirst
              ? 'Первый запрос процесса Android'
              : 'Повторный запрос или метка процесса не подтверждена',
        ),
        const SizedBox(height: 12),
        FullWidthAction(
          'Скопировать результат',
          key: Key('copy-result-$number'),
          secondary: true,
          onPressed: () => _copy(record.export()),
        ),
      ],
    ),
  );
}
