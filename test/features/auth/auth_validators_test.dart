import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/domain/auth_validators.dart';

void main() {
  group('email', () {
    test('is required', () {
      expect(AuthValidators.email(''), 'Email is required.');
      expect(AuthValidators.email('   '), 'Email is required.');
      expect(AuthValidators.email(null), 'Email is required.');
    });

    test('rejects malformed addresses', () {
      for (final value in ['raven', 'raven@', '@example.com', 'a b@c.com']) {
        expect(
          AuthValidators.email(value),
          'Enter a valid email address.',
          reason: value,
        );
      }
    });

    test('accepts valid addresses, ignoring surrounding spaces', () {
      expect(AuthValidators.email(' raven@example.com '), isNull);
    });
  });

  group('passwords', () {
    test('sign-in password is only required', () {
      expect(AuthValidators.requiredPassword(''), 'Password is required.');
      expect(AuthValidators.requiredPassword('abc'), isNull);
    });

    test('new password enforces minimum length', () {
      expect(AuthValidators.newPassword(''), 'Password is required.');
      expect(
        AuthValidators.newPassword('1234567'),
        'Password must be at least 8 characters.',
      );
      expect(AuthValidators.newPassword('12345678'), isNull);
    });

    test('confirmation must match', () {
      final validate = AuthValidators.confirmPassword(() => 'nightshade');
      expect(validate(''), 'Please confirm your password.');
      expect(validate('nightshadE'), 'Passwords do not match.');
      expect(validate('nightshade'), isNull);
    });
  });
}
