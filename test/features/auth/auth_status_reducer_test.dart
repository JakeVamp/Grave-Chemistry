import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/domain/auth_event.dart';
import 'package:grave_chemistry/features/auth/domain/auth_status.dart';
import 'package:grave_chemistry/features/auth/domain/auth_status_reducer.dart';

import '../../helpers/fake_auth_repository.dart';

void main() {
  AuthStatus reduce(
    AuthStatus current,
    AuthEventType type, [
    bool user = true,
  ]) {
    return reduceAuthStatus(current, AuthEvent(type, user ? testUser : null));
  }

  test('sign in and sign out', () {
    expect(
      reduce(const SignedOut(), AuthEventType.signedIn),
      const SignedIn(testUser),
    );
    expect(
      reduce(const SignedIn(testUser), AuthEventType.signedOut, false),
      const SignedOut(),
    );
  });

  test('restored session signs the user in', () {
    expect(
      reduce(const SignedOut(), AuthEventType.sessionRefreshed),
      const SignedIn(testUser),
    );
  });

  test('an event without a user is treated as signed out', () {
    expect(
      reduce(const SignedIn(testUser), AuthEventType.sessionRefreshed, false),
      const SignedOut(),
    );
  });

  test('password recovery is sticky until the password is updated', () {
    var status = reduce(const SignedOut(), AuthEventType.passwordRecovery);
    expect(status, const PasswordRecovery(testUser));

    status = reduce(status, AuthEventType.sessionRefreshed);
    expect(status, const PasswordRecovery(testUser));
    status = reduce(status, AuthEventType.signedIn);
    expect(status, const PasswordRecovery(testUser));

    status = reduce(status, AuthEventType.userUpdated);
    expect(status, const SignedIn(testUser));
  });

  test('signing out ends password recovery', () {
    expect(
      reduce(const PasswordRecovery(testUser), AuthEventType.signedOut, false),
      const SignedOut(),
    );
  });
}
