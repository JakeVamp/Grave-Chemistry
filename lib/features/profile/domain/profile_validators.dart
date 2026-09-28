import 'age.dart';
import 'community_identity.dart';
import 'dating_preference.dart';
import 'gender_option.dart';

/// Validation for onboarding fields. Limits match the CHECK constraints in
/// the profiles migration. Lengths count Unicode code points, as Postgres
/// `char_length` does, so emoji count as one character.
abstract final class ProfileValidators {
  static const int displayNameMaxLength = 50;
  static const int locationMaxLength = 100;
  static const int bioMaxLength = 500;
  static const int genderSelfDescriptionMaxLength = 50;

  static final RegExp _controlCharacters = RegExp(
    r'[\u0000-\u001F\u007F-\u009F]',
  );

  static int length(String value) => value.runes.length;

  static String? displayName(String? value) => _singleLineText(
    value,
    field: 'Display name',
    maxLength: displayNameMaxLength,
  );

  static String? city(String? value) =>
      _singleLineText(value, field: 'City', maxLength: locationMaxLength);

  static String? region(String? value) => _singleLineText(
    value,
    field: 'State or region',
    maxLength: locationMaxLength,
  );

  static String? bio(String? value) {
    if (length((value ?? '').trim()) > bioMaxLength) {
      return 'Bio must be $bioMaxLength characters or fewer.';
    }
    return null;
  }

  static String? birthDate(DateTime? value, {required DateTime today}) {
    if (value == null) return 'Birth date is required.';
    final date = DateTime.utc(value.year, value.month, value.day);
    if (date.isBefore(AgePolicy.earliestBirthDate)) {
      return 'Enter a valid birth date.';
    }
    if (date.isAfter(today)) return "Birth date can't be in the future.";
    if (AgePolicy.ageOn(date, today) < AgePolicy.minimumAge) {
      return 'You must be at least ${AgePolicy.minimumAge} to use '
          'Grave Chemistry.';
    }
    return null;
  }

  static String? gender(GenderOption? value) =>
      value == null ? 'Please choose a gender.' : null;

  static String? genderSelfDescription(String? value, GenderOption? gender) {
    if (gender != GenderOption.selfDescribe) return null;
    return _singleLineText(
      value,
      field: 'Gender description',
      maxLength: genderSelfDescriptionMaxLength,
      requiredMessage: 'Please describe your gender.',
    );
  }

  static String? communityIdentity(CommunityIdentity? value) =>
      value == null ? 'Please choose your community.' : null;

  /// A preference must start from the user's own identity. The app never
  /// changes either choice for the user; it only reports the mismatch.
  static String? datingPreference(
    DatingPreference? value,
    CommunityIdentity? identity,
  ) {
    if (value == null) return 'Please choose a dating preference.';
    if (identity != null && value.seeker != identity) {
      return "This doesn't match your community (${identity.label}). "
          'Choose a preference that starts with ${identity.label}.';
    }
    return null;
  }

  static String? _singleLineText(
    String? value, {
    required String field,
    required int maxLength,
    String? requiredMessage,
  }) {
    final text = (value ?? '').trim();
    if (text.isEmpty) return requiredMessage ?? '$field is required.';
    if (length(text) > maxLength) {
      return '$field must be $maxLength characters or fewer.';
    }
    if (_controlCharacters.hasMatch(text)) {
      return "$field can't contain line breaks or special characters.";
    }
    return null;
  }
}
