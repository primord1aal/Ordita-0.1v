enum UserRole { passenger, driver, admin }

/// Просмотр экрана не является авторизованной серверной ролью.
enum PreviewRole { passenger, driver }

class ServerIdentity {
  const ServerIdentity({required this.userId, required this.role});
  final String userId;
  final UserRole role;
}

/// Реализация Supabase получает роль с сервера после авторизации.
abstract interface class SessionRepository {
  Future<ServerIdentity?> restore();
  Future<void> signOut();
}

class DisconnectedSessionRepository implements SessionRepository {
  @override
  Future<ServerIdentity?> restore() async => null;
  @override
  Future<void> signOut() async {}
}

class BackendConfiguration {
  const BackendConfiguration({this.url = '', this.publishableKey = ''});
  const BackendConfiguration.fromEnvironment()
    : url = const String.fromEnvironment('SUPABASE_URL'),
      publishableKey = const String.fromEnvironment('SUPABASE_PUBLISHABLE_KEY');
  final String url;
  final String publishableKey;

  bool get isEmpty => url.isEmpty && publishableKey.isEmpty;
  bool get isValid {
    final uri = Uri.tryParse(url);
    return uri != null &&
        uri.scheme == 'https' &&
        uri.host.isNotEmpty &&
        uri.userInfo.isEmpty &&
        uri.query.isEmpty &&
        uri.fragment.isEmpty &&
        publishableKey.startsWith('sb_publishable_') &&
        publishableKey.length > 'sb_publishable_'.length;
  }
}

/// Подсказка интерфейсу; сервер независимо проверяет права.
class DriverWorkPolicy {
  const DriverWorkPolicy({
    required this.role,
    required this.approved,
    required this.online,
    required this.hasAcceptedTrip,
  });
  final UserRole role;
  final bool approved;
  final bool online;
  final bool hasAcceptedTrip;
  bool get canReceiveOffers =>
      role == UserRole.driver && approved && online && !hasAcceptedTrip;
  bool get canContinueTrip => role == UserRole.driver && hasAcceptedTrip;
  bool get canTrackWorkLocation =>
      role == UserRole.driver && (hasAcceptedTrip || approved && online);
  bool get showAccessRestriction =>
      role == UserRole.driver && !approved && !hasAcceptedTrip;
}

/// Контракт серверного Push; локальная диагностика его не реализует.
abstract interface class OrderPushGateway {
  Future<void> registerCurrentDevice();
  Future<void> unregisterCurrentDevice();
  Stream<OrderPushEvent> get events;
}

class OrderPushEvent {
  const OrderPushEvent({
    required this.eventId,
    required this.orderId,
    required this.offerId,
    required this.expiresAt,
  });
  final String eventId;
  final String orderId;
  final String offerId;
  final DateTime expiresAt;
}
