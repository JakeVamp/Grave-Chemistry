import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/core/router/auth_guard.dart';
import 'package:grave_chemistry/features/auth/domain/auth_status.dart';

import '../../helpers/fake_auth_repository.dart';

void main() {
  const statuses = <AuthStatus>[
    SignedOut(),
    SignedIn(testUser),
    PasswordRecovery(testUser),
  ];

  const paths = [
    AppRoutes.home,
    AppRoutes.auth,
    AppRoutes.signUp,
    AppRoutes.forgotPassword,
    AppRoutes.checkEmail,
    AppRoutes.resetPassword,
    AppRoutes.profileSetup,
    AppRoutes.discovery,
    AppRoutes.matches,
    AppRoutes.messages,
    AppRoutes.settings,
    '/does-not-exist',
    '/authentic', // looks like /auth but isn't an auth route
  ];

  test('no status/path combination can produce a redirect loop', () {
    for (final status in statuses) {
      for (final path in paths) {
        final target = authGuard(status, path);
        if (target != null) {
          expect(
            authGuard(status, target),
            isNull,
            reason: '$status: $path -> $target redirects again',
          );
        }
      }
    }
  });

  test('signed-out users can only reach auth screens', () {
    expect(authGuard(const SignedOut(), AppRoutes.auth), isNull);
    expect(authGuard(const SignedOut(), AppRoutes.signUp), isNull);
    expect(authGuard(const SignedOut(), AppRoutes.checkEmail), isNull);
    expect(authGuard(const SignedOut(), AppRoutes.home), AppRoutes.auth);
    expect(authGuard(const SignedOut(), AppRoutes.settings), AppRoutes.auth);
    expect(
      authGuard(const SignedOut(), AppRoutes.resetPassword),
      AppRoutes.auth,
    );
    expect(authGuard(const SignedOut(), '/authentic'), AppRoutes.auth);
  });

  test('signed-in users are kept out of auth screens', () {
    const status = SignedIn(testUser);
    expect(authGuard(status, AppRoutes.home), isNull);
    expect(authGuard(status, AppRoutes.settings), isNull);
    expect(authGuard(status, AppRoutes.auth), AppRoutes.home);
    expect(authGuard(status, AppRoutes.signUp), AppRoutes.home);
    expect(authGuard(status, AppRoutes.resetPassword), AppRoutes.home);
  });

  test('password recovery pins the user to the reset screen', () {
    const status = PasswordRecovery(testUser);
    expect(authGuard(status, AppRoutes.resetPassword), isNull);
    for (final path in paths.where((p) => p != AppRoutes.resetPassword)) {
      expect(authGuard(status, path), AppRoutes.resetPassword, reason: path);
    }
  });
}
