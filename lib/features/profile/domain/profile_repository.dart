import 'profile.dart';
import 'profile_draft.dart';

/// Access to the signed-in user's own profile. All methods throw
/// `ProfileFailure` on error.
abstract interface class ProfileRepository {
  /// The current user's profile, or null if they haven't created one.
  Future<Profile?> fetchMyProfile();

  /// Creates or updates the current user's profile from [draft] and returns
  /// the saved profile, including the server-computed completion flag.
  Future<Profile> saveMyProfile(ProfileDraft draft);
}
