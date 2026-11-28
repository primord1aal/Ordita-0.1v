import 'package:flutter/material.dart';

import '../ui/components.dart';
import '../maps/route_preview.dart';
import '../ui/theme.dart';
import 'dispatch_controller.dart';

class PassengerDispatchPanel extends StatelessWidget {
  const PassengerDispatchPanel({
    required this.controller,
    this.tripRoute,
    super.key,
  });
  final DispatchController controller;
  final RoutePreview? tripRoute;
  @override
  Widget build(BuildContext context) {
    final c = controller, state = c.state;
    final trip = state?.trip;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (c.busy) const LinearProgressIndicator(minHeight: 2),
        if (c.message != null) ...[
          Text(c.message!, key: const Key('order-error')),
          TextButton(
            onPressed: c.enabled && !c.busy ? c.refresh : null,
            child: const Text('Обновить заказ'),
          ),
        ],
        if (state == null && c.message == null)
          const Text('Проверяем текущий заказ…'),
        if (trip != null && trip.active)
          _PassengerTrip(controller: c, trip: trip, route: tripRoute),
        if (c.pending != null) ...[
          const Text(
            'Заказ отправлен без подтверждения. Повтор проверит тот же заказ.',
          ),
          TextButton(
            onPressed: c.enabled && !c.busy ? c.retryCreate : null,
            child: const Text('Проверить отправленный заказ'),
          ),
        ],
      ],
    );
  }
}

class _PassengerTrip extends StatelessWidget {
  const _PassengerTrip({
    required this.controller,
    required this.trip,
    this.route,
  });

  final DispatchController controller;
  final Trip trip;
  final RoutePreview? route;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = OrbitaPalette.of(context);
    final (status, timing) = switch (trip.status) {
      'created' => (trip.label, null),
      'accepted' => (trip.label, 'Время подачи уточняется'),
      'to_pickup' => ('Водитель едет к вам', 'Время подачи уточняется'),
      'arrived' => (trip.label, null),
      'riding' => ('Вы в поездке', 'Время до назначения уточняется'),
      _ => (trip.label, null),
    };
    final details = [
      if (route?.durationSeconds case final duration?)
        '≈ ${(duration / 60).ceil()} мин',
      if (route?.distanceMeters case final distance?)
        '${(distance / 1000).toStringAsFixed(1).replaceAll('.', ',')} км',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            children: [
              Icon(Icons.circle, size: 10, color: palette.success),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  status,
                  key: const Key('trip-status'),
                  style: theme.textTheme.titleLarge,
                ),
              ),
            ],
          ),
        ),
        if (timing != null) ...[
          const SizedBox(height: 4),
          Text(timing, style: theme.textTheme.titleMedium),
        ],
        if (details.isNotEmpty)
          Text(
            'Поездка · ${details.join(' · ')}',
            key: const Key('route-summary'),
            style: theme.textTheme.bodyMedium?.copyWith(color: palette.muted),
          ),
        if (trip.driverId != null) ...[
          const SizedBox(height: 10),
          DecoratedBox(
            decoration: BoxDecoration(
              color: palette.surfaceVariant,
              borderRadius: OrbitaChrome.controlShape,
            ),
            child: Padding(
              padding: const EdgeInsets.all(10),
              child: Row(
                children: [
                  CircleAvatar(
                    backgroundColor: palette.divider,
                    foregroundColor: palette.text,
                    child: const Icon(Icons.person_outline),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Водитель назначен',
                          style: theme.textTheme.bodyLarge,
                        ),
                        Text(
                          'Данные водителя и автомобиля недоступны',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: 10),
        OrderAddressLine(address: trip.pickup.address, pickup: true),
        const SizedBox(height: 4),
        OrderAddressLine(address: trip.destination.address),
        if (trip.status == 'created') ...[
          const SizedBox(height: 8),
          ValueListenableBuilder<int>(
            valueListenable: controller.clock,
            builder: (context, value, child) => Text(
              'Осталось до конца поиска: ${controller.secondsUntil(trip.expiresAt)} с',
              style: theme.textTheme.bodySmall,
            ),
          ),
          TextButton(
            onPressed: controller.canAct
                ? () => controller.cancel(trip.id)
                : null,
            child: const Text('Отменить заказ'),
          ),
        ],
      ],
    );
  }
}

class DriverDispatchPanel extends StatelessWidget {
  const DriverDispatchPanel({
    required this.controller,
    required this.onCompleted,
    super.key,
  });

  final DispatchController controller;
  final VoidCallback onCompleted;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;
    final trip = state?.trip;
    final offerId = state?.offerId;
    final theme = Theme.of(context);
    final palette = OrbitaPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (controller.busy) const LinearProgressIndicator(minHeight: 2),
        if (controller.message case final message?) ...[
          Text(message, key: const Key('order-error')),
          TextButton(
            onPressed: controller.enabled && !controller.busy
                ? controller.refresh
                : null,
            child: const Text('Обновить заказ'),
          ),
        ],
        if (state == null && controller.message == null)
          const Text('Проверяем текущий заказ…')
        else if (trip != null && offerId != null)
          _DriverOffer(
            key: ValueKey(offerId),
            controller: controller,
            trip: trip,
            offerId: offerId,
            deadline: state!.offerExpiresAt!,
          )
        else if (trip != null && trip.active)
          _DriverJourney(
            controller: controller,
            trip: trip,
            onCompleted: onCompleted,
          )
        else if (state != null)
          Row(
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.surfaceVariant,
                  shape: BoxShape.circle,
                ),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Icon(
                    state.online
                        ? Icons.monitor_heart_outlined
                        : Icons.power_settings_new,
                    color: state.online ? palette.success : palette.muted,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.online ? 'Ожидаем заказ' : 'Вне рабочей смены',
                      style: theme.textTheme.titleMedium,
                    ),
                    Text(
                      state.online
                          ? 'Вы доступны для предложений'
                          : 'Выйдите на линию для получения заказов',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: palette.muted,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
      ],
    );
  }
}

