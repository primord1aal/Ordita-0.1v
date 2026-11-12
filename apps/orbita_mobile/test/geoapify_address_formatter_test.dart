import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/maps/geoapify_address_formatter.dart';

void main() {
  test('Населённый пункт, улица и дом без административных частей', () {
    expect(
      formatGeoapifyAddress({
        'city': 'Чик',
        'street': 'Улица Павлика Морозова',
        'housenumber': '1',
        'state': 'NS',
        'country': 'Россия',
        'postcode': '632662',
        'formatted': 'Улица Павлика Морозова 1, Чик, NS, Россия, 632662',
      }),
      'Чик, улица Павлика Морозова, 1',
    );
  });

  test('Названия населённых пунктов из разных структурированных полей', () {
    for (final key in ['city', 'town', 'village', 'hamlet']) {
      expect(
        formatGeoapifyAddress({
          key: 'Учебный',
          'street': 'Речная',
          'housenumber': '12А/2',
        }),
        'Учебный, Речная, 12А/2',
      );
    }
    expect(formatGeoapifyAddress({'city': 'Чик', 'village': 'Учебный'}), 'Чик');
  });

  test('Неполный адрес показывает только известные компоненты', () {
    expect(
      formatGeoapifyAddress({'city': 'Чик', 'street': 'улица Учебная'}),
      'Чик, улица Учебная',
    );
    expect(formatGeoapifyAddress({'city': 'Чик'}), 'Чик');
    expect(
      formatGeoapifyAddress({'street': 'улица Учебная', 'housenumber': '4'}),
      'улица Учебная, 4',
    );
    expect(formatGeoapifyAddress({'city': 'Чик', 'housenumber': '4'}), 'Чик');
  });

  test('Пробелы убираются; собственное имя улицы сохраняет регистр', () {
    expect(
      formatGeoapifyAddress({
        'city': '  Чик\n ',
        'street': '  Улица   Павлика Морозова ',
        'housenumber': ' 1 ',
      }),
      'Чик, улица Павлика Морозова, 1',
    );
    expect(formatGeoapifyAddress({'street': 'Речная'}), 'Речная');
    expect(formatGeoapifyAddress({'street': '8 Марта'}), '8 Марта');
  });

  test('Без структурированных частей остаётся проверенная подпись сервиса', () {
    expect(
      formatGeoapifyAddress({
        'address_line1': 'Учебная площадь',
        'name': 'Учебный сквер',
        'formatted': 'Учебная площадь, NS, Россия, 632662',
      }),
      'Учебная площадь',
    );
    expect(
      formatGeoapifyAddress({
        'address_line1': ' ',
        'name': 'Учебный сквер',
        'formatted': 'Учебный сквер, NS, Россия, 632662',
      }),
      'Учебный сквер',
    );
    expect(
      formatGeoapifyAddress({
        'city': ' ',
        'street': null,
        'housenumber': 4,
        'formatted': '  Адрес выбранной точки  ',
      }),
      isNull,
    );
    expect(formatGeoapifyAddress({'state': 'NS', 'country': 'Россия'}), isNull);
  });

  test('Некорректные и слишком длинные подписи не становятся адресом', () {
    for (final value in [null, '', ' ', 123, [], 'x' * 501]) {
      expect(formatGeoapifyAddress({'formatted': value}), isNull);
    }
    expect(
      formatGeoapifyAddress({'city': 'x' * 300, 'street': 'x' * 300}),
      isNull,
    );
  });
}
