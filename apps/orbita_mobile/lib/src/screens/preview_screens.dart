import 'package:flutter/material.dart';

import '../domain/contracts.dart';
import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import '../maps/geoapify_service.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import '../ui/theme.dart';
import 'passenger_screen.dart';

export 'passenger_screen.dart';

class PreviewShell extends StatefulWidget {
  const PreviewShell({
    required this.role,
    required this.device,
    required this.mapSettings,
    this.mapAccessAllowed = true,
    this.mapForeground = true,
    this.addressServiceFactory,
    this.tileSessionFactory,
    this.accountPanel,
    super.key,
  });
  final PreviewRole role;
  final DeviceGateway device;
  final MapSettings mapSettings;
  final bool mapAccessAllowed;
  final bool mapForeground;
  final AddressService Function(String)? addressServiceFactory;
  final MapTileSession Function(String)? tileSessionFactory;
  final Widget? accountPanel;
  @override
  State<PreviewShell> createState() => _PreviewShellState();
}

class _PreviewShellState extends State<PreviewShell> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final driver = widget.role == PreviewRole.driver;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return PopScope(
      canPop: _index == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _index != 0) setState(() => _index = 0);
      },
      child: Scaffold(
        body: SafeArea(
          bottom: false,
          child: IndexedStack(
            index: _index,
            children: [
              driver
                  ? const DriverScreen()
                  : PassengerScreen(
                      mapSettings: widget.mapSettings,
                      enabled: widget.mapAccessAllowed && _index == 0,
                      foreground: widget.mapForeground,
                      serviceFactory: widget.addressServiceFactory,
                      tileSessionFactory: widget.tileSessionFactory,
                    ),
              const HistoryScreen(),
              ProfileScreen(
                driver: driver,
                device: widget.device,
                accountPanel: widget.accountPanel,
              ),
            ],
          ),
        ),
        bottomNavigationBar: keyboardVisible
            ? null
            : AdaptiveNavigation(
                driver: driver,
                selected: _index,
                onSelected: (i) {
                  FocusScope.of(context).unfocus();
                  setState(() => _index = i);
                },
              ),
      ),
    );
  }
}

class DriverScreen extends StatelessWidget {
  const DriverScreen({super.key});
  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const Key('driver-scroll'),
    slivers: [
      const SliverToBoxAdapter(child: BrandHeader(showShift: true)),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        sliver: SliverFillRemaining(
          hasScrollBody: false,
          child: const Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: MapPlaceholder(key: Key('driver-map'))),
              SizedBox(height: 12),
              CurrentOrderCard(),
            ],
          ),
        ),
      ),
    ],
  );
}

class CurrentOrderCard extends StatelessWidget {
  const CurrentOrderCard({
    this.pickup,
    this.destination,
    this.status,
    this.actionLabel,
    this.onAction,
    super.key,
  });
  final String? pickup, destination, status, actionLabel;
  final VoidCallback? onAction;
  @override
  Widget build(BuildContext context) => SurfaceCard(
    key: const Key('current-order'),
    padding: const EdgeInsets.all(14),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Текущий заказ',
          style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 6),
        if (pickup == null)
          const Text('Нет активных заказов')
        else ...[
          Text('Откуда: $pickup'),
          const SizedBox(height: 8),
          Text('Куда: ${destination ?? 'Не указано'}'),
          if (status != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(status!),
            ),
          if (actionLabel != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: FullWidthAction(actionLabel!, onPressed: onAction),
            ),
        ],
      ],
    ),
  );
}

class HistoryScreen extends StatelessWidget {
  const HistoryScreen({super.key});
  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      const SliverToBoxAdapter(child: BrandHeader()),
      SliverPadding(
        padding: const EdgeInsets.all(16),
        sliver: SliverList.list(
          children: [
            Text('Ваши поездки', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            const SurfaceCard(
              child: Text(
                'История появится после подключения заказов. В тестовой версии поездок нет.',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    required this.driver,
    required this.device,
    this.accountPanel,
    super.key,
  });
  final bool driver;
  final DeviceGateway device;
  final Widget? accountPanel;
  Future<void> _settings(BuildContext context) async {
    try {
      await device.openSettings();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть настройки приложения.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) => CustomScrollView(
    slivers: [
      const SliverToBoxAdapter(child: BrandHeader()),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        sliver: SliverList.list(
          children: [
            Text(
              driver ? 'Профиль водителя' : 'Профиль пассажира',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 14),
            accountPanel ??
                SurfaceCard(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const StateBadge('Просмотр без входа', good: false),
                      const SizedBox(height: 12),
                      Text(
                        driver
                            ? 'Аккаунт и данные автомобиля подключит администратор.'
                            : 'Вход и данные пассажира будут подключены на следующем этапе.',
                      ),
                    ],
                  ),
                ),
            const SizedBox(height: 20),
            Text('Настройки', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _MenuTile(
              icon: Icons.settings_outlined,
              title: 'Настройки приложения',
              onTap: () => _settings(context),
            ),
            const SizedBox(height: 12),
            Text('Диагностика', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 12),
            _MenuTile(
              icon: Icons.phonelink_setup_outlined,
              title: 'Проверка устройства',
              onTap: () => Navigator.pushNamed(context, '/device-check'),
            ),
            const SizedBox(height: 12),
            const SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'О приложении',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  SizedBox(height: 6),
                  Text('Версия $appVersion · тестовая основа'),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class _MenuTile extends StatelessWidget {
  const _MenuTile({
    required this.icon,
    required this.title,
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) => Card(
    child: InkWell(
      borderRadius: BorderRadius.circular(20),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(icon, size: 24, color: OrbitaColors.accent),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: OrbitaColors.muted,
            ),
          ],
        ),
      ),
    ),
  );
}
