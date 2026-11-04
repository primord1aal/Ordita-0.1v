import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/backend/api_probe.dart';
import 'package:orbita_mobile/src/backend/probe_journal.dart';
import 'package:orbita_mobile/src/platform/network_observer.dart';
import 'package:orbita_mobile/src/services/api_check_controller.dart';

import 'api_fixtures.dart';

const wifiConditions = ProbeConditions(
  expectedNetwork: NetworkType.wifi,
  dns: ProbeDns.automatic,
  window: 1,
  ownerConfirmed: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakeApiProbe probe;
  late FakeNetworkObserver network;
  late ProbeJournal journal;
  late ApiCheckController controller;
  setUp(() {
    probe = FakeApiProbe();
    network = FakeNetworkObserver();
    journal = ProbeJournal();
    controller = ApiCheckController(
      probe: probe,
      network: network,
      journal: journal,
    );
  });
  tearDown(() => controller.dispose());

  test(
    'Android-снимки, домен, условия, дата и первый запрос попадают в запись',
    () async {
      final record = (await controller.run(wifiConditions))!;
      expect(record.networkStable, isTrue);
      expect(record.domainMatches, isTrue);
      expect(record.coldFirst, isTrue);
      expect(record.withinLimit, isTrue);
      expect(record.export(), contains('VPN (владелец): Выключен'));
      expect(record.export(), contains('Окно испытания (владелец): Окно 1'));
      expect(
        record.export(),
        contains('Ожидаемый домен: aaaaaaaaaaaaaaaaaaaa.supabase.co'),
      );
      final second = (await controller.run(wifiConditions))!;
      expect(second.coldFirst, isFalse);
      expect(journal.records.length, 2);
    },
  );

  test('Несовпадение домена не отправляет HTTP', () async {
    probe.domainMatches = false;
    final record = (await controller.run(wifiConditions))!;
    expect(record.result.state, ProbeState.domainMismatch);
    expect(probe.calls, 0);
    expect(record.requestAttempted, isFalse);
  });

  test(
    'Нет сети: быстрый отказ и успешный повтор после восстановления',
    () async {
      network.type = NetworkType.none;
      final offline = (await controller.run(wifiConditions))!;
      expect(offline.result.state, ProbeState.noNetwork);
      expect(probe.calls, 0);
      expect(controller.busy, isFalse);
      network.type = NetworkType.wifi;
      expect((await controller.run(wifiConditions))!.result.success, isTrue);
      expect(probe.calls, 1);
    },
  );

  test('Выбор Wi-Fi не подменяет фактическую мобильную сеть', () async {
    network.type = NetworkType.mobile;
    final record = (await controller.run(wifiConditions))!;
    expect(record.result.state, ProbeState.networkMismatch);
    expect(probe.calls, 0);
    expect(record.before.type, NetworkType.mobile);
  });

  test('Смена активной сети видна даже при HTTP 200', () async {
    network.afterType = NetworkType.mobile;
    final record = (await controller.run(wifiConditions))!;
    expect(record.result.success, isTrue);
    expect(record.networkChanged, isTrue);
    expect(record.networkStable, isFalse);
  });

  test('Неизвестный транспорт не превращается автоматически в Wi-Fi', () async {
    network.type = NetworkType.unknown;
    expect((await controller.run(wifiConditions))!.requestAttempted, isFalse);
    final record = (await controller.run(
      const ProbeConditions(
        expectedNetwork: NetworkType.wifi,
        dns: ProbeDns.automatic,
        window: 1,
        ownerConfirmed: true,
        manualNetworkConfirmed: true,
      ),
    ))!;
    expect(record.result.success, isTrue);
    expect(record.before.type, NetworkType.unknown);
    expect(record.networkStable, isFalse);
    expect(
      record.export(),
      contains('Ручное подтверждение неопределённой сети: Да'),
    );
  });

  for (final proxy in [false, true]) {
    test('Обнаруженный ${proxy ? 'прокси' : 'VPN'} блокирует запрос', () async {
      if (proxy) {
        network.proxy = true;
      } else {
        network.vpn = true;
      }
      final record = (await controller.run(wifiConditions))!;
      expect(record.result.state, ProbeState.conditionsBlocked);
      expect(probe.calls, 0);
    });
  }

  test('Изменение прокси после HTTP видно и не подтверждает условия', () async {
    network.afterProxy = true;
    final record = (await controller.run(wifiConditions))!;
    expect(record.result.success, isTrue);
    expect(record.environmentConflict, isTrue);
    expect(
      record.networkEvidence,
      contains('Условия испытания не подтверждены'),
    );
  });

  test('Журнал не теряет первые записи после шестого запроса', () async {
    for (var i = 0; i < 12; i++) {
      await controller.run(wifiConditions);
    }
    expect(journal.records.length, 12);
    expect(journal.records.first.coldFirst, isTrue);
    expect(journal.export().split('ОРБИТА — диагностика HTTPS API').length, 13);
  });

  test(
    'Предел памяти блокирует новые запросы без молчаливого удаления',
    () async {
      final record = (await controller.run(wifiConditions))!;
      while (!journal.full) {
        journal.add(record);
      }
      expect(await controller.run(wifiConditions), isNull);
      expect(probe.calls, 1);
      expect(journal.records.length, 100);
    },
  );

  test(
    'Экспорт не содержит сетевого handle или невалидной метки процесса',
    () async {
      final record = (await controller.run(wifiConditions))!;
      expect(record.export(), isNot(contains('networkId')));
      expect(record.export(), isNot(contains('sb_publishable_')));
      expect(record.export(), isNot(contains('Authorization')));
    },
  );
}
