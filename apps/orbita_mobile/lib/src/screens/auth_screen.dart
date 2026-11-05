import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/auth_repository.dart';
import '../domain/contracts.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import 'preview_screens.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({required this.repository, required this.device, super.key});
  final AuthRepository repository;
  final DeviceGateway device;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final AuthController _controller;
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _login = false;
  @override
  void initState() {
    super.initState();
    _controller = AuthController(widget.repository)..start();
  }

  @override
  void dispose() {
    _controller.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    final password = _password.text;
    _password.clear();
    FocusScope.of(context).unfocus();
    await _controller.signIn(_email.text, password);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      if (_controller.canUseRole) {
        final access = _controller.access!;
        return PreviewShell(
          key: ValueKey('${access.userId}:${access.version}:${access.role}'),
          role: access.role == UserRole.driver
              ? PreviewRole.driver
              : PreviewRole.passenger,
          device: widget.device,
          accountPanel: SurfaceCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const StateBadge('Аккаунт проверен', good: true),
                if (access.displayName.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(access.displayName),
                ],
                const SizedBox(height: 12),
                const Text(
                  'Роль подтверждена сервером. Карты и заказы ещё не подключены.',
                ),
                const SizedBox(height: 12),
                FullWidthAction(
                  'Выйти на этом телефоне',
                  secondary: true,
                  onPressed: _controller.signOut,
                ),
              ],
            ),
          ),
        );
      }
      if (_controller.phase == AuthPhase.signedOut && !_login) {
        return WelcomeScreen(
          device: widget.device,
          onSignIn: () => setState(() => _login = true),
        );
      }
      final showLogin =
          _controller.phase == AuthPhase.signedOut ||
          _controller.phase == AuthPhase.failure && _controller.session == null;
      return Scaffold(
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const PageHeader('Аккаунт Орбиты'),
              SurfaceCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      _message,
                      style: Theme.of(context).textTheme.titleMedium,
                      key: const Key('auth-status'),
                    ),
                    const SizedBox(height: 16),
                    if (_controller.busy) ...[
                      const Center(child: CircularProgressIndicator()),
                      const SizedBox(height: 16),
                      const Text('Ожидание ограничено 12 секундами.'),
                    ],
                    if (_controller.failure != null) ...[
                      Text(
                        _controller.failure!.message,
                        key: const Key('auth-error'),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Причина недоступности сервера может быть неизвестна. Сетевая ошибка не удаляет сохранённую сессию.',
                      ),
                    ],
                    if (showLogin) ...[
                      const SizedBox(height: 12),
                      const Text('Электронная почта'),
                      const SizedBox(height: 8),
                      Semantics(
                        label: 'Электронная почта',
                        child: TextField(
                          controller: _email,
                          key: const Key('login-email'),
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.next,
                          autocorrect: false,
                          enableSuggestions: false,
                          decoration: const InputDecoration(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text('Пароль'),
                      const SizedBox(height: 8),
                      Semantics(
                        label: 'Пароль',
                        child: TextField(
                          controller: _password,
                          key: const Key('login-password'),
                          obscureText: true,
                          autocorrect: false,
                          enableSuggestions: false,
                          enableIMEPersonalizedLearning: false,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _signIn(),
                          decoration: const InputDecoration(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      FullWidthAction(
                        'Войти',
                        key: const Key('sign-in'),
                        onPressed: widget.repository.configured
                            ? _signIn
                            : null,
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'Только аккаунт, заранее созданный администратором. Свободная регистрация не подключена.',
                      ),
                      if (!widget.repository.configured)
                        const Text(
                          'Тестовый сервер не настроен в этой сборке.',
                        ),
                    ],
                    if (!_controller.busy) ...[
                      const SizedBox(height: 16),
                      FullWidthAction(
                        'Повторить проверку',
                        secondary: true,
                        onPressed: _controller.retry,
                      ),
                      if (_controller.session != null) ...[
                        const SizedBox(height: 12),
                        FullWidthAction(
                          'Выйти на этом телефоне',
                          secondary: true,
                          onPressed: _controller.signOut,
                        ),
                      ],
                    ],
                    const SizedBox(height: 16),
                    const Text(
                      'Диагностика доступна отдельно и не даёт рабочих полномочий.',
                    ),
                    const SizedBox(height: 12),
                    FullWidthAction(
                      'Проверка API',
                      secondary: true,
                      onPressed: () =>
                          Navigator.pushNamed(context, '/api-check'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
  String get _message => switch (_controller.phase) {
    AuthPhase.checking => 'Проверяем сессию и доступ',
    AuthPhase.signedOut => 'Вход в аккаунт',
    AuthPhase.active => 'Полномочия не подтверждены',
    AuthPhase.admin =>
      'Администратор: управление выполняется отдельно в веб-панели.',
    AuthPhase.noRole => 'Вы вошли. Роль ещё не назначена.',
    AuthPhase.revoked => 'Доступ отозван. Прежние действия закрыты.',
    AuthPhase.blocked => 'Аккаунт заблокирован. Обратитесь к администратору.',
    AuthPhase.unknownRole => 'Неизвестная роль. Доступ закрыт.',
    AuthPhase.noProfile => 'Профиль ещё не подготовлен администратором.',
    AuthPhase.inconsistent =>
      'Данные доступа требуют проверки администратором.',
    AuthPhase.failure => 'Не удалось подтвердить доступ',
  };
}
