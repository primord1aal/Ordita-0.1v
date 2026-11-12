import 'package:flutter/material.dart';

import '../domain/contracts.dart';
import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import '../maps/geoapify_service.dart';
import '../maps/route_preview.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import '../ui/theme.dart';
import 'account_pages.dart';
import 'passenger_screen.dart';
import 'driver_screen.dart';

export 'passenger_screen.dart';
export 'driver_screen.dart';

class PreviewShell extends StatefulWidget {
  const PreviewShell({
    required this.role,
    required this.device,
    required this.mapSettings,
    this.mapAccessAllowed = true,
    this.mapForeground = true,
    this.addressServiceFactory,
    this.routeServiceFactory,
    this.tileSessionFactory,
    this.accountPanel,
    this.onSignOut,
    this.onOpenDriverDemo,
    super.key,
  });
  final PreviewRole role;
  final DeviceGateway device;
  final MapSettings mapSettings;
  final bool mapAccessAllowed;
  final bool mapForeground;
  final AddressService Function(String)? addressServiceFactory;
  final RouteService Function(String)? routeServiceFactory;
  final MapTileSession Function(String)? tileSessionFactory;
  final Widget? accountPanel;
  final VoidCallback? onSignOut;
  final Future<int?> Function()? onOpenDriverDemo;
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
      child: LayoutBuilder(
        builder: (context, constraints) {
          final availableHeight =
              (constraints.maxHeight -
                      MediaQuery.paddingOf(context).vertical -
                      MediaQuery.viewInsetsOf(context).bottom)
                  .clamp(0.0, double.infinity);
          return Scaffold(
            resizeToAvoidBottomInset: driver || _index != 0,
            body: SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: [
                  driver
                      ? DriverScreen(
                          mapSettings: widget.mapSettings,
                          device: widget.device,
                          enabled: widget.mapAccessAllowed && _index == 0,
                          foreground: widget.mapForeground,
                          tileSessionFactory: widget.tileSessionFactory,
                        )
                      : PassengerScreen(
                          mapSettings: widget.mapSettings,
                          device: widget.device,
                          enabled: widget.mapAccessAllowed && _index == 0,
                          foreground: widget.mapForeground,
                          serviceFactory: widget.addressServiceFactory,
                          routeServiceFactory: widget.routeServiceFactory,
                          tileSessionFactory: widget.tileSessionFactory,
                        ),
                  const HistoryScreen(),
                  ProfileScreen(
                    driver: driver,
                    device: widget.device,
                    accountPanel: widget.accountPanel,
                    onSignOut: widget.onSignOut,
                    onOpenDriverDemo: widget.onOpenDriverDemo == null
                        ? null
                        : () async {
                            final index = await widget.onOpenDriverDemo!();
                            if (!mounted || index == null) return;
                            Navigator.of(this.context)
                                .popUntil((route) => route.isFirst);
                            setState(() => _index = index);
                          },
                    onTrips: () => setState(() => _index = 1),
                    onBack: () => setState(() => _index = 0),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: keyboardVisible && (driver || _index != 0)
                ? null
                : Visibility(
                    visible: !keyboardVisible,
                    maintainSize: true,
                    maintainAnimation: true,
                    maintainState: true,
                    child: AdaptiveNavigation(
                      driver: driver,
                      availableHeight: !driver && _index == 0
                          ? availableHeight +
                                MediaQuery.viewInsetsOf(context).bottom
                          : availableHeight,
                      selected: _index,
                      onSelected: (i) {
                        FocusScope.of(context).unfocus();
                        setState(() => _index = i);
                      },
                    ),
                  ),
          );
        },
      ),
    );
  }
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
            const SurfaceCard(child: Text('Пока нет поездок.')),
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
    this.onSignOut,
    this.onTrips,
    this.onBack,
    this.onOpenDriverDemo,
    super.key,
  });
  final bool driver;
  final DeviceGateway device;
  final Widget? accountPanel;
  final VoidCallback? onSignOut, onTrips, onBack, onOpenDriverDemo;

  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    return CustomScrollView(
      key: const Key('profile-scroll'),
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Row(
              children: [
                IconButton(
                  tooltip: 'К заказу',
                  onPressed: onBack,
                  icon: const Icon(Icons.arrow_back),
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    'Профиль',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 26),
          sliver: SliverList.list(
            children: [
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
              const SizedBox(height: 22),
              Text(
                'МОЙ АККАУНТ',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: palette.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Material(
                color: palette.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: palette.divider),
                ),
                child: Column(
                  children: [
                    _ProfileRow(
                      icon: Icons.history,
                      title: 'Поездки',
                      subtitle: 'История поездок',
                      onTap: onTrips,
                    ),
                    Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: palette.divider,
                    ),
                    _ProfileRow(
                      icon: Icons.settings_outlined,
                      title: 'Настройки',
                      subtitle: 'Тема и внешний вид',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => SettingsScreen(
                            device: device,
                            onOpenDriverDemo: onOpenDriverDemo,
                          ),
                        ),
                      ),
                    ),
                    Divider(
                      height: 1,
                      indent: 16,
                      endIndent: 16,
                      color: palette.divider,
                    ),
                    _ProfileRow(
                      icon: Icons.info_outline,
                      title: 'О приложении',
                      subtitle: 'Информация и диагностика',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AboutScreen(
                            device: device,
                            onOpenDriverDemo: onOpenDriverDemo,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        SliverFillRemaining(
          hasScrollBody: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.end,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (onSignOut != null) ...[
                  FullWidthAction(
                    'Выйти',
                    key: const Key('sign-out'),
                    secondary: true,
                    onPressed: onSignOut,
                  ),
                ],
                const SizedBox(height: 12),
                Text(
                  'орбита. · Местное такси для своих',
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: palette.muted),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _ProfileRow extends StatelessWidget {
  const _ProfileRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });
  final IconData icon;
  final String title, subtitle;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    return ListTile(
      minTileHeight: 72,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: palette.muted),
      title: Text(title),
      subtitle: Text(subtitle),
      trailing: Icon(Icons.chevron_right, color: palette.muted),
      onTap: onTap,
    );
  }
}
