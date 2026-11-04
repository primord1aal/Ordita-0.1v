import 'package:flutter/material.dart';

import '../services/device_check_controller.dart';
import '../ui/components.dart';
import '../ui/theme.dart';

class LocationPermissionsScreen extends StatelessWidget {
  const LocationPermissionsScreen({required this.controller, super.key});
  final DeviceCheckController controller;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: controller,
    builder: (context, _) {
      final state = controller.state;
      final available = controller.available && !controller.busy;
      return Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              children: [
                const PageHeader('Доступ к геолокации'),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (controller.actionError != null) ...[
                        Text(
                          controller.actionError!,
                          style: const TextStyle(color: OrbitaColors.warning),
                        ),
                        const SizedBox(height: 16),
                      ],
                      SurfaceCard(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(
                              '1. При использовании',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Разрешите точную или приблизительную позицию. Для запуска проверки службы подходит «Только при использовании».',
                            ),
                            const SizedBox(height: 16),
                            FullWidthAction(
                              'Разрешить геопозицию',
                              key: const Key('foreground-permission'),
                              onPressed: available
                                  ? () => controller.run(
                                      controller
                                          .device
                                          .requestForegroundLocation,
                                      failure:
                                          'Не удалось запросить геопозицию.',
                                    )
                                  : null,
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
                              '2. Доступ в фоне',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                            const SizedBox(height: 12),
                            const Text(
                              'Дополнительный шаг, необязательный для ручной диагностики. На Android 11 и новее доступ меняется в системных настройках, отдельно от первого запроса.',
                            ),
                            const SizedBox(height: 16),
                            FullWidthAction(
                              'Настроить фоновый доступ',
                              key: const Key('background-permission'),
                              secondary: true,
                              onPressed:
                                  available && state.hasForegroundLocation
                                  ? () => controller.run(
                                      controller
                                          .device
                                          .requestBackgroundLocation,
                                      failure:
                                          'Не удалось открыть фоновый доступ.',
                                    )
                                  : null,
                            ),
                            if (!state.hasForegroundLocation)
                              const Padding(
                                padding: EdgeInsets.only(top: 10),
                                child: Text('Сначала выполните первый шаг.'),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Постоянный доступ не разрешает приложению произвольно запускать службу. Проверка стартует только по вашему действию из открытого экрана.',
                      ),
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
}
