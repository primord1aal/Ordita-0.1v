import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';

import 'fake_auth_repository.dart';

void main() {
  test('Неизвестная роль/состояние и отсутствие версии приводят к закрытому доступу', () {
    for (final data in [
      {'status': 'active', 'role': 'future-role', 'access_version': 1},
      {'status': 'active', 'role': 'driver', 'access_version': null},
      {'status': 'active', 'role': 'driver', 'access_version': -1},
      {'status': 'unexpected', 'role': 'admin', 'access_version': 1},
      {'status': 'blocked', 'role': 'driver', 'access_version': 1},
    ]) {
      expect(
        ServerAccess.fromJson({'user_id': userA, ...data}, userA).active,
        false,
      );
    }
  });
  test('Чужой user_id не принимается даже с ролью admin', () {
    expect(
      () => ServerAccess.fromJson({
        'user_id': userB,
        'status': 'active',
        'role': 'admin',
        'access_version': 1,
      }, userA),
      throwsA(isA<AuthFailure>()),
    );
  });
}
