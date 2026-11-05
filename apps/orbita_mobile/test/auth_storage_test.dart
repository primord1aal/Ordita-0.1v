import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/auth/secure_auth_storage.dart';
import 'package:orbita_mobile/src/services/session_store.dart';

class MemorySessionStore implements SessionStore {
  String? value;
  Completer<void>? delayedWrite;
  bool fail = false;
  final List<String> operations = [];
  @override
  Future<String?> read() async {
    if (fail) throw StateError('Artificial storage error');
    return value;
  }

  @override
  Future<void> write(String session) async {
    operations.add('write');
    if (fail) throw StateError('Artificial storage error');
    await delayedWrite?.future;
    value = session;
  }

  @override
  Future<void> clear() async {
    operations.add('clear');
    if (fail) throw StateError('Artificial storage error');
    value = null;
  }
}

void main() {
  test(
    'Явный LocalStorage: чтение, запись и удаление через защищённый адаптер',
    () async {
      final memory = MemorySessionStore();
      final storage = SecureAuthStorage(memory);
      await storage.initialize();
      expect(await storage.hasAccessToken(), false);
      await storage.persistSession('artificial-session');
      expect(await storage.accessToken(), 'artificial-session');
      await storage.removePersistedSession();
      expect(await storage.hasAccessToken(), false);
    },
  );
  test('Завершение старой записи перед выходом не восстанавливает сессию после clear', () async {
    final memory = MemorySessionStore()..delayedWrite = Completer<void>();
    final storage = SecureAuthStorage(memory);
    final write = storage.persistSession('artificial-session');
    final clear = storage.removePersistedSession();
    memory.delayedWrite!.complete();
    await write;
    await clear;
    expect(await storage.accessToken(), isNull);
    expect(memory.operations, ['write', 'clear']);
  });
  test('Ошибка хранилища не раскрывает внутреннее исключение; очередь восстанавливается', () async {
    final memory = MemorySessionStore()..fail = true;
    final storage = SecureAuthStorage(memory);
    await expectLater(
      storage.accessToken(),
      throwsA(
        isA<AuthFailure>().having(
          (e) => e.kind,
          'kind',
          AuthFailureKind.storage,
        ),
      ),
    );
    memory.fail = false;
    await storage.persistSession('artificial-session');
    expect(await storage.hasAccessToken(), true);
  });
}
