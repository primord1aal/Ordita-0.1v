import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:orbita_mobile/src/backend/test_backend_configuration.dart';

// Только искусственные идентификаторы. Ни одного настоящего проекта.
const fixtureRef = 'aaaaaaaaaaaaaaaaaaaa';
const forbiddenFixtureRef = 'bbbbbbbbbbbbbbbbbbbb';
const fixtureKey = 'sb_publishable_artificial_fixture_not_a_real_key';
const fixtureConfig = TestBackendConfiguration(
  url: 'https://$fixtureRef.supabase.co',
  publishableKey: fixtureKey,
  projectRef: fixtureRef,
);

void main() {
  test('Разрешён точный HTTPS-домен утверждённого проекта', () {
    expect(fixtureConfig.error, isNull);
    expect(
      fixtureConfig.healthUri.toString(),
      'https://$fixtureRef.supabase.co/auth/v1/health',
    );
    expect(
      fixtureConfig.buildError(forbiddenProjectRef: forbiddenFixtureRef),
      isNull,
    );
  });

  final badUrls = [
    '',
    'http://$fixtureRef.supabase.co',
    'https://$forbiddenFixtureRef.supabase.co',
    'https://$fixtureRef.supabase.co.evil.invalid',
    'https://user@$fixtureRef.supabase.co',
    'https://$fixtureRef.supabase.co:443',
    'https://$fixtureRef.supabase.co/path',
    'https://$fixtureRef.supabase.co?apikey=fixture',
    'https://$fixtureRef.supabase.co#fragment',
    ' https://$fixtureRef.supabase.co',
  ];
  for (var i = 0; i < badUrls.length; i++) {
    test('Неверный или подменённый URL отклонён: вариант $i', () {
      final config = TestBackendConfiguration(
        url: badUrls[i],
        publishableKey: fixtureKey,
        projectRef: fixtureRef,
      );
      expect(config.isValid, isFalse);
      expect(() => config.healthUri, throwsStateError);
    });
  }

  test('Обязательны ключ, разрешённый и запрещённый идентификаторы', () {
    expect(
      const TestBackendConfiguration(
        url: 'https://$fixtureRef.supabase.co',
        publishableKey: '',
        projectRef: fixtureRef,
      ).isValid,
      isFalse,
    );
    expect(
      const TestBackendConfiguration(
        url: 'https://$fixtureRef.supabase.co',
        publishableKey: fixtureKey,
        projectRef: '',
      ).isValid,
      isFalse,
    );
    expect(fixtureConfig.buildError(forbiddenProjectRef: ''), isNotNull);
    expect(
      fixtureConfig.buildError(forbiddenProjectRef: fixtureRef),
      isNotNull,
    );
  });

  for (final (index, key) in [
    'sb_secret_artificial_fixture_not_a_real_key',
    'service_role',
    'eyJfixture.not_a_valid.jwt',
    'sb_publishable_fixture\r\nInjected: value',
  ].indexed) {
    test('Неподходящий ключ не попадёт в подключённую сборку: $index', () {
      final config = TestBackendConfiguration(
        url: 'https://$fixtureRef.supabase.co',
        publishableKey: key,
        projectRef: fixtureRef,
      );
      expect(config.isValid, isFalse);
      expect(config.error, isNot(contains(key)));
    });
  }

  test('В клиентский JSON не входит запрещённый проект', () {
    expect(fixtureConfig.clientDefines.length, 3);
    expect(
      fixtureConfig.clientDefines.containsKey('SUPABASE_FORBIDDEN_PROJECT_REF'),
      isFalse,
    );
    expect(
      jsonEncode(fixtureConfig.clientDefines),
      isNot(contains(forbiddenFixtureRef)),
    );
  });
}
