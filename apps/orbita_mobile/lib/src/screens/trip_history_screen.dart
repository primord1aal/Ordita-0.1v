import 'dart:async';

import 'package:flutter/material.dart';

import '../orders/trip_history.dart';
import '../orders/dispatch_panel.dart';
import '../ui/components.dart';

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

  @override
  Widget build(BuildContext context) {
    final records = _records;
    final locale = MaterialLocalizations.of(context);
    final theme = Theme.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16),
        children: [
          Text('Поездки', style: theme.textTheme.headlineMedium),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (widget.api == null)
            const Text('История поездок недоступна.')
          else if (_error) ...[
            const Text('Не удалось загрузить историю поездок.'),
            TextButton(onPressed: _load, child: const Text('Повторить')),
          ] else if (records?.isEmpty == true)
            const Text('Пока нет поездок.'),
          for (final trip in records ?? const <HistoryTrip>[]) ...[
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    trip.completed ? 'Завершена' : 'Отменена',
                    style: theme.textTheme.titleMedium,
                  ),
                  Text(locale.formatMediumDate(trip.finishedAt.toLocal())),
                  const SizedBox(height: 8),
                  OrderAddressLine(address: trip.pickup, pickup: true),
                  OrderAddressLine(address: trip.destination),
                ],
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
