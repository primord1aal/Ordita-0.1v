import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/auth/auth_controller.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';

import 'fake_auth_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'Сохранение представления не разрешает работу до завершения проверки',
    () async {
      final repository = FakeAuthRepository()..saved = testSession();
      final controller = AuthController(repository);
      final pending = Completer<ServerAccess>();
      addTearDown(controller.dispose);
      await controller.start();
      repository.accessPending = pending;
      final recheck = controller.revalidate();
      try {
        expect(controller.presentationAccess, isNotNull);
        expect(controller.access, isNull);
        expect(controller.canUseRole, isFalse);
        var started = false;
        await expectLater(
          controller.guardAction((_) async {
            started = true;
            return true;
          }),
          throwsA(isA<AuthFailure>()),
        );
        expect(started, isFalse);
      } finally {
        pending.complete(testAccess());
        await recheck;
      }
      expect(controller.canUseRole, isTrue);
    },
  );
}
