import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/map_settings.dart';
import 'package:orbita_mobile/src/maps/address_models.dart';

import 'maps_test_fakes.dart';

void main() {
  test(
    'Ключ хранится отдельно и восстанавливается на том же устройстве',
    () async {
      final store = FakeMapKeyStore();
      final first = MapSettings(store: store),
          second = MapSettings(store: store);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.save(fakeMapKey);
      await second.load();
      expect(second.configured, isTrue);
      expect(second.clientKey, fakeMapKey);
      await second.clear();
      expect(store.saved, isNull);
      expect(second.configured, isFalse);
    },
  );
  test('Пароль/URL/Supabase-ключ не принимается как настройка карт', () async {
    final store = FakeMapKeyStore();
    final settings = MapSettings(store: store);
    addTearDown(settings.dispose);
    for (final value in [
      '',
      'short',
      'https://api.geoapify.com/?apiKey=anything',
      'sb_secret_fake_value_0123456789',
      'sb_publishable_fake_value_0123456789',
      'eyJfake_token_0123456789',
      'quoted "fake_key"',
    ]) {
      await expectLater(settings.save(value), throwsException);
    }
    expect(store.saved, isNull);
    expect(settings.configured, isFalse);
  });
  test(
    'Ошибка защищённого хранилища не блокирует запуск и не подменяет настройку',
    () async {
      final store = FakeMapKeyStore()..fail = true;
      final settings = MapSettings(store: store);
      addTearDown(settings.dispose);
      await settings.load();
      expect(settings.storageUnavailable, isTrue);
      expect(settings.configured, isFalse);
      await expectLater(
        settings.save(fakeMapKey),
        throwsA(
          isA<MapFailure>().having(
            (e) => e.kind,
            'kind',
            MapFailureKind.storage,
          ),
        ),
      );
      expect(settings.configured, isFalse);
    },
  );
}
