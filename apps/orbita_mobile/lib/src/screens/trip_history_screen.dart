import 'dart:async';

import 'package:flutter/material.dart';

import '../orders/trip_history.dart';
import '../orders/dispatch_panel.dart';
import '../ui/theme.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({
    this.api,
    this.userId,
    this.driver = false,
    this.active = false,
    this.lastTerminal,
    super.key,
  });

  final TripHistoryApi? api;
  final String? userId;
  final bool driver, active;
  final (String, int, String)? lastTerminal;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  List<HistoryTrip>? _records;
  bool _hasMore = false, _busy = false, _error = false;
  int _generation = 0;
  String? _status;

  @override
  void initState() {
    super.initState();
    if (widget.active) unawaited(_load());
  }

  @override
  void didUpdateWidget(covariant HistoryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final accountChanged =
        oldWidget.api != widget.api ||
        oldWidget.userId != widget.userId ||
        oldWidget.driver != widget.driver;
    if (accountChanged || !widget.active) {
      _generation++;
      _busy = false;
      _records = null;
      _error = false;
      _hasMore = false;
    }
    if (widget.active &&
        (accountChanged ||
            !oldWidget.active ||
            (widget.lastTerminal != null &&
                oldWidget.lastTerminal != widget.lastTerminal))) {
      unawaited(_load());
    }
  }

  Future<void> _load({bool next = false}) async {
    final api = widget.api;
    final userId = widget.userId;
    if (!widget.active || api == null || userId == null) return;
    final before = next ? _records?.lastOrNull : null;
    final request = ++_generation;
    setState(() {
      _busy = true;
      _error = false;
    });
    try {
      final result = await api.loadTripHistory(
        driver: widget.driver,
        before: before,
        status: _status,
      );
      if (!mounted || request != _generation) return;
      final page = TripHistoryPage.parse(
        result,
        userId: userId,
        driver: widget.driver,
      );
      setState(() {
        _records = [if (next) ...?_records, ...page.items];
        _hasMore = page.hasMore;
      });
    } catch (_) {
      if (mounted && request == _generation) setState(() => _error = true);
    } finally {
      if (mounted && request == _generation) setState(() => _busy = false);
    }
  }

  void _filter(String? status) {
    if (_status == status) return;
    setState(() {
      _status = status;
      _records = null;
      _hasMore = false;
    });
    unawaited(_load());
  }

  Future<void> _details(HistoryTrip trip) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder: (context) {
      final date = MaterialLocalizations.of(context);
      final theme = Theme.of(context).textTheme;
      final finished = trip.finishedAt.toLocal();
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Детали поездки', style: theme.titleLarge),
            const SizedBox(height: 10),
            Text(
              trip.completed ? 'Завершена' : 'Отменена',
              style: theme.titleMedium,
            ),
            Text(
              '${date.formatMediumDate(finished)} · ${date.formatTimeOfDay(TimeOfDay.fromDateTime(finished))}',
            ),
            const Divider(),
            OrderAddressLine(address: trip.pickup, pickup: true),
            const SizedBox(height: 8),
            OrderAddressLine(address: trip.destination),
          ],
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final records = _records ?? const <HistoryTrip>[];
    final locale = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    final palette = OrbitaPalette.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text('Поездки', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 12),
          if (widget.api != null)
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                for (final (status, label) in [
                  (null, 'Все'),
                  ('completed', 'Завершённые'),
                  ('cancelled', 'Отменённые'),
                ])
                  ChoiceChip(
                    label: Text(label),
                    showCheckmark: false,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    labelPadding: EdgeInsets.zero,
                    shape: const RoundedRectangleBorder(
                      borderRadius: OrbitaChrome.controlShape,
                    ),
                    selectedColor: theme.brightness == Brightness.light
                        ? palette.text
                        : palette.accentSoft,
                    labelStyle: theme.textTheme.bodyMedium?.copyWith(
                      color:
                          _status == status &&
                              theme.brightness == Brightness.light
                          ? palette.surface
                          : palette.text,
                    ),
                    selected: _status == status,
                    onSelected: (_) => _filter(status),
                  ),
              ],
            ),
          const SizedBox(height: 12),
          if (_busy) const LinearProgressIndicator(),
          if (widget.api == null)
            const Text('История поездок недоступна.')
          else if (_error) ...[
            const Text('Не удалось загрузить историю поездок.'),
            TextButton(onPressed: _load, child: const Text('Повторить')),
          ] else if (_records != null && records.isEmpty)
            const Text('Пока нет поездок.'),
          for (final (index, trip) in records.indexed) ...[
            if (index == 0 ||
                !DateUtils.isSameDay(
                  records[index - 1].createdAt.toLocal(),
                  trip.createdAt.toLocal(),
                ))
              Padding(
                padding: const EdgeInsets.only(bottom: 8, top: 4),
                child: Text(
                  locale.formatMediumDate(trip.createdAt.toLocal()),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: OrbitaPalette.of(context).muted,
                  ),
                ),
              ),
            Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () => _details(trip),
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 8,
                        children: [
                          Text(
                            trip.completed ? 'Завершена' : 'Отменена',
                            style: theme.textTheme.bodyMedium?.copyWith(
                              color: trip.completed
                                  ? OrbitaPalette.of(context).success
                                  : OrbitaPalette.of(context).muted,
                            ),
                          ),
                          Text(
                            locale.formatTimeOfDay(
                              TimeOfDay.fromDateTime(trip.finishedAt.toLocal()),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              children: [
                                OrderAddressLine(
                                  address: trip.pickup,
                                  pickup: true,
                                ),
                                OrderAddressLine(address: trip.destination),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: OrbitaPalette.of(context).muted,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
          ],
          if (_hasMore)
            TextButton(
              onPressed: _busy ? null : () => _load(next: true),
              child: const Text('Показать ещё'),
            ),
        ],
      ),
    );
  }
}
