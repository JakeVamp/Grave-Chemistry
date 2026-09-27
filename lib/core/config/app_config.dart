import 'dart:convert';

import 'app_environment.dart';

/// Runtime configuration supplied at build time via
/// `--dart-define-from-file=env/<name>.json`.
///
/// Only values that are safe to ship inside a client binary belong here.
/// The Supabase publishable (or legacy anon) key is designed to be public;
/// access is enforced by Row Level Security. Secret / service-role keys must
/// NEVER be supplied to the app, and [validate] rejects them.
class AppConfig {
  const AppConfig({
    required this.environment,
    required this.supabaseUrl,
    required this.supabasePublishableKey,
  });

  factory AppConfig.fromEnvironment() {
    return AppConfig(
      environment: AppEnvironment.fromName(
        const String.fromEnvironment('APP_ENV', defaultValue: 'development'),
      ),
      supabaseUrl: const String.fromEnvironment('SUPABASE_URL'),
      supabasePublishableKey: const String.fromEnvironment(
        'SUPABASE_PUBLISHABLE_KEY',
      ),
    );
  }

  final AppEnvironment environment;
  final String supabaseUrl;
  final String supabasePublishableKey;

  /// Human-readable problems with this configuration; empty when valid.
  List<String> validate() {
    final errors = <String>[];

    final uri = Uri.tryParse(supabaseUrl);
    if (supabaseUrl.isEmpty) {
      errors.add('SUPABASE_URL is not set.');
    } else if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      errors.add('SUPABASE_URL is not a valid URL.');
    } else if (environment == AppEnvironment.production &&
        uri.scheme != 'https') {
      errors.add('SUPABASE_URL must use https in production.');
    }

    if (supabasePublishableKey.isEmpty) {
      errors.add('SUPABASE_PUBLISHABLE_KEY is not set.');
    } else if (_isPrivilegedKey(supabasePublishableKey)) {
      errors.add(
        'SUPABASE_PUBLISHABLE_KEY is a secret/service-role key. '
        'Use the publishable (anon) key instead.',
      );
    }

    return errors;
  }

  bool get isValid => validate().isEmpty;

  /// Detects new-style secret keys and legacy JWT keys with the
  /// `service_role` claim.
  static bool _isPrivilegedKey(String key) {
    if (key.startsWith('sb_secret_')) return true;

    final parts = key.split('.');
    if (parts.length != 3) return false;
    try {
      final payload = utf8.decode(
        base64Url.decode(base64Url.normalize(parts[1])),
      );
      final claims = jsonDecode(payload);
      return claims is Map && claims['role'] == 'service_role';
    } on FormatException {
      return false;
    }
  }
}
