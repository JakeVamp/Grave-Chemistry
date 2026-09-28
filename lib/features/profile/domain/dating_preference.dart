import 'community_identity.dart';

/// Mirrors rows in `public.dating_preferences`: a (seeker, sought) pair.
enum DatingPreference {
  gothSeekingGoth(
    'goth_seeking_goth',
    'Goth seeking Goth',
    seeker: CommunityIdentity.goth,
    sought: CommunityIdentity.goth,
  ),
  normieSeekingGoth(
    'normie_seeking_goth',
    'Normie seeking Goth',
    seeker: CommunityIdentity.normie,
    sought: CommunityIdentity.goth,
  ),
  gothSeekingNormie(
    'goth_seeking_normie',
    'Goth seeking Normie',
    seeker: CommunityIdentity.goth,
    sought: CommunityIdentity.normie,
  );

  const DatingPreference(
    this.code,
    this.label, {
    required this.seeker,
    required this.sought,
  });

  final String code;
  final String label;

  /// The identity of the person holding this preference.
  final CommunityIdentity seeker;
  final CommunityIdentity sought;

  static DatingPreference? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
