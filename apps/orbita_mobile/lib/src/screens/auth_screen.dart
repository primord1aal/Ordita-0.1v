import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../auth/auth_controller.dart';
import '../auth/auth_repository.dart';
import '../domain/contracts.dart';
import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import '../maps/geoapify_service.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import '../ui/orbita_brand.dart';
import '../ui/theme.dart';
import 'preview_screens.dart';

class AuthScreen extends StatefulWidget {
  const AuthScreen({
    required this.repository,
    required this.device,
    required this.mapSettings,
    this.addressServiceFactory,
    this.tileSessionFactory,
    super.key,
  });
  final AuthRepository repository;
  final DeviceGateway device;
  final MapSettings mapSettings;
  final AddressService Function(String)? addressServiceFactory;
  final MapTileSession Function(String)? tileSessionFactory;
  @override
  State<AuthScreen> createState() => _AuthScreenState();
}

class _AuthScreenState extends State<AuthScreen> {
  late final AuthController _controller;
  final _email = TextEditingController();
  final _password = TextEditingController();
  bool _starting = true, _obscurePassword = true;
  AuthPhase _resolvedPhase = AuthPhase.signedOut;
  ServerAccess? _resolvedAccess;

  @override
  void initState() {
    super.initState();
    _controller = AuthController(widget.repository)..addListener(_changed);
    unawaited(_controller.start());
  }

