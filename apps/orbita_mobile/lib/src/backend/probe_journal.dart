import '../platform/network_observer.dart';
import 'api_probe.dart';

enum ProbeOperator {
  yota('Yota'),
  mts('МТС'),
  megafon('МегаФон'),
  beeline('Билайн'),
  t2('T2 / Tele2'),
  other('Другой оператор');

  const ProbeOperator(this.label);
  final String label;
}

enum ProbeDns {
  automatic('Автоматически'),
  disabled('Выключен'),
  custom('Задан вручную'),
  unknown('Не определено');

  const ProbeDns(this.label);
  final String label;
}

/// Только перечисления и флаги: свободный текст/ключи в журнал не принимаются.
class ProbeConditions {
  const ProbeConditions({
    required this.expectedNetwork,
    required this.dns,
    required this.window,
    required this.ownerConfirmed,
    this.operator,
    this.manualNetworkConfirmed = false,
  });
  final NetworkType expectedNetwork;
  final ProbeOperator? operator;
  final ProbeDns dns;
  final int window;
  final bool ownerConfirmed, manualNetworkConfirmed;
  bool get valid =>
      ownerConfirmed &&
      (expectedNetwork == NetworkType.wifi ||
          expectedNetwork == NetworkType.mobile) &&
      (expectedNetwork != NetworkType.mobile || operator != null) &&
      (window == 0 || window == 1 || window == 2);
  String get windowLabel =>
      window == 0 ? 'Без сети / восстановление' : 'Окно $window';
}

String diagnosticTime(DateTime time) {
  final offset = time.timeZoneOffset;
  final sign = offset.isNegative ? '-' : '+';
  final minutes = offset.inMinutes.abs();
  final zone =
      '$sign${(minutes ~/ 60).toString().padLeft(2, '0')}:${(minutes % 60).toString().padLeft(2, '0')}';
  return '${time.toIso8601String()} (UTC$zone)';
}

class ProbeRecord {
  const ProbeRecord({
    required this.result,
    required this.conditions,
    required this.before,
    required this.after,
    required this.startedAt,
    required this.expectedDomain,
    required this.requestDomain,
    required this.domainMatches,
    required this.requestAttempted,
  });
  final ProbeResult result;
  final ProbeConditions conditions;
  final NetworkSnapshot before, after;
  final DateTime startedAt;
  final String? expectedDomain, requestDomain;
  final bool domainMatches, requestAttempted;
  bool get networkStable =>
      before.knownTransport &&
      after.knownTransport &&
      before.type == after.type &&
      before.networkId != null &&
      before.networkId == after.networkId;
  bool get networkChanged =>
      before.type != after.type ||
      (before.networkId != null &&
          after.networkId != null &&
          before.networkId != after.networkId);
  bool get coldFirst =>
      requestAttempted && before.attempt == 1 && before.processSession != null;
  bool get withinLimit =>
      result.success && result.elapsed <= const Duration(seconds: 3);
  bool get environmentConflict =>
      before.vpn == true ||
      after.vpn == true ||
      before.proxy == true ||
      after.proxy == true;
  String get domainLabel => domainMatches
      ? 'Домен соответствует конфигурации'
      : 'Домен не соответствует конфигурации';
  String get networkEvidence => environmentConflict
      ? 'Android обнаружил VPN или прокси. Условия испытания не подтверждены.'
      : networkChanged
      ? 'Сеть изменилась или её снимок недоступен. Не засчитывать автоматически.'
      : networkStable
      ? 'Снимки активной сети Android до и после совпали.'
      : 'Тип сети не подтверждён Android; требуется ручная проверка.';

  String _flag(bool? value) => value == null
      ? 'Не определено'
      : value
      ? 'Обнаружен'
      : 'Не обнаружен';

  String export() => [
    'ОРБИТА — диагностика HTTPS API',
    'Начало: ${diagnosticTime(startedAt)}',
    'Окончание: ${diagnosticTime(result.checkedAt)}',
    'Окно испытания (владелец): ${conditions.windowLabel}',
    'Ожидаемая сеть (владелец): ${conditions.expectedNetwork.label}',
    'Активная сеть Android до: ${before.type.label}',
    'Активная сеть Android после: ${after.type.label}',
    'Свидетельство сети: $networkEvidence',
    'Ручное подтверждение неопределённой сети: ${conditions.manualNetworkConfirmed ? 'Да' : 'Нет'}',
    'Оператор (владелец): ${conditions.expectedNetwork == NetworkType.mobile ? conditions.operator?.label ?? 'Не указан' : 'Не применимо'}',
    'Частный DNS (владелец): ${conditions.dns.label}',
    'VPN (владелец): ${conditions.ownerConfirmed ? 'Выключен' : 'Не подтверждено'}',
    'Прокси (владелец): ${conditions.ownerConfirmed ? 'Выключен' : 'Не подтверждено'}',
    'VPN Android до/после: ${_flag(before.vpn)} / ${_flag(after.vpn)}',
    'Системный прокси Android до/после: ${_flag(before.proxy)} / ${_flag(after.proxy)}',
    'Домен запроса: ${requestDomain ?? 'Не определено'}',
    'Ожидаемый домен: ${expectedDomain ?? 'Не определено'}',
    domainLabel,
    'Сверка означает согласованность конфигурации, не независимое доказательство принадлежности проекта.',
    'HTTP: ${result.httpStatus ?? 'Код не получен'}',
    'Время ответа: ${result.elapsedMilliseconds} мс',
    'HTTP-запрос начат: ${requestAttempted ? 'Да' : 'Нет'}',
    'Результат: ${result.message}',
    'Порог ответа 3000 мс: ${withinLimit ? 'Соблюдён' : 'Не соблюдён или нет успешного ответа'}',
    'Метка процесса Android: ${_safeSession(before.processSession)}',
    'Номер попытки процесса: ${before.attempt}',
    'Первый запрос процесса: ${coldFirst ? 'Да' : 'Нет'}',
  ].join('\n');

  String _safeSession(String? value) =>
      value != null &&
          RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$',
          ).hasMatch(value)
      ? value
      : 'Не определено';
}

/// Живёт в OrbitaApp, не на диске. Холодный запуск очищает всю серию.
class ProbeJournal {
  final List<ProbeRecord> _records = [];
  List<ProbeRecord> get records => List.unmodifiable(_records);
  bool get full => _records.length >= 100;
  void add(ProbeRecord record) {
    if (full) throw StateError('Скопируйте серию перед очисткой журнала.');
    _records.add(record);
  }

  void clear() => _records.clear();
  String export() =>
      _records.map((record) => record.export()).join('\n\n---\n\n');
}
