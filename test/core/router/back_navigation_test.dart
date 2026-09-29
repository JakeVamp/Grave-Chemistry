import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/core/router/auth_guard.dart';
import 'package:grave_chemistry/core/router/back_navigation.dart';
import 'package:grave_chemistry/features/auth/domain/auth_status.dart';
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
    AppRoutes.profilePhotos,
    AppRoutes.moderation,
    AppRoutes.photoReview,
    '/moderation/photos/abc',
    '/does-not-exist',
  ];
  const member = SignedIn(testUser);
  const moderator = SignedIn(moderatorUser);
  const ready = OnboardingGate.ready;
  const memberGates = [
    OnboardingGate.profileIncomplete,
    OnboardingGate.verificationRequired,
    OnboardingGate.verificationRetry,
    OnboardingGate.verificationPending,
  ];

  test('6+7. Back only ever leads somewhere the router allows: it never '
      'skips a gate and never starts a redirect loop', () {
    for (final status in statuses) {
      for (final gate in OnboardingGate.values) {
        for (final path in paths) {
          final target = backTargetFor(status, gate, path);
          if (target == null) continue;
          expect(target, isNot(path), reason: '$status/$gate $path');
          expect(
            authGuard(status, gate, target),
            isNull,
            reason: '$status/$gate: Back from $path to $target is redirected',
          );
        }
      }
    }
  });

  test('1+2. nested screens go back to their parent', () {
    final expected = {
      AppRoutes.discovery: AppRoutes.home,
      AppRoutes.matches: AppRoutes.home,
      AppRoutes.messages: AppRoutes.home,
      AppRoutes.settings: AppRoutes.home,
      AppRoutes.profilePhotos: AppRoutes.home,
      '/does-not-exist': AppRoutes.home,
    };
    for (final MapEntry(key: path, value: parent) in expected.entries) {
      expect(backTargetFor(member, ready, path), parent, reason: path);
    }
    for (final path in [
      AppRoutes.signUp,
      AppRoutes.forgotPassword,
      AppRoutes.checkEmail,
    ]) {
      expect(
        backTargetFor(const SignedOut(), ready, path),
        AppRoutes.auth,
        reason: path,
      );
    }
  });

  test('3+4. moderator screens go back up the moderator hierarchy', () {
    expect(
      backTargetFor(moderator, ready, '/moderation/photos/abc'),
      AppRoutes.photoReview,
    );
    expect(
      backTargetFor(moderator, ready, AppRoutes.photoReview),
      AppRoutes.moderation,
    );
    expect(
      backTargetFor(moderator, ready, AppRoutes.moderation),
      AppRoutes.home,
    );
  });

  test('root screens have no Back', () {
    expect(backTargetFor(member, ready, AppRoutes.home), isNull);
    expect(backTargetFor(const SignedOut(), ready, AppRoutes.auth), isNull);
    expect(
      backTargetFor(
        const PasswordRecovery(testUser),
        ready,
        AppRoutes.resetPassword,
      ),
      isNull,
    );
    for (final gate in [OnboardingGate.loading, OnboardingGate.error]) {
      expect(backTargetFor(member, gate, AppRoutes.profileLoading), isNull);
    }
  });

  test('6. members in onboarding get no Back out of it', () {
    for (final gate in memberGates) {
      final route = onboardingRouteFor(gate)!;
      expect(backTargetFor(member, gate, route), isNull, reason: '$gate');
    }
  });

  test('moderators in member setup can go back to Moderator Home, which is '
      'then their root', () {
    for (final gate in memberGates) {
      final route = onboardingRouteFor(gate)!;
      expect(backTargetFor(moderator, gate, route), AppRoutes.moderation);
      expect(backTargetFor(moderator, gate, AppRoutes.moderation), isNull);
      expect(
        backTargetFor(moderator, gate, AppRoutes.photoReview),
        AppRoutes.moderation,
      );
    }
  });

  test('non-moderators get no Back into moderator screens', () {
    expect(backTargetFor(member, ready, '/moderation/photos/abc'), isNull);
    expect(backTargetFor(member, ready, AppRoutes.photoReview), isNull);
  });
}
