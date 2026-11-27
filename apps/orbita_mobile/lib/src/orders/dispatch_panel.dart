import 'package:flutter/material.dart';

import '../ui/components.dart';
import 'dispatch_controller.dart';

class DispatchPanel extends StatelessWidget {
  const DispatchPanel({required this.controller, super.key});
  final DispatchController controller;
  @override
  Widget build(BuildContext context) {
    final c = controller, state = c.state;
    final trip = state?.trip;
    final offerId = state?.offerId;
    final next = switch (trip?.status) {
      'accepted' => ('to_pickup', 'К клиенту'),
      'to_pickup' => ('arrived', 'На месте'),
      'arrived' => ('riding', 'Начать поездку'),
      'riding' => ('completed', 'Завершить поездку'),
      _ => null,
    };
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
        if (trip != null) ...[
          const SizedBox(height: 8),
          Semantics(
            liveRegion: true,
            child: Text(
              offerId != null ? 'Новый заказ' : trip.label,
              key: const Key('trip-status'),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          const SizedBox(height: 8),
          Text('Откуда: ${trip.pickup.address}'),
          Text('Куда: ${trip.destination.address}'),
          const SizedBox(height: 10),
          if (!c.driver && trip.status == 'created') ...[
            ValueListenableBuilder<int>(
              valueListenable: c.clock,
              builder: (context, value, child) => Text(
                'Осталось до конца поиска: ${c.secondsUntil(trip.expiresAt)} с',
              ),
            ),
            TextButton(
              onPressed: c.canAct ? () => c.cancel(trip.id) : null,
              child: const Text('Отменить заказ'),
            ),
          ],
          if (offerId != null)
            ValueListenableBuilder<int>(
              valueListenable: c.clock,
              builder: (context, value, child) {
                final seconds = c.secondsUntil(state!.offerExpiresAt!);
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Ответить за $seconds с',
                      key: const Key('offer-countdown'),
                    ),
                    FullWidthAction(
                      'Принять',
                      key: const Key('accept-offer'),
                      onPressed: c.canAct && seconds > 0
                          ? () => c.respond(true, offerId: offerId)
                          : null,
                    ),
                    TextButton(
                      onPressed: c.canAct && seconds > 0
                          ? () => c.respond(false, offerId: offerId)
                          : null,
                      child: const Text('Отказаться'),
                    ),
                  ],
                );
              },
            )
          else if (c.driver && next != null)
            FullWidthAction(
              next.$2,
              onPressed: c.canAct
                  ? () => c.advance(next.$1, orderId: trip.id)
                  : null,
            ),
        ],
        if (c.driver && state != null && trip?.active != true) ...[
          const SizedBox(height: 8),
          Text(state.online ? 'На линии · ожидаем заказ' : 'Не на линии'),
          const Text('Для новых предложений оставайтесь на линии.'),
        ],
        if (!c.driver && c.pending != null) ...[
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
