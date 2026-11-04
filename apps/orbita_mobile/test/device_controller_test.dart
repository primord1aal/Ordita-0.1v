import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/platform/device_gateway.dart';
import 'package:orbita_mobile/src/services/device_check_controller.dart';

import 'fake_device.dart';
import 'test_helpers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Обновление состояния не запускает службу и не просит разрешения',
    () async {
      final device = FakeDevice()..state = readyState(running: true);
      final controller = DeviceCheckController(device);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.state.serviceRunning, isTrue);
      expect(device.calls.every((name) => name == 'read'), isTrue);
    },
  );
  test(
    'Сигнал во время чтения приводит к свежему дополнительному чтению',
    () async {
      final device = FakeDevice();
      final first = Completer<DeviceState>();
      var reads = 0;
      device.readHandler = () {
        reads++;
        return reads == 1
            ? first.future
            : Future.value(readyState(running: true));
      };
      final controller = DeviceCheckController(device);
      addTearDown(controller.dispose);
      final refreshed = controller.refresh();
      first.complete(const DeviceState());
      await refreshed;
      expect(reads, 2);
      expect(controller.state.serviceRunning, isTrue);
    },
  );
  test(
    'Повтор действия во время ожидания не отправляется второй раз',
    () async {
      final device = FakeDevice()..state = readyState();
      final done = Completer<void>();
      device.actionHandler = (_) => done.future;
      final controller = DeviceCheckController(device);
      addTearDown(controller.dispose);
      await controller.refresh();
      final action = controller.run(
        device.startLocationDiagnostic,
        failure: 'Не запущено',
      );
      expect(
        await controller.run(
          device.startLocationDiagnostic,
          failure: 'Не запущено',
        ),
        isFalse,
      );
      done.complete();
      expect(await action, isTrue);
      expect(device.calls.where((name) => name == 'start').length, 1);
    },
  );
  test(
    'Ошибка действия отделена от показателей и не исчезает от фонового чтения',
    () async {
      final device = FakeDevice()..state = readyState();
      device.actionHandler = (_) async => throw StateError('Тест');
      final controller = DeviceCheckController(device);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(
        await controller.run(
          device.showLocalNotification,
          failure: 'Не показано',
        ),
        isFalse,
      );
      await controller.refresh();
      expect(controller.actionError, 'Не показано');
      expect(controller.readError, isNull);
    },
  );
  test(
    'После ошибки чтения нет вечной загрузки, повтор восстанавливает данные',
    () async {
      final device = FakeDevice()..failRead = true;
      final controller = DeviceCheckController(device);
      addTearDown(controller.dispose);
      await controller.refresh();
      expect(controller.loading, isFalse);
      expect(controller.available, isFalse);
      device.failRead = false;
      device.state = readyState();
      await controller.refresh();
      expect(controller.available, isTrue);
      expect(controller.readError, isNull);
    },
  );
  test(
    'Закрытие диагностики не останавливает запущенную вручную службу',
    () async {
      final device = FakeDevice()..state = readyState(running: true);
      final controller = DeviceCheckController(device);
      await controller.refresh();
      controller.dispose();
      expect(device.calls, isNot(contains('stop')));
    },
  );
  test(
    'Поздний результат после закрытия экрана не уведомляет слушателей',
    () async {
      final device = FakeDevice();
      final done = Completer<DeviceState>();
      device.readHandler = () => done.future;
      final controller = DeviceCheckController(device);
      final read = controller.refresh();
      controller.dispose();
      done.complete(readyState());
      await read;
    },
  );
}
