import 'community_identity.dart';
import 'dating_preference.dart';
import 'gender_option.dart';

/// Values entered during onboarding, before they are saved. There is no
/// completion flag: the database decides completion.
class ProfileDraft {
  const ProfileDraft({
    this.displayName = '',
    this.birthDate,
    this.city = '',
    this.region = '',
    this.bio = '',
    this.gender,
    this.genderSelfDescription = '',
    this.communityIdentity,
    this.datingPreference,
  });

  final String displayName;
  final DateTime? birthDate;
  final String city;
  final String region;
  final String bio;
  final GenderOption? gender;
  final String genderSelfDescription;
  final CommunityIdentity? communityIdentity;
  final DatingPreference? datingPreference;

  /// Normalised copy: surrounding whitespace trimmed and the self-description
  /// dropped unless "Self-describe" is chosen. Line breaks inside the bio are
  /// kept.
  ProfileDraft normalized() {
    return ProfileDraft(
      displayName: displayName.trim(),
      birthDate: birthDate,
      city: city.trim(),
      region: region.trim(),
      bio: bio.trim(),
      gender: gender,
      genderSelfDescription: gender == GenderOption.selfDescribe
          ? genderSelfDescription.trim()
          : '',
      communityIdentity: communityIdentity,
      datingPreference: datingPreference,
    );
  }
}
