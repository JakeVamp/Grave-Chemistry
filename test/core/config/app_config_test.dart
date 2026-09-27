import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/core/config/app_config.dart';
import 'package:grave_chemistry/core/config/app_environment.dart';

String jwtWithRole(String role) {
  String encode(Map<String, Object> json) =>
      base64Url.encode(utf8.encode(jsonEncode(json))).replaceAll('=', '');
  return '${encode({'alg': 'HS256'})}.${encode({'role': role})}.signature';
}

void main() {
  AppConfig config({
    AppEnvironment environment = AppEnvironment.development,
    String url = 'https://example.supabase.co',
    String publishableKey = 'sb_publishable_test',
  }) {
    return AppConfig(
      environment: environment,
      supabaseUrl: url,
      supabasePublishableKey: publishableKey,
    );
  }

  group('AppConfig.validate', () {
    test('accepts a complete configuration', () {
      expect(config().validate(), isEmpty);
    });

    test('reports missing values', () {
      final errors = config(url: '', publishableKey: '').validate();
      expect(errors, hasLength(2));
    });

    test('rejects malformed URLs', () {
      expect(config(url: 'not a url').isValid, isFalse);
    });

    test('requires https in production', () {
      final prod = config(
        environment: AppEnvironment.production,
        url: 'http://example.supabase.co',
      );
      expect(prod.isValid, isFalse);
    });

    test('rejects new-style secret keys', () {
      expect(config(publishableKey: 'sb_secret_abc').isValid, isFalse);
    });

    test('rejects legacy service-role JWT keys', () {
      expect(
        config(publishableKey: jwtWithRole('service_role')).isValid,
        isFalse,
      );
    });

    test('accepts legacy anon JWT keys', () {
      expect(config(publishableKey: jwtWithRole('anon')).isValid, isTrue);
    });

    test('allows http for local development', () {
      expect(config(url: 'http://127.0.0.1:54321').isValid, isTrue);
    });
  });

  group('AppEnvironment.fromName', () {
    test('parses known names case-insensitively', () {
      expect(AppEnvironment.fromName('Production'), AppEnvironment.production);
    });

    test('falls back to development for unknown names', () {
      expect(AppEnvironment.fromName('unknown'), AppEnvironment.development);
    });
  });
}
