import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/data/auth_error_mapper.dart';
import 'package:grave_chemistry/features/auth/domain/auth_failure.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  AuthFailureType typeOf(Object error) => mapAuthError(error).type;

  test('maps known Supabase error codes', () {
    expect(
      typeOf(const AuthException('x', code: 'invalid_credentials')),
      AuthFailureType.invalidCredentials,
    );
    expect(
      typeOf(const AuthException('x', code: 'email_not_confirmed')),
      AuthFailureType.emailNotConfirmed,
    );
    expect(
      typeOf(const AuthException('x', code: 'user_already_exists')),
      AuthFailureType.emailAlreadyRegistered,
    );
    expect(
      typeOf(const AuthException('x', code: 'same_password')),
      AuthFailureType.samePassword,
    );
    expect(
      typeOf(const AuthException('x', code: 'over_email_send_rate_limit')),
      AuthFailureType.rateLimited,
    );
    expect(
      typeOf(const AuthException('x', statusCode: '429')),
      AuthFailureType.rateLimited,
    );
  });

  test('maps email-link errors from a redirect URL', () {
    // getSessionFromUrl puts error_code in statusCode, error in code.
    expect(
      typeOf(
        const AuthException(
          'Email link is invalid or has expired',
          code: 'access_denied',
          statusCode: 'otp_expired',
        ),
      ),
      AuthFailureType.linkExpired,
    );
    expect(
      typeOf(
        const AuthException(
          'Code verifier could not be found in local storage.',
        ),
      ),
      AuthFailureType.linkInvalid,
    );
  });

  test('maps network failures', () {
    expect(
      typeOf(AuthRetryableFetchException(message: 'offline')),
      AuthFailureType.network,
    );
    expect(typeOf(TimeoutException('slow')), AuthFailureType.network);
  });

  test('never exposes raw server messages', () {
    final failure = mapAuthError(
      const AuthException('internal: db connection refused', code: 'weird'),
    );
    expect(failure.type, AuthFailureType.unknown);
    expect(failure.message, isNot(contains('db connection')));
  });

  test('passes AuthFailure through unchanged', () {
    const failure = AuthFailure(AuthFailureType.network, 'm');
    expect(mapAuthError(failure), same(failure));
  });
}
