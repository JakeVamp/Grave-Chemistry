import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/auth_status.dart';
import '../data/supabase_profile_repository.dart';
import '../domain/profile.dart';
import '../domain/profile_draft.dart';
import '../domain/profile_failure.dart';
import '../domain/profile_repository.dart';
import '../domain/verification_status.dart';

final profileRepositoryProvider = Provider<ProfileRepository>(
  (ref) => SupabaseProfileRepository(ref.watch(supabaseClientProvider)),
);

/// The signed-in user's profile: null when signed out or not yet created.
/// Reloads automatically when a different user signs in.
final profileControllerProvider =
    AsyncNotifierProvider<ProfileController, Profile?>(
      ProfileController.new,
      // Failures surface to the user with a Retry button instead of silent
      // background retries.
      retry: (retryCount, error) => null,
    );

/// Where a signed-in user is in onboarding, which decides where the router
/// sends them. Profile completion, verification submission and verification
/// approval are separate steps.
enum OnboardingGate {
  loading,
  error,
  profileIncomplete,

  /// Profile done; no verification photo submitted yet.
  verificationRequired,

  /// Photo submitted and waiting for review. Limited access only.
  verificationPending,

  /// Rejected, expired or revoked: the user must verify again.
  verificationRetry,

  /// Profile complete and verification approved.
  ready,
}

final onboardingGateProvider = Provider<OnboardingGate>((ref) {
  final profile = ref.watch(profileControllerProvider);
  if (profile.isLoading) return OnboardingGate.loading;
  if (profile.hasError) return OnboardingGate.error;
  return onboardingGateFor(profile.value);
});

OnboardingGate onboardingGateFor(Profile? profile) {
  if (profile == null || !profile.isCompleted) {
    return OnboardingGate.profileIncomplete;
  }
  return switch (profile.verificationStatus) {
    VerificationStatus.verified => OnboardingGate.ready,
    VerificationStatus.pending => OnboardingGate.verificationPending,
    VerificationStatus.rejected ||
    VerificationStatus.expired ||
    VerificationStatus.reverificationRequired =>
      OnboardingGate.verificationRetry,
    VerificationStatus.notStarted ||
    null => OnboardingGate.verificationRequired,
  };
}

class ProfileController extends AsyncNotifier<Profile?> {
  @override
  Future<Profile?> build() async {
    final userId = ref.watch(
      authControllerProvider.select(
        (status) => status is SignedIn ? status.user.id : null,
      ),
    );
    if (userId == null) return null;
    return ref.watch(profileRepositoryProvider).fetchMyProfile();
  }

  /// Fetches the profile again, e.g. after a failed load. Shows the loading
  /// screen while it runs.
  void reload() => ref.invalidateSelf();

  /// Fetches the latest profile in the background, keeping the current one
  /// on screen. Errors are ignored; the current state stays.
  Future<void> refresh() async {
    try {
      final profile = await ref
          .read(profileRepositoryProvider)
          .fetchMyProfile();
      if (ref.mounted) state = AsyncData(profile);
    } on ProfileFailure {
      // Keep showing what we have; the user can try again.
    }
  }

  /// Saves [draft] and publishes the saved profile. Throws `ProfileFailure`.
  Future<Profile> save(ProfileDraft draft) async {
    final profile = await ref
        .read(profileRepositoryProvider)
        .saveMyProfile(draft);
    state = AsyncData(profile);
    return profile;
  }
}
