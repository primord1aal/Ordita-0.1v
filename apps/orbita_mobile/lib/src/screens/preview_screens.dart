import 'package:flutter/material.dart';

import '../domain/contracts.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import '../ui/theme.dart';

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({required this.device, super.key});
  final DeviceGateway device;
  void _open(BuildContext context, PreviewRole role) => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => PreviewShell(role: role, device: device),
    ),
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const SizedBox(height: 24),
          const Text(
            'Орбита',
            style: TextStyle(fontSize: 30, fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          const Text('Чик, Прокудское и рядом'),
          const SizedBox(height: 28),
          Text(
            'Выберите интерфейс',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 12),
          const Text(
            'Тестовый просмотр. Это не вход в аккаунт, заказы пока недоступны.',
          ),
          const SizedBox(height: 20),
          _MenuTile(
            icon: Icons.person_outline,
            title: 'Пассажир',
            subtitle: 'Адреса и поездки',
            onTap: () => _open(context, PreviewRole.passenger),
          ),
          const SizedBox(height: 14),
          _MenuTile(
            icon: Icons.local_taxi_outlined,
            title: 'Водитель',
            subtitle: 'Рабочий экран',
            onTap: () => _open(context, PreviewRole.driver),
          ),
          const SizedBox(height: 24),
          const Text('Настройки и проверка телефона находятся в профиле.'),
          const SizedBox(height: 12),
          const Text(
            'Тестовая версия $appVersion',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    ),
  );
}

class PreviewShell extends StatefulWidget {
  const PreviewShell({required this.role, required this.device, super.key});
  final PreviewRole role;
  final DeviceGateway device;
  @override
  State<PreviewShell> createState() => _PreviewShellState();
}

class _PreviewShellState extends State<PreviewShell> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final driver = widget.role == PreviewRole.driver;
    final keyboardVisible = MediaQuery.viewInsetsOf(context).bottom > 0;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: IndexedStack(
          index: _index,
          children: [
            driver ? const DriverScreen() : const PassengerScreen(),
            const HistoryScreen(),
            ProfileScreen(driver: driver, device: widget.device),
          ],
        ),
      ),
      bottomNavigationBar: keyboardVisible
          ? null
          : AdaptiveNavigation(
              driver: driver,
              selected: _index,
              onSelected: (i) => setState(() => _index = i),
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

class PassengerScreen extends StatelessWidget {
  const PassengerScreen({super.key});
  @override
  Widget build(BuildContext context) => CustomScrollView(
    key: const Key('passenger-scroll'),
    slivers: [
      const SliverToBoxAdapter(child: BrandHeader()),
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        sliver: SliverList.list(
          children: [
            const MapPlaceholder(key: Key('passenger-map'), minimumHeight: 230),
            const SizedBox(height: 16),
            SurfaceCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const TextField(
                    key: Key('pickup'),
                    maxLines: null,
                    maxLength: 250,
                    textInputAction: TextInputAction.next,
                    decoration: InputDecoration(
                      labelText: 'Откуда',
                      prefixIcon: Icon(Icons.trip_origin),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const Key('destination'),
                    maxLines: null,
                    maxLength: 250,
                    textInputAction: TextInputAction.done,
                    onSubmitted: (_) => FocusScope.of(context).unfocus(),
                    decoration: const InputDecoration(
                      labelText: 'Куда',
                      prefixIcon: Icon(Icons.place_outlined),
                      counterText: '',
                    ),
                  ),
                  const SizedBox(height: 16),
                  const FullWidthAction(
                    'Заказать такси',
                    key: Key('create-order'),
                    onPressed: null,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'Заказы недоступны в режиме просмотра.',
                    style: TextStyle(fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ],
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
                'История появится после входа. В тестовой версии поездок нет.',
              ),
            ),
          ],
        ),
      ),
    ],
  );
}

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({required this.driver, required this.device, super.key});
  final bool driver;
  final DeviceGateway device;
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
            Text(
              'Настройки и проверки',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            _MenuTile(
              icon: Icons.settings_outlined,
              title: 'Настройки приложения',
              onTap: () => _settings(context),
            ),
            const SizedBox(height: 12),
            _MenuTile(
              icon: Icons.phonelink_setup_outlined,
              title: 'Проверка телефона',
              onTap: () => Navigator.pushNamed(context, '/device-check'),
            ),
            const SizedBox(height: 12),
            _MenuTile(
              icon: Icons.notifications_outlined,
              title: 'Проверка уведомлений',
              onTap: () =>
                  Navigator.pushNamed(context, '/device-check/notifications'),
            ),
            const SizedBox(height: 12),
            _MenuTile(
              icon: Icons.location_on_outlined,
              title: 'Диагностика геолокации',
              onTap: () =>
                  Navigator.pushNamed(context, '/device-check/location'),
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
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.maybePop(context),
              child: const Text('Сменить интерфейс просмотра'),
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
    this.subtitle,
  });
  final IconData icon;
  final String title;
  final String? subtitle;
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
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 5),
                      child: Text(subtitle!),
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
