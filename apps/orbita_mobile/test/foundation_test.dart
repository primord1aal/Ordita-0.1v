import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/domain/contracts.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';

void main() {
  test('Пустая конфигурация не подключает сервер', () {
    const configuration = BackendConfiguration();
    expect(configuration.isEmpty, isTrue);
    expect(configuration.isValid, isFalse);
  });
  test('Конфигурация допускает только HTTPS и публичный формат ключа', () {
    const key = 'sb_publishable_example';
    expect(
      const BackendConfiguration(
        url: 'https://example.supabase.co',
        publishableKey: key,
      ).isValid,
      isTrue,
    );
    expect(
      const BackendConfiguration(
        url: 'http://example.supabase.co',
        publishableKey: key,
      ).isValid,
      isFalse,
    );
    expect(
      const BackendConfiguration(
        url: 'https://example.supabase.co',
        publishableKey: 'service_role',
      ).isValid,
      isFalse,
    );
    expect(
      const BackendConfiguration(
        url: 'https://user:example@example.supabase.co',
        publishableKey: key,
      ).isValid,
      isFalse,
    );
  });
  test(
    'Ограниченный водитель продолжает принятую поездку без новых заказов',
    () {
      const policy = DriverWorkPolicy(
        role: UserRole.driver,
        approved: false,
        online: false,
        hasAcceptedTrip: true,
      );
      expect(policy.canContinueTrip, isTrue);
      expect(policy.canTrackWorkLocation, isTrue);
      expect(policy.canReceiveOffers, isFalse);
      expect(policy.showAccessRestriction, isFalse);
    },
  );
  test('После окончания поездки ограничение становится видимым', () {
    const policy = DriverWorkPolicy(
      role: UserRole.driver,
      approved: false,
      online: false,
      hasAcceptedTrip: false,
    );
    expect(policy.showAccessRestriction, isTrue);
    expect(policy.canTrackWorkLocation, isFalse);
  });
  test('Пассажир не получает водительский режим работы', () {
    const policy = DriverWorkPolicy(
      role: UserRole.passenger,
      approved: true,
      online: true,
      hasAcceptedTrip: true,
    );
    expect(policy.canReceiveOffers, isFalse);
    expect(policy.canContinueTrip, isFalse);
    expect(policy.canTrackWorkLocation, isFalse);
  });
  test(
    'Приблизительный доступ без Всегда достаточен для ручной проверки службы',
    () {
      const state = DeviceState(
        notifications: true,
        location: 'approximate',
        locationEnabled: true,
      );
      expect(state.backgroundLocation, isFalse);
      expect(state.canStartDiagnostic, isTrue);
    },
  );
  test(
    'Служба не запускается при отсутствии разрешений или выключенном GPS',
    () {
      expect(const DeviceState().canStartDiagnostic, isFalse);
      expect(
        const DeviceState(
          location: 'precise',
          locationEnabled: true,
        ).canStartDiagnostic,
        isFalse,
      );
      expect(
        const DeviceState(
          notifications: true,
          location: 'precise',
        ).canStartDiagnostic,
        isFalse,
      );
    },
  );
}
