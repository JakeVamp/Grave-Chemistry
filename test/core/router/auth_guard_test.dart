import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/core/router/auth_guard.dart';
import 'package:grave_chemistry/features/auth/domain/auth_status.dart';
import 'package:grave_chemistry/features/profile/application/profile_providers.dart';

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
    AppRoutes.profileLoading,
    AppRoutes.discovery,
    AppRoutes.matches,
    AppRoutes.messages,
    AppRoutes.settings,
    '/does-not-exist',
    '/authentic', // looks like /auth but isn't an auth route
  ];

  test('no auth/profile/path combination can produce a redirect loop', () {
    for (final status in statuses) {
      for (final gate in ProfileGate.values) {
        for (final path in paths) {
          final target = authGuard(status, gate, path);
          if (target != null) {
            expect(
              authGuard(status, gate, target),
              isNull,
              reason: '$status/$gate: $path -> $target redirects again',
            );
          }
        }
      }
    }
  });

  test(
    'signed-out users can only reach auth screens, whatever the profile',
    () {
      for (final gate in ProfileGate.values) {
        expect(authGuard(const SignedOut(), gate, AppRoutes.auth), isNull);
        expect(authGuard(const SignedOut(), gate, AppRoutes.signUp), isNull);
        expect(
          authGuard(const SignedOut(), gate, AppRoutes.home),
          AppRoutes.auth,
        );
        expect(
          authGuard(const SignedOut(), gate, AppRoutes.profileSetup),
          AppRoutes.auth,
        );
        expect(
          authGuard(const SignedOut(), gate, '/authentic'),
          AppRoutes.auth,
        );
      }
    },
  );

  group('signed in', () {
    const status = SignedIn(testUser);

    test('without a completed profile: only profile setup', () {
      for (final path in paths) {
        expect(
          authGuard(status, ProfileGate.incomplete, path),
          path == AppRoutes.profileSetup ? isNull : AppRoutes.profileSetup,
          reason: path,
        );
      }
    });

    test('while the profile loads or fails: only the loading screen', () {
      for (final gate in [ProfileGate.loading, ProfileGate.error]) {
        for (final path in paths) {
          expect(
            authGuard(status, gate, path),
            path == AppRoutes.profileLoading
                ? isNull
                : AppRoutes.profileLoading,
            reason: '$gate $path',
          );
        }
      }
    });

    test('with a completed profile: the app, not the gating screens', () {
      const gate = ProfileGate.complete;
      expect(authGuard(status, gate, AppRoutes.home), isNull);
      expect(authGuard(status, gate, AppRoutes.settings), isNull);
      expect(authGuard(status, gate, AppRoutes.discovery), isNull);
      for (final path in [
        AppRoutes.auth,
        AppRoutes.signUp,
        AppRoutes.resetPassword,
        AppRoutes.profileSetup,
        AppRoutes.profileLoading,
      ]) {
        expect(authGuard(status, gate, path), AppRoutes.home, reason: path);
      }
    });
  });

  test('password recovery pins the user to the reset screen', () {
    const status = PasswordRecovery(testUser);
    for (final gate in ProfileGate.values) {
      for (final path in paths) {
        expect(
          authGuard(status, gate, path),
          path == AppRoutes.resetPassword ? isNull : AppRoutes.resetPassword,
          reason: '$gate $path',
        );
      }
    }
  });
}