class _DriverOffer extends StatelessWidget {
  const _DriverOffer({
    required this.controller,
    required this.trip,
    required this.offerId,
    required this.deadline,
    super.key,
  });

  final DispatchController controller;
  final Trip trip;
  final String offerId;
  final DateTime deadline;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = OrbitaPalette.of(context);
    return ValueListenableBuilder<int>(
      valueListenable: controller.clock,
      builder: (context, _, addresses) {
        final remaining = controller.secondsUntil(deadline);
        final canRespond = controller.canAct && remaining > 0;
        final timer = Text(
          '$remaining с',
          key: const Key('offer-countdown'),
          style: theme.textTheme.titleLarge?.copyWith(color: palette.accent),
        );
        final decline = OutlinedButton(
          onPressed: canRespond
              ? () => controller.respond(false, offerId: offerId)
              : null,
          child: const Text('Отказаться'),
        );
        final accept = FilledButton(
          key: const Key('accept-offer'),
          onPressed: canRespond
              ? () => controller.respond(true, offerId: offerId)
              : null,
          child: const Text('Принять'),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 12,
              children: [
                Text(
                  'Новый заказ',
                  key: const Key('trip-status'),
                  style: theme.textTheme.titleLarge,
                ),
                timer,
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: (remaining / 25).clamp(0.0, 1.0)),
                duration:
                    remaining == 0 || MediaQuery.disableAnimationsOf(context)
                    ? Duration.zero
                    : const Duration(milliseconds: 220),
                builder: (context, fraction, _) => LinearProgressIndicator(
                  minHeight: 5,
                  value: fraction,
                  backgroundColor: palette.accentSoft,
                  semanticsLabel: 'Оставшееся время ответа',
                ),
              ),
            ),
            const SizedBox(height: 12),
            addresses!,
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, area) {
                final labelStyle = theme.textTheme.labelLarge!;
                final unit = (area.maxWidth - 8) / 5;
                final fits =
                    2 * unit >=
                        textWidth(context, 'Отказаться', labelStyle) + 32 &&
                    3 * unit >= textWidth(context, 'Принять', labelStyle) + 32;
                return !fits
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [accept, const SizedBox(height: 8), decline],
                      )
                    : Row(
                        children: [
                          Expanded(flex: 2, child: decline),
                          const SizedBox(width: 8),
                          Expanded(flex: 3, child: accept),
                        ],
                      );
              },
            ),
          ],
        );
      },
      child: Column(
        children: [
          OrderAddressLine(address: trip.pickup.address, pickup: true),
          const SizedBox(height: 6),
          OrderAddressLine(address: trip.destination.address),
        ],
      ),
    );
  }
}

class _DriverJourney extends StatelessWidget {
  const _DriverJourney({
    required this.controller,
    required this.trip,
    required this.onCompleted,
  });

  final DispatchController controller;
  final Trip trip;
  final VoidCallback onCompleted;

  @override
  Widget build(BuildContext context) {
    final (title, action, label, icon) = switch (trip.status) {
      'accepted' => (
        'Заказ принят',
        'to_pickup',
        'Ехать к пассажиру',
        Icons.navigation_outlined,
      ),
      'to_pickup' => (
        'К пассажиру',
        'arrived',
        'Я на месте',
        Icons.navigation_outlined,
      ),
      'arrived' => (
        'На месте',
        'riding',
        'Начать поездку',
        Icons.person_pin_circle_outlined,
      ),
      'riding' => (
        'В поездке',
        'completed',
        'Завершить поездку',
        Icons.route_outlined,
      ),
      _ => (trip.label, null, null, Icons.route_outlined),
    };
    final toPickup = trip.status != 'riding';
    final theme = Theme.of(context);
    final palette = OrbitaPalette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(icon, color: palette.accent),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                title,
                key: const Key('trip-status'),
                style: theme.textTheme.titleLarge,
              ),
            ),
          ],
        ),
        const Divider(),
        Text(
          toPickup ? 'Адрес подачи' : 'Адрес назначения',
          style: theme.textTheme.bodyMedium?.copyWith(color: palette.muted),
        ),
        const SizedBox(height: 4),
        Text(
          toPickup ? trip.pickup.address : trip.destination.address,
          style: theme.textTheme.titleMedium,
        ),
        if (action != null) ...[
          const SizedBox(height: 12),
          FullWidthAction(
            label!,
            onPressed: controller.canAct
                ? () async {
                    if (await controller.advance(action, orderId: trip.id) &&
                        action == 'completed') {
                      onCompleted();
                    }
                  }
                : null,
          ),
        ],
      ],
    );
  }
}

class OrderAddressLine extends StatelessWidget {
  const OrderAddressLine({
    required this.address,
    this.pickup = false,
    super.key,
  });

  final String address;
  final bool pickup;

  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    return Semantics(
      label: pickup ? 'Адрес подачи' : 'Адрес назначения',
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Icon(
              Icons.circle,
              size: 10,
              color: pickup ? palette.text : palette.accent,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(address)),
        ],
      ),
    );
  }
}
