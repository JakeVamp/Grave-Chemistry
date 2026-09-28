import 'age.dart';
import 'community_identity.dart';
import 'dating_preference.dart';
import 'gender_option.dart';
import 'verification_status.dart';

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
    this.verificationStatus,
    this.verificationSubmittedAt,
    this.verificationReviewedAt,
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

  /// Set by the backend only. Null if the server sent a status this app
  /// version doesn't know.
  final VerificationStatus? verificationStatus;
  final DateTime? verificationSubmittedAt;
  final DateTime? verificationReviewedAt;

  final DateTime? createdAt;
  final DateTime? updatedAt;

  int? ageOn(DateTime today) {
    final birthDate = this.birthDate;
    return birthDate == null ? null : AgePolicy.ageOn(birthDate, today);
  }
}