  void _changed() {
    if (_controller.busy) return;
    _starting = false;
    final fresh = _controller.access;
    final permitted =
        (_controller.phase == AuthPhase.active ||
            _controller.phase == AuthPhase.admin) &&
        fresh?.active == true;
    final previous = _resolvedAccess;
    if (previous != null &&
        (!permitted ||
            fresh!.userId != previous.userId ||
            fresh.role != previous.role)) {
      // Только завершённая смена/потеря доступа закрывает вложенные маршруты.
      // Обычная проверка неизменных прав не трогает стек и текущую вкладку.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) Navigator.of(context).popUntil((route) => route.isFirst);
      });
    }
    _resolvedAccess = permitted ? fresh : null;
    _resolvedPhase = _controller.phase;
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    _controller.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    if (_controller.busy || !widget.repository.configured) return;
    final password = _password.text;
    _password.clear();
    setState(() => _obscurePassword = true);
    FocusScope.of(context).unfocus();
    await _controller.signIn(_email.text, password);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _controller,
    builder: (context, _) {
      final visible = _controller.presentationAccess;
      if (visible != null) {
        final paused = _controller.busy || !_controller.foreground;
        return Stack(
          fit: StackFit.expand,
          children: [
            ExcludeFocus(
              excluding: !_controller.foreground,
              child: ExcludeSemantics(
                excluding: paused,
                child: AbsorbPointer(
                  absorbing: paused,
                  child: TickerMode(
                    enabled: !paused,
                    child: visible.role == UserRole.admin
                        ? _adminPage()
                        : PreviewShell(
                            key: ValueKey('${visible.userId}:${visible.role}'),
                            role: visible.role == UserRole.driver
                                ? PreviewRole.driver
                                : PreviewRole.passenger,
                            device: widget.device,
                            mapSettings: widget.mapSettings,
                            mapAccessAllowed: _controller.canUseRole,
                            mapForeground: _controller.foreground,
                            addressServiceFactory: widget.addressServiceFactory,
                            tileSessionFactory: widget.tileSessionFactory,
                            accountPanel: _accountPanel(visible),
                          ),
                  ),
                ),
              ),
            ),
            if (paused && _controller.foreground)
              const Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: SafeArea(
                  child: LinearProgressIndicator(
                    key: Key('access-recheck-progress'),
                    minHeight: 2,
                  ),
                ),
              ),
            if (!_controller.foreground)
              const ColoredBox(
                key: Key('background-privacy-cover'),
                color: OrbitaColors.background,
              ),
          ],
        );
      }
      final recoveringRole =
          _controller.checkKind == AuthCheckKind.validating &&
          (_resolvedPhase == AuthPhase.active ||
              _resolvedPhase == AuthPhase.admin);
      if (_controller.busy &&
          (_starting ||
              _controller.checkKind == AuthCheckKind.restoring ||
              recoveringRole)) {
        return const StartupSplash();
      }
      return _loginPage();
    },
  );

  Widget _accountPanel(ServerAccess access) => SurfaceCard(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const StateBadge('Аккаунт проверен', good: true),
        if (access.displayName.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(access.displayName),
        ],
        const SizedBox(height: 10),
        Text(
          access.role == UserRole.driver ? 'Роль: водитель' : 'Роль: пассажир',
        ),
        const SizedBox(height: 16),
        FullWidthAction(
          'Выйти',
          key: const Key('sign-out'),
          secondary: true,
          onPressed: _controller.signOut,
        ),
      ],
    ),
  );

  Widget _adminPage() => BrandedAccountPage(
    child: SurfaceCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const StateBadge('Аккаунт проверен', good: true),
          const SizedBox(height: 16),
          const Text(
            'Администратор: управление выполняется отдельно в веб-панели.',
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 20),
            FullWidthAction(
              'Проверка устройства',
              secondary: true,
              onPressed: () => Navigator.pushNamed(context, '/device-check'),
            ),
          ],
          const SizedBox(height: 16),
          FullWidthAction(
            'Выйти',
            key: const Key('sign-out'),
            secondary: true,
            onPressed: _controller.signOut,
          ),
        ],
      ),
    ),
  );

  Widget _loginPage() {
    final phase = _controller.busy ? _resolvedPhase : _controller.phase;
    final hasSession = _controller.session != null;
    final showFields =
        !hasSession ||
        phase != AuthPhase.failure ||
        _controller.checkKind == AuthCheckKind.signingIn;
    final message = _message(phase);
    final enabled = !_controller.busy && widget.repository.configured;
    final editingEnabled =
        !_controller.busy || _controller.checkKind == AuthCheckKind.validating;
    return BrandedAccountPage(
      child: SurfaceCard(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              showFields ? 'Вход в аккаунт' : 'Подключение к аккаунту',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            if (message != null) ...[
              const SizedBox(height: 16),
              Semantics(
                liveRegion: true,
                child: Text(
                  message,
                  key: const Key('auth-status'),
                  style: const TextStyle(color: OrbitaColors.warning),
                ),
              ),
            ],
            if (showFields) ...[
              const SizedBox(height: 20),
              const Text('Электронная почта'),
              const SizedBox(height: 8),
              Semantics(
                label: 'Электронная почта',
                child: TextField(
                  controller: _email,
                  key: const Key('login-email'),
                  enabled: editingEnabled,
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
                  enabled: editingEnabled,
                  obscureText: _obscurePassword,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => _signIn(),
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword
                          ? 'Показать пароль'
                          : 'Скрыть пароль',
                      onPressed: !editingEnabled
                          ? null
                          : () => setState(
                              () => _obscurePassword = !_obscurePassword,
                            ),
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 20),
              FullWidthAction(
                _controller.busy &&
                        _controller.checkKind == AuthCheckKind.signingIn
                    ? 'Входим…'
                    : 'Войти',
                key: const Key('sign-in'),
                onPressed: enabled ? _signIn : null,
              ),
              if (!widget.repository.configured) ...[
                const SizedBox(height: 12),
                const Text('Вход не настроен в этой тестовой версии.'),
              ],
            ],
            if (_controller.busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (hasSession || phase == AuthPhase.failure) ...[
              const SizedBox(height: 16),
              FullWidthAction(
                'Повторить',
                key: const Key('auth-retry'),
                secondary: true,
                onPressed: _controller.busy ? null : _controller.retry,
              ),
            ],
            if (hasSession) ...[
              const SizedBox(height: 12),
              FullWidthAction(
                'Выйти',
                key: const Key('sign-out'),
                secondary: true,
                onPressed: _controller.busy ? null : _controller.signOut,
              ),
            ],
          ],
        ),
      ),
    );
  }

  String? _message(AuthPhase phase) => switch (phase) {
    AuthPhase.checking || AuthPhase.signedOut => null,
    AuthPhase.active => null,
    AuthPhase.admin =>
      'Администратор: управление выполняется отдельно в веб-панели.',
    AuthPhase.noRole => 'Вы вошли. Роль ещё не назначена.',
    AuthPhase.revoked => 'Доступ отозван. Прежние действия закрыты.',
    AuthPhase.blocked => 'Аккаунт заблокирован. Обратитесь к администратору.',
    AuthPhase.unknownRole => 'Неизвестная роль. Обратитесь к администратору.',
    AuthPhase.noProfile => 'Профиль ещё не подготовлен администратором.',
    AuthPhase.inconsistent =>
      'Данные доступа требуют проверки администратором.',
    AuthPhase.failure =>
      _controller.failure?.kind == AuthFailureKind.http
          ? 'Сервис временно недоступен. Повторите попытку.'
          : _controller.failure?.message ?? 'Не удалось подтвердить доступ.',
  };
}
