import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../auth/application/auth_providers.dart';
import '../../auth/domain/auth_status.dart';
import '../data/supabase_profile_repository.dart';
import '../domain/profile.dart';
import '../domain/profile_draft.dart';
import '../domain/profile_repository.dart';

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

/// Where the router should send a signed-in user, based on their profile.
enum ProfileGate { loading, error, incomplete, complete }

final profileGateProvider = Provider<ProfileGate>((ref) {
  final profile = ref.watch(profileControllerProvider);
  if (profile.isLoading) return ProfileGate.loading;
  if (profile.hasError) return ProfileGate.error;
  return profile.value?.isCompleted ?? false
      ? ProfileGate.complete
      : ProfileGate.incomplete;
});

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

  /// Fetches the profile again, e.g. after a failed load.
  void reload() => ref.invalidateSelf();

  /// Saves [draft] and publishes the saved profile. Throws `ProfileFailure`.
  Future<Profile> save(ProfileDraft draft) async {
    final profile = await ref
        .read(profileRepositoryProvider)
        .saveMyProfile(draft);
    state = AsyncData(profile);
    return profile;
  }
}
