import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile/application/profile_providers.dart';
import 'package:grave_chemistry/features/profile/domain/profile.dart';
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';

import '../../helpers/fake_profile_repository.dart';

void main() {
  group('verified badge', () {
    test('only an approved verification shows the badge', () {
      for (final status in VerificationStatus.values) {
        expect(
          status.showsVerifiedBadge,
          status == VerificationStatus.verified,
          reason: status.name,
        );
      }
    });

    test('pending, rejected and reverification_required never show it', () {
      expect(VerificationStatus.pending.showsVerifiedBadge, isFalse);
      expect(VerificationStatus.rejected.showsVerifiedBadge, isFalse);
      expect(
        VerificationStatus.reverificationRequired.showsVerifiedBadge,
        isFalse,
      );
    });
  });

  test('who may start a new verification session', () {
    expect(VerificationStatus.notStarted.canStartVerification, isTrue);
    expect(VerificationStatus.rejected.canStartVerification, isTrue);
    expect(VerificationStatus.expired.canStartVerification, isTrue);
    expect(
      VerificationStatus.reverificationRequired.canStartVerification,
      isTrue,
    );
    expect(VerificationStatus.pending.canStartVerification, isFalse);
    expect(VerificationStatus.verified.canStartVerification, isFalse);
  });

  test('codes match the database', () {
    expect(VerificationStatus.values.map((s) => s.code), [
      'not_started',
      'pending',
      'verified',
      'rejected',
      'expired',
      'reverification_required',
    ]);
    expect(VerificationStatus.fromCode('added_later'), isNull);
  });

  group('onboarding gate', () {
    test('profile completion comes first', () {
      expect(onboardingGateFor(null), OnboardingGate.profileIncomplete);
      expect(
        onboardingGateFor(
          const Profile(
            id: 'u',
            isCompleted: false,
            verificationStatus: VerificationStatus.verified,
          ),
        ),
        OnboardingGate.profileIncomplete,
      );
    });

    test('complete profile maps each verification status', () {
      const expected = {
        VerificationStatus.notStarted: OnboardingGate.verificationRequired,
        VerificationStatus.pending: OnboardingGate.verificationPending,
        VerificationStatus.verified: OnboardingGate.ready,
        VerificationStatus.rejected: OnboardingGate.verificationRetry,
        VerificationStatus.expired: OnboardingGate.verificationRetry,
        VerificationStatus.reverificationRequired:
            OnboardingGate.verificationRetry,
      };
      for (final MapEntry(key: status, value: gate) in expected.entries) {
        expect(
          onboardingGateFor(completedProfileWith(status)),
          gate,
          reason: status.name,
        );
      }
    });

    test('pending is never treated as ready', () {
      expect(
        onboardingGateFor(completedProfileWith(VerificationStatus.pending)),
        isNot(OnboardingGate.ready),
      );
    });

    test('an unknown status from a newer server is not ready', () {
      expect(
        onboardingGateFor(
          const Profile(id: 'u', isCompleted: true, verificationStatus: null),
        ),
        OnboardingGate.verificationRequired,
      );
    });
  });
}
