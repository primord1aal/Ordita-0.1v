import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;

import '../domain/contracts.dart';
import '../orders/dispatch_controller.dart';
import '../orders/driver_push_registration.dart';
import '../ui/trip_notice.dart';
import '../orders/trip_history.dart';
import '../orders/trip_people.dart';
import '../orders/driver_offer_open.dart';
import '../maps/map_settings.dart';
import '../maps/map_tiles.dart';
import '../maps/geoapify_service.dart';
import '../maps/route_preview.dart';
import '../platform/device_gateway.dart';
import '../ui/components.dart';
import '../ui/theme.dart';
import 'account_pages.dart';
import 'passenger_screen.dart';
import 'trip_history_screen.dart';
import 'driver_screen.dart';

export 'passenger_screen.dart';
export 'driver_screen.dart';

class PreviewShell extends StatefulWidget {
  const PreviewShell({
    required this.role,
    required this.device,
    required this.mapSettings,
    this.mapAccessAllowed = true,
    this.diagnosticsEnabled = false,
    this.mapForeground = true,
    this.addressServiceFactory,
    this.routeServiceFactory,
    this.tileSessionFactory,
    this.accountPanel,
    this.dispatchApi,
    this.userId,
    this.driverOfferOpens,
    this.onDriverOnline,
    this.onSignOut,
    this.onOpenDriverDemo,
    super.key,
  });
  final DispatchApi? dispatchApi;
  final String? userId;
  final DriverOfferOpens? driverOfferOpens;
  final ValueChanged<bool>? onDriverOnline;
  final PreviewRole role;
  final DeviceGateway device;
  final MapSettings mapSettings;
  final bool mapAccessAllowed;
  final bool diagnosticsEnabled;
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
  DispatchController? _dispatch;
  bool _handlingOfferOpen = false;
  final _foregroundOffers = DriverForegroundOffers();
  String? _announcedOffer;

  bool get _canCheckOfferOpen =>
      widget.role == PreviewRole.driver &&
      widget.mapAccessAllowed &&
      widget.mapForeground &&
      _dispatch != null;

  @override
  void initState() {
    super.initState();
    if (widget.dispatchApi != null && widget.userId != null) {
      _dispatch = DispatchController(
        api: widget.dispatchApi!,
        userId: widget.userId!,
        driver: widget.role == PreviewRole.driver,
      );
      if (widget.role == PreviewRole.driver) {
        _dispatch!.addListener(_driverOnline);
      }
      _dispatch!.setEnabled(widget.mapAccessAllowed && widget.mapForeground);
    }
    widget.driverOfferOpens?.addListener(_scheduleOfferOpen);
    _scheduleOfferOpen();
  }

