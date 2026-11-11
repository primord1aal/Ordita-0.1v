import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Несекретная настройка интерфейса; сессия Auth хранится отдельно.
class ThemeSettings extends ChangeNotifier {
  ThemeSettings({Future<SharedPreferences> Function()? openPreferences})
    : _openPreferences = openPreferences ?? SharedPreferences.getInstance;

  static const storageKey = 'orbita.theme_mode';
  final Future<SharedPreferences> Function() _openPreferences;
  ThemeMode _mode = ThemeMode.system;
  bool _changedLocally = false;
  ThemeMode get mode => _mode;

  Future<void> load() async {
    try {
      final saved = (await _openPreferences()).getString(storageKey);
      if (_changedLocally) return;
      _mode = switch (saved) {
        'light' => ThemeMode.light,
        'dark' => ThemeMode.dark,
        _ => ThemeMode.system,
      };
      notifyListeners();
    } catch (_) {
      // Неисправное локальное хранилище не блокирует запуск приложения.
    }
  }

  Future<void> setMode(ThemeMode value) async {
    _changedLocally = true;
    _mode = value;
    notifyListeners();
    try {
      await (await _openPreferences()).setString(storageKey, value.name);
    } catch (_) {
      // Выбор действует до закрытия приложения; при следующем запуске
      // вернётся последний успешно сохранённый режим.
    }
  }
}

class ThemeSettingsScope extends InheritedNotifier<ThemeSettings> {
  const ThemeSettingsScope({
    required ThemeSettings settings,
    required super.child,
    super.key,
  }) : super(notifier: settings);

  static ThemeSettings of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<ThemeSettingsScope>()!
      .notifier!;
}
