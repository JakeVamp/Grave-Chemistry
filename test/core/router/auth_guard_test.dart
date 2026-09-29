import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/core/router/auth_guard.dart';
import 'package:grave_chemistry/features/auth/domain/auth_status.dart';
import 'package:grave_chemistry/features/auth/domain/auth_user.dart';
import 'package:grave_chemistry/features/profile/application/profile_providers.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_moderation.dart';

void main() {
  const statuses = <AuthStatus>[
    SignedOut(),
    SignedIn(testUser),
    SignedIn(moderatorUser),
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
    AppRoutes.moderation,
    AppRoutes.photoReview,
    '/moderation/photos/abc',
    '/moderationx',
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

  group('moderator routes', () {
    const moderatorPaths = [
      AppRoutes.moderation,
      AppRoutes.photoReview,
      '/moderation/photos/abc',
    ];

    test('members who are not moderators are sent home', () {
      for (final path in moderatorPaths) {
        expect(
          authGuard(const SignedIn(testUser), OnboardingGate.ready, path),
          AppRoutes.home,
          reason: path,
        );
      }
      expect(
        authGuard(
          const SignedIn(
            AuthUser(id: 'u', email: null, role: 'child_safety_reviewer'),
          ),
          OnboardingGate.ready,
          AppRoutes.photoReview,
        ),
        AppRoutes.home,
        reason: 'the child-safety reviewer role is separate',
      );
    });

    test('moderators may open them once onboarded', () {
      for (final path in moderatorPaths) {
        expect(
          authGuard(const SignedIn(moderatorUser), OnboardingGate.ready, path),
          isNull,
          reason: path,
        );
      }
    });

    test('a look-alike path is not a moderator route', () {
      expect(AppRoutes.isModeratorRoute('/moderationx'), isFalse);
      expect(
        authGuard(
          const SignedIn(testUser),
          OnboardingGate.ready,
          '/moderationx',
        ),
        isNull,
      );
    });
  });

  group('moderators with unfinished member onboarding', () {
    const memberGates = [
      OnboardingGate.profileIncomplete,
      OnboardingGate.verificationRequired,
      OnboardingGate.verificationRetry,
      OnboardingGate.verificationPending,
    ];
    const moderatorPaths = [
      AppRoutes.moderation,
      AppRoutes.photoReview,
      '/moderation/photos/abc',
    ];
    const datingPaths = [
      AppRoutes.home,
      AppRoutes.discovery,
      AppRoutes.matches,
      AppRoutes.messages,
      AppRoutes.settings,
      AppRoutes.profilePhotos,
      AppRoutes.profileLoading,
      '/does-not-exist',
    ];

    test('1. a normal incomplete user is still pinned to onboarding, '
        'including away from moderator routes', () {
      for (final gate in memberGates) {
        final required = onboardingRouteFor(gate)!;
        for (final path in [...datingPaths, ...moderatorPaths]) {
          expect(
            authGuard(const SignedIn(testUser), gate, path),
            path == required ? isNull : required,
            reason: '$gate $path',
          );
        }
      }
    });

    test('2. an incomplete moderator lands on Moderator Home, and moderator '
        'routes stay open', () {
      for (final gate in memberGates) {
        for (final path in moderatorPaths) {
          expect(
            authGuard(const SignedIn(moderatorUser), gate, path),
            isNull,
            reason: '$gate $path',
          );
        }
        // Including right after sign-in, from the profile loading screen.
        for (final path in datingPaths) {
          expect(
            authGuard(const SignedIn(moderatorUser), gate, path),
            AppRoutes.moderation,
            reason: '$gate $path',
          );
        }
      }
    });

    test('5. moderator access opens no part of the dating app', () {
      for (final gate in memberGates) {
        for (final path in [
          AppRoutes.home,
          AppRoutes.discovery,
          AppRoutes.matches,
          AppRoutes.messages,
          AppRoutes.profilePhotos,
        ]) {
          expect(
            authGuard(const SignedIn(moderatorUser), gate, path),
            isNot(isNull),
            reason: '$gate $path',
          );
        }
      }
    });

    test('an incomplete moderator can still choose member setup, and moves '
        'on to the next step as usual', () {
      for (final gate in memberGates) {
        final required = onboardingRouteFor(gate)!;
        expect(
          authGuard(const SignedIn(moderatorUser), gate, required),
          isNull,
        );
      }
      // Profile saved: from profile setup on to verification.
      expect(
        authGuard(
          const SignedIn(moderatorUser),
          OnboardingGate.verificationRequired,
          AppRoutes.profileSetup,
        ),
        AppRoutes.verification,
      );
    });

    test('while the profile loads, moderator routes stay open and others '
        'wait on the loading screen', () {
      for (final gate in [OnboardingGate.loading, OnboardingGate.error]) {
        for (final path in moderatorPaths) {
          expect(authGuard(const SignedIn(moderatorUser), gate, path), isNull);
        }
        expect(
          authGuard(const SignedIn(moderatorUser), gate, AppRoutes.home),
          AppRoutes.profileLoading,
        );
      }
    });

    test('4. a role outside app_metadata grants nothing', () {
      const imposter = AuthUser(id: 'u', email: null);
      for (final gate in memberGates) {
        expect(
          authGuard(const SignedIn(imposter), gate, AppRoutes.moderation),
          onboardingRouteFor(gate),
        );
      }
    });
  });
}
