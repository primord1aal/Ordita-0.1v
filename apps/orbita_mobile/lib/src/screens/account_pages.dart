import 'package:flutter/material.dart';

import '../platform/device_gateway.dart';
import '../ui/theme.dart';
import '../ui/theme_settings.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({this.device, super.key});
  final DeviceGateway? device;

  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    final settings = ThemeSettingsScope.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Настройки'),
        toolbarHeight: 74,
        backgroundColor: palette.background,
        scrolledUnderElevation: 0,
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Тема приложения',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 4),
              Text(
                'Выбери, как будет выглядеть Орбита',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: palette.muted),
              ),
              const SizedBox(height: 20),
              for (final (mode, icon, label, description) in [
                (
                  ThemeMode.light,
                  Icons.light_mode_outlined,
                  'Светлая',
                  'Лён и мягкий дневной свет',
                ),
                (
                  ThemeMode.dark,
                  Icons.dark_mode_outlined,
                  'Тёмная',
                  'Графит и тёплая медь',
                ),
                (
                  ThemeMode.system,
                  Icons.settings_outlined,
                  'Как на устройстве',
                  'Меняется вместе с системой',
                ),
              ]) ...[
                ListTile(
                  key: Key('theme-${mode.name}'),
                  minTileHeight: 64,
                  contentPadding: EdgeInsets.zero,
                  titleTextStyle: Theme.of(context).textTheme.bodyMedium,
                  subtitleTextStyle: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(color: palette.muted),
                  selectedColor: palette.text,
                  leading: Icon(icon, color: palette.muted),
                  title: Text(label),
                  subtitle: Text(description),
                  trailing: settings.mode == mode
                      ? Icon(Icons.check, color: palette.accent)
                      : null,
                  selected: settings.mode == mode,
                  onTap: () => settings.setMode(mode),
                ),
                Divider(height: 1, color: palette.divider),
              ],
              const SizedBox(height: 14),
              Text(
                'ДОСТУПНОСТЬ',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                  color: palette.muted,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Размер текста — как в настройках устройства.',
                style: Theme.of(context).textTheme.bodyMedium
                    ?.copyWith(color: palette.muted),
              ),
              const SizedBox(height: 14),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.info_outline, color: palette.muted),
                title: const Text('О приложении'),
                trailing: Icon(Icons.chevron_right, color: palette.muted),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => AboutScreen(device: device),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({this.device, super.key});
  final DeviceGateway? device;

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
    return Scaffold(
      appBar: AppBar(title: const Text('О приложении')),
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
            Text('Версия $appVersion · тестовая основа'),
            const SizedBox(height: 20),
            Divider(color: palette.divider),
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
            if (device != null) ...[
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
