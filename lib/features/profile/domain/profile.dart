import 'age.dart';
import 'community_identity.dart';
import 'dating_preference.dart';
import 'gender_option.dart';

/// The signed-in user's own profile.
///
/// Contains the full birth date, so it must only ever be used for the owner.
/// Views of other users (discovery, later) need a separate model that
/// carries a computed age instead.
class Profile {
  const Profile({
    required this.id,
    required this.isCompleted,
    this.displayName,
    this.birthDate,
    this.city,
    this.region,
    this.bio,
    this.gender,
    this.genderSelfDescription,
    this.communityIdentity,
    this.datingPreference,
    this.createdAt,
    this.updatedAt,
  });

  final String id;

  /// Computed by the database; the app never sets it.
  final bool isCompleted;

  final String? displayName;
  final DateTime? birthDate;
  final String? city;
  final String? region;
  final String? bio;
  final GenderOption? gender;
  final String? genderSelfDescription;
  final CommunityIdentity? communityIdentity;
  final DatingPreference? datingPreference;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  int? ageOn(DateTime today) {
    final birthDate = this.birthDate;
    return birthDate == null ? null : AgePolicy.ageOn(birthDate, today);
  }
}
