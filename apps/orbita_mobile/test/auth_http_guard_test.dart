import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:orbita_mobile/src/auth/auth_repository.dart';
import 'package:orbita_mobile/src/auth/bounded_http_client.dart';

void main() {
  test('Auth-транспорт блокирует другой хост, HTTP, порт, userinfo и чужой API до сети', () async {
    final client = BoundedAuthHttpClient('aaaaaaaaaaaaaaaaaaaa.supabase.co');
    addTearDown(client.close);
    for (final value in [
      'https://bbbbbbbbbbbbbbbbbbbb.supabase.co/auth/v1/token',
      'http://aaaaaaaaaaaaaaaaaaaa.supabase.co/auth/v1/token',
      'https://aaaaaaaaaaaaaaaaaaaa.supabase.co:444/auth/v1/token',
      'https://user@aaaaaaaaaaaaaaaaaaaa.supabase.co/auth/v1/token',
      'https://aaaaaaaaaaaaaaaaaaaa.supabase.co/functions/v1/unapproved',
    ]) {
      await expectLater(
        client.send(http.Request('POST', Uri.parse(value))),
        throwsA(
          isA<AuthFailure>().having(
            (e) => e.kind,
            'kind',
            AuthFailureKind.unverified,
          ),
        ),
      );
      expect(client.lastFailure!.kind, AuthFailureKind.unverified);
    }
  });
}
