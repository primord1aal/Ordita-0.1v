import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../platform/device_gateway.dart';
import '../orders/trip_people.dart';
import '../ui/components.dart' show SurfaceCard;
import '../ui/theme.dart';
import '../ui/theme_settings.dart';

double _toolbarHeight(BuildContext context, String title, double minimum) {
  final theme = Theme.of(context);
  final spacing =
      theme.appBarTheme.titleSpacing ?? NavigationToolbar.kMiddleSpacing;
  final titleWidth =
      MediaQuery.sizeOf(context).width -
      MediaQuery.paddingOf(context).horizontal -
      kToolbarHeight -
      2 * spacing;
  final painter = TextPainter(
    text: TextSpan(
      text: title,
      style: theme.appBarTheme.titleTextStyle ?? theme.textTheme.titleLarge,
    ),
    textDirection: Directionality.of(context),
    textScaler: MediaQuery.textScalerOf(context),
  )..layout(maxWidth: math.max(1, titleWidth));
  final height = math.max(minimum, painter.height + 20);
  painter.dispose();
  return height;
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({this.device, this.driver = false, super.key});

  final DeviceGateway? device;
  final bool driver;

  Future<void> _open(
    BuildContext context,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Не удалось открыть настройки устройства.'),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    final settings = ThemeSettingsScope.of(context);
    final gateway = device;
    const title = 'Настройки';
    return Scaffold(
      appBar: AppBar(
        title: const Text(title),
        toolbarHeight: _toolbarHeight(context, title, 56),
        backgroundColor: palette.background,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
          children: [
            Text('Внешний вид', style: Theme.of(context).textTheme.bodyMedium),
            const SizedBox(height: 8),
            Card(
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  for (final (mode, icon, label) in [
                    (ThemeMode.light, Icons.light_mode_outlined, 'Светлая'),
                    (ThemeMode.dark, Icons.dark_mode_outlined, 'Тёмная'),
                    (ThemeMode.system, Icons.devices_outlined, 'Системная'),
                  ])
                    ListTile(
                      key: Key('theme-${mode.name}'),
                      minTileHeight: 52,
                      leading: Icon(icon, color: palette.muted),
                      title: Text(label),
                      trailing: Icon(
                        settings.mode == mode
                            ? Icons.check_circle_outline
                            : Icons.radio_button_unchecked,
                        color: settings.mode == mode
                            ? palette.accent
                            : palette.muted,
                      ),
                      selected: settings.mode == mode,
                      onTap: () => settings.setMode(mode),
                    ),
                ],
              ),
            ),
            if (driver && gateway is OfferNotificationSettings) ...[
              const SizedBox(height: 16),
              Text(
                'Уведомления',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  leading: const Icon(Icons.notifications_outlined),
                  title: const Text('Звук и вибрация заказов'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _open(
                    context,
                    (gateway as OfferNotificationSettings)
                        .openOfferNotificationSettings,
                  ),
                ),
              ),
            ],
            if (gateway != null) ...[
              const SizedBox(height: 16),
              Text('Устройство', style: Theme.of(context).textTheme.bodyMedium),
              const SizedBox(height: 8),
              Card(
                clipBehavior: Clip.antiAlias,
                child: ListTile(
                  key: const Key('permission-settings'),
                  leading: const Icon(Icons.shield_outlined),
                  title: const Text('Разрешения приложения'),
                  trailing: const Icon(Icons.open_in_new),
                  onTap: () => _open(context, gateway.openSettings),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class AccountSupportScreen extends StatelessWidget {
  const AccountSupportScreen({super.key});

  @override
  Widget build(BuildContext context) => const _AccountInformation(
    title: 'Поддержка',
    child: Text(
      'Канал поддержки пока не подключён. Даты и адреса заказов можно найти во вкладке «Поездки».',
    ),
  );
}

class MyVehicleScreen extends StatefulWidget {
  const MyVehicleScreen({this.api, this.userId, super.key});
  final TripPeopleApi? api;
  final String? userId;

  @override
  State<MyVehicleScreen> createState() => _MyVehicleScreenState();
}

class _MyVehicleScreenState extends State<MyVehicleScreen> {
  late Future<VehicleDetails?> _vehicle = _read();

  Future<VehicleDetails?> _read() async {
    final api = widget.api;
    if (api == null || widget.userId == null) return null;
    final result = await api.loadOwnVehicle() as Map<String, dynamic>;
    if (result['user_id'] != widget.userId) throw const FormatException();
    return result['vehicle'] == null
        ? null
        : VehicleDetails.fromJson(result['vehicle']);
  }

  @override
  Widget build(BuildContext context) => _AccountInformation(
    title: 'Мой автомобиль',
    child: FutureBuilder<VehicleDetails?>(
      future: _vehicle,
      builder: (context, snapshot) {
        final vehicle = snapshot.data;
        if (snapshot.connectionState != ConnectionState.done) {
          return const LinearProgressIndicator();
        }
        if (snapshot.hasError) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Не удалось получить данные автомобиля.'),
              TextButton(
                onPressed: () => setState(() => _vehicle = _read()),
                child: const Text('Повторить'),
              ),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (vehicle == null)
              const Text('Подтверждённых данных об автомобиле пока нет.')
            else ...[
              Text(
                '${vehicle.make} ${vehicle.model}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text(vehicle.color),
              Text(
                vehicle.plate,
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ],
            const SizedBox(height: 8),
            const Text('Данные автомобиля обновляет администратор.'),
          ],
        );
      },
    ),
  );
}

class _AccountInformation extends StatelessWidget {
  const _AccountInformation({required this.title, required this.child});
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(title),
      toolbarHeight: _toolbarHeight(context, title, 56),
    ),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SurfaceCard(
          child: SizedBox(width: double.infinity, child: child),
        ),
      ),
    ),
  );
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({
    this.device,
    this.onOpenDriverDemo,
    this.diagnosticsEnabled = false,
    super.key,
  });
  final DeviceGateway? device;
  final bool diagnosticsEnabled;
  final VoidCallback? onOpenDriverDemo;

  Future<void> _openSystemSettings(BuildContext context) async {
    try {
      await device?.openSettings();
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
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    const title = 'О приложении';
    return Scaffold(
      appBar: AppBar(
        title: const Text(title, softWrap: true),
        toolbarHeight: _toolbarHeight(context, title, kToolbarHeight),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          children: [
            Text('орбита.', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 6),
            Text(
              'Местное такси для своих',
              style: Theme.of(context).textTheme.bodyMedium
                  ?.copyWith(color: palette.muted),
            ),
            const SizedBox(height: 20),
            Text('Версия $appVersion'),
            const SizedBox(height: 20),
            Divider(color: palette.divider),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              leading: const Icon(Icons.info_outline),
              title: const Text('Как используются адреса'),
              children: const [
                Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    'Для поиска адресов введённый текст и выбранные точки передаются Geoapify. Обе точки используются для построения маршрута. После нажатия «Заказать такси» адреса отправляются в службу такси.',
                  ),
                ),
              ],
            ),
            Divider(color: palette.divider),
            if (diagnosticsEnabled) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  Icons.phonelink_setup_outlined,
                  color: palette.muted,
                ),
                title: const Text('Проверка устройства'),
                trailing: Icon(Icons.chevron_right, color: palette.muted),
                onTap: () => Navigator.pushNamed(context, '/device-check'),
              ),
              Divider(color: palette.divider),
              if (onOpenDriverDemo != null) ...[
                ListTile(
                  key: const Key('driver-demo-entry'),
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.science_outlined, color: palette.muted),
                  title: const Text('Диагностика интерфейса водителя'),
                  trailing: Icon(Icons.chevron_right, color: palette.muted),
                  onTap: onOpenDriverDemo,
                ),
                Divider(color: palette.divider),
              ],
            ],
            if (device != null && diagnosticsEnabled) ...[
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.settings_outlined, color: palette.muted),
                title: const Text('Настройки приложения'),
                trailing: Icon(Icons.open_in_new, color: palette.muted),
                onTap: () => _openSystemSettings(context),
              ),
              Divider(color: palette.divider),
            ],
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.description_outlined, color: palette.muted),
              title: const Text('Лицензии'),
              trailing: Icon(Icons.chevron_right, color: palette.muted),
              onTap: () =>
                  showLicensePage(context: context, applicationName: 'орбита.'),
            ),
          ],
        ),
      ),
    );
  }
}
