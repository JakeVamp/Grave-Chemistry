import '../domain/community_identity.dart';
import '../domain/dating_preference.dart';
import '../domain/gender_option.dart';
import '../domain/profile.dart';
import '../domain/profile_draft.dart';

/// Converts between `public.profiles` rows and domain models.
abstract final class ProfileRowMapper {
  /// Columns read by the app. `profile_completed` is read but never written.
  static const String selectColumns =
      'id, display_name, birth_date, location_city, location_state_or_region, '
      'bio, gender, gender_self_description, community_identity, '
      'dating_preference, profile_completed, created_at, updated_at';

  static Profile fromRow(Map<String, dynamic> row) {
    return Profile(
      id: row['id'] as String,
      isCompleted: row['profile_completed'] as bool? ?? false,
      displayName: row['display_name'] as String?,
      birthDate: _parseDate(row['birth_date'] as String?),
      city: row['location_city'] as String?,
      region: row['location_state_or_region'] as String?,
      bio: row['bio'] as String?,
      gender: GenderOption.fromCode(row['gender'] as String?),
      genderSelfDescription: row['gender_self_description'] as String?,
      communityIdentity: CommunityIdentity.fromCode(
        row['community_identity'] as String?,
      ),
      datingPreference: DatingPreference.fromCode(
        row['dating_preference'] as String?,
      ),
      createdAt: _parseTimestamp(row['created_at'] as String?),
      updatedAt: _parseTimestamp(row['updated_at'] as String?),
    );
  }

  /// Writable columns only. Completion, timestamps and id are excluded;
  /// the database rejects client writes to them anyway.
  static Map<String, dynamic> toWritableRow(ProfileDraft draft) {
    final d = draft.normalized();
    return {
      'display_name': d.displayName,
      'birth_date': d.birthDate == null ? null : formatDate(d.birthDate!),
      'location_city': d.city,
      'location_state_or_region': d.region,
      'bio': d.bio.isEmpty ? null : d.bio,
      'gender': d.gender?.code,
      'gender_self_description': d.genderSelfDescription.isEmpty
          ? null
          : d.genderSelfDescription,
      'community_identity': d.communityIdentity?.code,
      'dating_preference': d.datingPreference?.code,
    };
  }

  /// `YYYY-MM-DD`, the Postgres `date` format.
  static String formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${date.year.toString().padLeft(4, '0')}-${two(date.month)}-'
        '${two(date.day)}';
  }

  static DateTime? _parseDate(String? value) {
    if (value == null) return null;
    final parsed = DateTime.parse(value);
    return DateTime.utc(parsed.year, parsed.month, parsed.day);
  }

  static DateTime? _parseTimestamp(String? value) =>
      value == null ? null : DateTime.parse(value).toUtc();
}
