import 'package:flutter/material.dart';

import '../maps/address_models.dart';
import '../maps/map_settings.dart';
import '../ui/components.dart';

/// Только расширенная диагностика debug APK; не обычная настройка пассажира.
class MapSettingsScreen extends StatefulWidget {
  const MapSettingsScreen({required this.settings, super.key});
  final MapSettings settings;
  @override
  State<MapSettingsScreen> createState() => _MapSettingsScreenState();
}

class _MapSettingsScreenState extends State<MapSettingsScreen> {
  final _key = TextEditingController();
  bool _busy = false;
  String? _message;
  Future<void> _save({bool clear = false}) async {
    if (_busy) return;
    final input = _key.text;
    _key.clear();
    FocusScope.of(context).unfocus();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      if (clear) {
        await widget.settings.clear();
      } else {
        await widget.settings.save(input);
      }
      if (mounted) {
        _message = clear
            ? 'Ключ удалён с этого устройства.'
            : 'Ключ сохранён на этом устройстве. Можно открыть карту.';
      }
    } on MapFailure catch (failure) {
      if (mounted) {
        _message = failure.kind == MapFailureKind.configuration
            ? 'Вставьте API-ключ проекта Geoapify, без кавычек и URL.'
            : failure.message;
      }
    } catch (_) {
      if (mounted) {
        _message = 'Не удалось сохранить настройку в защищённом хранилище.';
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _key.clear();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Настройка карт')),
    body: SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SurfaceCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text(
                'Настройка тестовой сборки. API-ключ берётся в вашем проекте Geoapify Free. Не используйте здесь ключи Supabase или пароль.',
              ),
              const SizedBox(height: 16),
              ListenableBuilder(
                listenable: widget.settings,
                builder: (context, _) => Text(
                  widget.settings.configured
                      ? 'Ключ карт сохранён.'
                      : 'Ключ карт не задан.',
                ),
              ),
              if (widget.settings.storageUnavailable)
                const Text('Не удалось прочитать защищённую настройку.'),
              const SizedBox(height: 16),
              const Text('API-ключ Geoapify'),
              const SizedBox(height: 8),
              TextField(
                key: const Key('map-api-key'),
                controller: _key,
                obscureText: true,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                enableIMEPersonalizedLearning: false,
                decoration: const InputDecoration(),
                onSubmitted: (_) => _save(),
              ),
              const SizedBox(height: 16),
              FullWidthAction('Сохранить', onPressed: _busy ? null : _save),
              const SizedBox(height: 12),
              FullWidthAction(
                'Удалить ключ',
                secondary: true,
                onPressed: _busy ? null : () => _save(clear: true),
              ),
              if (_message != null)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Semantics(liveRegion: true, child: Text(_message!)),
                ),
              const SizedBox(height: 16),
              const Text(
                'Ключ не передаётся в Supabase и не попадает в исходники или отчёты. При удалении приложения эта настройка тоже удаляется. Лимит и расходы контролируются в Geoapify.',
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
