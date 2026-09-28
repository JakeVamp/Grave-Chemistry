import 'profile_draft.dart';
import 'profile_validators.dart';

enum ProfileField {
  displayName,
  birthDate,
  city,
  region,
  bio,
  gender,
  genderSelfDescription,
  communityIdentity,
  datingPreference,
}

/// Client-side completion rules, used to validate before saving. The
/// database's `profile_completed` column, computed by a trigger with the
/// same rules, is the source of truth.
abstract final class ProfileCompletion {
  /// Validation errors by field; empty when the draft is complete.
  static Map<ProfileField, String> errors(
    ProfileDraft draft, {
    required DateTime today,
  }) {
    final d = draft.normalized();
    final results = <ProfileField, String?>{
      ProfileField.displayName: ProfileValidators.displayName(d.displayName),
      ProfileField.birthDate: ProfileValidators.birthDate(
        d.birthDate,
        today: today,
      ),
      ProfileField.city: ProfileValidators.city(d.city),
      ProfileField.region: ProfileValidators.region(d.region),
      ProfileField.bio: ProfileValidators.bio(d.bio),
      ProfileField.gender: ProfileValidators.gender(d.gender),
      ProfileField.genderSelfDescription:
          ProfileValidators.genderSelfDescription(
            d.genderSelfDescription,
            d.gender,
          ),
      ProfileField.communityIdentity: ProfileValidators.communityIdentity(
        d.communityIdentity,
      ),
      ProfileField.datingPreference: ProfileValidators.datingPreference(
        d.datingPreference,
        d.communityIdentity,
      ),
    };
    return {for (final MapEntry(:key, :value) in results.entries) key: ?value};
  }

  static bool isComplete(ProfileDraft draft, {required DateTime today}) =>
      errors(draft, today: today).isEmpty;
}
