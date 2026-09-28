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
    AppRoutes.verification,
    AppRoutes.verificationRetry,
    AppRoutes.verificationPending,
    AppRoutes.discovery,
    AppRoutes.matches,
    AppRoutes.messages,
    AppRoutes.settings,
    '/does-not-exist',
    '/authentic', // looks like /auth but isn't an auth route
  ];

  test('no auth/onboarding/path combination can produce a redirect loop', () {
    for (final status in statuses) {
      for (final gate in OnboardingGate.values) {
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

  test('signed-out users can only reach auth screens', () {
    for (final gate in OnboardingGate.values) {
      for (final path in paths) {
        expect(
          authGuard(const SignedOut(), gate, path),
          AppRoutes.isAuthRoute(path) ? isNull : AppRoutes.auth,
          reason: '$gate $path',
        );
      }
    }
  });

  group('signed in', () {
    const status = SignedIn(testUser);

    void expectPinnedTo(OnboardingGate gate, String route) {
      for (final path in paths) {
        expect(
          authGuard(status, gate, path),
          path == route ? isNull : route,
          reason: '$gate $path',
        );
      }
    }

    test('loading or failed profile: loading screen only', () {
      expectPinnedTo(OnboardingGate.loading, AppRoutes.profileLoading);
      expectPinnedTo(OnboardingGate.error, AppRoutes.profileLoading);
    });

    test('incomplete profile: profile setup only', () {
      expectPinnedTo(OnboardingGate.profileIncomplete, AppRoutes.profileSetup);
    });

    test('complete profile without verification: verification only', () {
      expectPinnedTo(
        OnboardingGate.verificationRequired,
        AppRoutes.verification,
      );
    });

    test('pending verification: pending screen only, not the app', () {
      expectPinnedTo(
        OnboardingGate.verificationPending,
        AppRoutes.verificationPending,
      );
      expect(
        authGuard(status, OnboardingGate.verificationPending, AppRoutes.home),
        AppRoutes.verificationPending,
      );
    });

    test('rejected, expired or revoked: retry screen only', () {
      expectPinnedTo(
        OnboardingGate.verificationRetry,
        AppRoutes.verificationRetry,
      );
    });

    test('verified: the app, not the onboarding screens', () {
      const gate = OnboardingGate.ready;
      for (final path in [
        AppRoutes.home,
        AppRoutes.settings,
        AppRoutes.discovery,
      ]) {
        expect(authGuard(status, gate, path), isNull, reason: path);
      }
      for (final path in [
        AppRoutes.auth,
        AppRoutes.signUp,
        AppRoutes.resetPassword,
        AppRoutes.profileSetup,
        AppRoutes.profileLoading,
        AppRoutes.verification,
        AppRoutes.verificationRetry,
        AppRoutes.verificationPending,
      ]) {
        expect(authGuard(status, gate, path), AppRoutes.home, reason: path);
      }
    });
  });

  test('password recovery pins the user to the reset screen', () {
    const status = PasswordRecovery(testUser);
    for (final gate in OnboardingGate.values) {
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