  void _driverOnline() {
    final dispatch = _dispatch;
    if (dispatch == null || !dispatch.canAct) return;
    final state = dispatch.state!;
    widget.onDriverOnline?.call(state.online);
    if (!widget.mapAccessAllowed || !widget.mapForeground) return;
    final deadline = state.offerExpiresAt;
    final seconds = deadline == null ? 0 : dispatch.secondsUntil(deadline);
    final id = seconds > 0 ? state.offerId : null;
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.android) {
      _foregroundOffers.update(id, deadline, seconds: seconds);
    }
    if (id == _announcedOffer) return;
    _announcedOffer = id;
    if (id == null || _index == 0) return;
    final address = state.trip?.pickup.address;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _announcedOffer != id || _index == 0) return;
      final remaining = dispatch.secondsUntil(deadline!);
      if (remaining == 0) return;
      showTripNotice(
        context,
        'Новый заказ',
        icon: Icons.notifications_active_outlined,
        subtitle: address,
        duration: Duration(seconds: remaining),
        action: SnackBarAction(
          label: 'Открыть',
          onPressed: () {
            if (mounted && _announcedOffer == id) setState(() => _index = 0);
          },
        ),
      );
    });
  }

  @override
  void didUpdateWidget(covariant PreviewShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    _dispatch?.setEnabled(widget.mapAccessAllowed && widget.mapForeground);
    if (oldWidget.driverOfferOpens != widget.driverOfferOpens) {
      oldWidget.driverOfferOpens?.removeListener(_scheduleOfferOpen);
      widget.driverOfferOpens?.addListener(_scheduleOfferOpen);
    }
    _scheduleOfferOpen();
  }

  void _scheduleOfferOpen() {
    if (_handlingOfferOpen ||
        !_canCheckOfferOpen ||
        widget.driverOfferOpens?.hasPending != true) {
      return;
    }
    _handlingOfferOpen = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_openConfirmedOffer());
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _openConfirmedOffer() async {
    try {
      if (!_canCheckOfferOpen) return;
      final open = widget.driverOfferOpens?.take();
      if (open == null || !await _dispatch!.verifyOfferOpen(open)) return;
      if (!mounted || !_canCheckOfferOpen) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
      if (_index != 0) setState(() => _index = 0);
    } finally {
      _handlingOfferOpen = false;
      if (mounted) _scheduleOfferOpen();
    }
  }

  @override
  void dispose() {
    widget.driverOfferOpens?.removeListener(_scheduleOfferOpen);
    _dispatch?.removeListener(_driverOnline);
    _dispatch?.dispose();
    super.dispose();
  }

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
                      MediaQuery.viewPaddingOf(context).vertical -
                      MediaQuery.viewInsetsOf(context).bottom)
                  .clamp(0.0, double.infinity);
          return Scaffold(
            body: SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: [
                  driver
                      ? DriverScreen(
                          mapSettings: widget.mapSettings,
                          dispatch: _dispatch,
                          device: widget.device,
                          enabled: widget.mapAccessAllowed && _index == 0,
                          foreground: widget.mapForeground,
                          trackActiveTrip:
                              widget.mapAccessAllowed && widget.mapForeground,
                          tileSessionFactory: widget.tileSessionFactory,
                        )
                      : PassengerScreen(
                          mapSettings: widget.mapSettings,
                          dispatch: _dispatch,
                          device: widget.device,
                          enabled: widget.mapAccessAllowed && _index == 0,
                          foreground: widget.mapForeground,
                          serviceFactory: widget.addressServiceFactory,
                          routeServiceFactory: widget.routeServiceFactory,
                          tileSessionFactory: widget.tileSessionFactory,
                        ),
                  ListenableBuilder(
                    listenable: _dispatch ?? const AlwaysStoppedAnimation(null),
                    builder: (context, _) {
                      final api = widget.dispatchApi;
                      final trip = _dispatch?.state?.trip;
                      return HistoryScreen(
                        api: api is TripHistoryApi
                            ? api as TripHistoryApi
                            : null,
                        userId: widget.userId,
                        driver: driver,
                        active:
                            _index == 1 &&
                            widget.mapAccessAllowed &&
                            widget.mapForeground,
                        lastTerminal: trip != null && !trip.active
                            ? (trip.id, trip.version, trip.status)
                            : null,
                      );
                    },
                  ),
                  ProfileScreen(
                    driver: driver,
                    diagnosticsEnabled: widget.diagnosticsEnabled,
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
                    api: widget.dispatchApi,
                    userId: widget.userId,
                    onBack: () => setState(() => _index = 0),
                  ),
                ],
              ),
            ),
            bottomNavigationBar: keyboardVisible
                ? null
                : AdaptiveNavigation(
                    driver: driver,
                    availableHeight: availableHeight,
                    selected: _index,
                    onSelected: (i) {
                      FocusScope.of(context).unfocus();
                      setState(() => _index = i);
                    },
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

class ProfileScreen extends StatelessWidget {
  const ProfileScreen({
    required this.driver,
    required this.device,
    this.diagnosticsEnabled = false,
    this.accountPanel,
    this.onSignOut,
    this.api,
    this.userId,
    this.onBack,
    this.onOpenDriverDemo,
    super.key,
  });
  final bool driver, diagnosticsEnabled;
  final DeviceGateway device;
  final Widget? accountPanel;
  final VoidCallback? onSignOut, onBack, onOpenDriverDemo;
  final DispatchApi? api;
  final String? userId;

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
              const SizedBox(height: 16),
              Material(
                color: palette.surface,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(color: palette.divider),
                ),
                child: Column(
                  children: [
                    if (driver) ...[
                      _ProfileRow(
                        icon: Icons.directions_car_outlined,
                        title: 'Мой автомобиль',
                        onTap: () {
                          final backend = api;
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => MyVehicleScreen(
                                api: backend is TripPeopleApi
                                    ? backend as TripPeopleApi
                                    : null,
                                userId: userId,
                              ),
                            ),
                          );
                        },
                      ),
                      const Divider(height: 1, indent: 16, endIndent: 16),
                    ],
                    _ProfileRow(
                      icon: Icons.settings_outlined,
                      title: 'Настройки',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              SettingsScreen(device: device, driver: driver),
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
                      icon: Icons.headset_mic_outlined,
                      title: 'Поддержка',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const AccountSupportScreen(),
                        ),
                      ),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    _ProfileRow(
                      icon: Icons.info_outline,
                      title: 'О приложении',
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => AboutScreen(
                            device: device,
                            diagnosticsEnabled: diagnosticsEnabled,
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
        if (onSignOut != null)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: FullWidthAction(
                'Выйти из аккаунта',
                key: const Key('sign-out'),
                secondary: true,
                onPressed: onSignOut,
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
    required this.onTap,
  });
  final IconData icon;
  final String title;
  final VoidCallback? onTap;
  @override
  Widget build(BuildContext context) {
    final palette = OrbitaPalette.of(context);
    return ListTile(
      minTileHeight: 56,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      leading: Icon(icon, color: palette.muted),
      title: Text(title),
      trailing: Icon(Icons.chevron_right, color: palette.muted),
      onTap: onTap,
    );
  }
}
