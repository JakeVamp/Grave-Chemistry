import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile/domain/age.dart';
import 'package:grave_chemistry/features/profile/domain/community_identity.dart';
import 'package:grave_chemistry/features/profile/domain/dating_preference.dart';
import 'package:grave_chemistry/features/profile/domain/gender_option.dart';
import 'package:grave_chemistry/features/profile/domain/profile_validators.dart';

void main() {
  final today = DateTime.utc(2026, 9, 28);

  group('display name', () {
    test('is required and trimmed', () {
      expect(ProfileValidators.displayName(''), 'Display name is required.');
      expect(ProfileValidators.displayName('   '), 'Display name is required.');
      expect(ProfileValidators.displayName('  Raven  '), isNull);
    });

    test('enforces the length limit in characters, not bytes', () {
      expect(ProfileValidators.displayName('a' * 50), isNull);
      expect(
        ProfileValidators.displayName('a' * 51),
        'Display name must be 50 characters or fewer.',
      );
      // 50 emoji are 100 UTF-16 units but 50 characters, as in Postgres.
      expect(ProfileValidators.displayName('🦇' * 50), isNull);
    });

    test('rejects line breaks and control characters', () {
      expect(ProfileValidators.displayName('Ra\nven'), isNotNull);
      expect(ProfileValidators.displayName('Ra\u0007ven'), isNotNull);
    });
  });

  group('location', () {
    test('city and region are required', () {
      expect(ProfileValidators.city(''), 'City is required.');
      expect(ProfileValidators.region(''), 'State or region is required.');
      expect(ProfileValidators.city('Salem'), isNull);
      expect(ProfileValidators.region('Massachusetts'), isNull);
    });

    test('have a 100 character limit', () {
      expect(ProfileValidators.city('x' * 100), isNull);
      expect(ProfileValidators.city('x' * 101), isNotNull);
    });
  });

  group('bio', () {
    test('is optional', () {
      expect(ProfileValidators.bio(''), isNull);
      expect(ProfileValidators.bio(null), isNull);
    });

    test('keeps punctuation and line breaks', () {
      expect(
        ProfileValidators.bio('Crypt keeper.\n\nLikes: fog, velvet & rain!'),
        isNull,
      );
    });

    test('has a 500 character limit', () {
      expect(ProfileValidators.bio('x' * 500), isNull);
      expect(
        ProfileValidators.bio('x' * 501),
        'Bio must be 500 characters or fewer.',
      );
    });
  });

  group('birth date', () {
    test('is required', () {
      expect(
        ProfileValidators.birthDate(null, today: today),
        'Birth date is required.',
      );
    });

    test('rejects future dates', () {
      expect(
        ProfileValidators.birthDate(DateTime.utc(2026, 9, 29), today: today),
        "Birth date can't be in the future.",
      );
    });

    test('rejects users under 18', () {
      expect(
        ProfileValidators.birthDate(DateTime.utc(2008, 9, 29), today: today),
        'You must be at least 18 to use Grave Chemistry.',
      );
      expect(
        ProfileValidators.birthDate(DateTime.utc(2026, 9, 28), today: today),
        'You must be at least 18 to use Grave Chemistry.',
      );
    });

    test('accepts users who turn 18 today', () {
      expect(
        ProfileValidators.birthDate(DateTime.utc(2008, 9, 28), today: today),
        isNull,
      );
    });

    test('rejects implausible dates', () {
      expect(
        ProfileValidators.birthDate(DateTime.utc(1899, 12, 31), today: today),
        'Enter a valid birth date.',
      );
    });
  });

  group('age', () {
    test('counts whole years', () {
      expect(AgePolicy.ageOn(DateTime.utc(2000, 9, 28), today), 26);
      expect(AgePolicy.ageOn(DateTime.utc(2000, 9, 29), today), 25);
    });

    test('29 February birthdays count from 1 March in non-leap years', () {
      final born = DateTime.utc(2008, 2, 29);
      expect(AgePolicy.ageOn(born, DateTime.utc(2026, 2, 28)), 17);
      expect(AgePolicy.ageOn(born, DateTime.utc(2026, 3, 1)), 18);
    });

    test('latest allowed birth date is exactly old enough', () {
      final latest = AgePolicy.latestAllowedBirthDate(today);
      expect(latest, DateTime.utc(2008, 9, 28));
      expect(AgePolicy.ageOn(latest, today), 18);
      expect(AgePolicy.ageOn(latest.add(const Duration(days: 1)), today), 17);
    });

    test('latest allowed birth date handles leap days', () {
      final today = DateTime.utc(2028, 2, 29);
      final latest = AgePolicy.latestAllowedBirthDate(today);
      expect(AgePolicy.ageOn(latest, today), 18);
      expect(AgePolicy.ageOn(latest.add(const Duration(days: 1)), today), 17);
    });

    test('today is the UTC calendar date', () {
      final lateEvening = DateTime.parse('2026-09-28T23:30:00-05:00');
      expect(AgePolicy.todayUtc(lateEvening), DateTime.utc(2026, 9, 29));
    });
  });

  group('gender', () {
    test('is required', () {
      expect(ProfileValidators.gender(null), 'Please choose a gender.');
      expect(ProfileValidators.gender(GenderOption.agender), isNull);
    });

    test('self-description is required only for Self-describe', () {
      expect(
        ProfileValidators.genderSelfDescription('', GenderOption.selfDescribe),
        'Please describe your gender.',
      );
      expect(
        ProfileValidators.genderSelfDescription(
          'Moth-adjacent',
          GenderOption.selfDescribe,
        ),
        isNull,
      );
      expect(
        ProfileValidators.genderSelfDescription('', GenderOption.woman),
        isNull,
      );
    });

    test('offers more than a binary choice', () {
      expect(GenderOption.values.length, greaterThan(2));
      expect(GenderOption.values, contains(GenderOption.selfDescribe));
    });
  });

  group('community and preference', () {
    test('both are required', () {
      expect(ProfileValidators.communityIdentity(null), isNotNull);
      expect(ProfileValidators.datingPreference(null, null), isNotNull);
    });

    test('preference must match the chosen identity', () {
      expect(
        ProfileValidators.datingPreference(
          DatingPreference.normieSeekingGoth,
          CommunityIdentity.goth,
        ),
        contains("doesn't match your community (Goth)"),
      );
      expect(
        ProfileValidators.datingPreference(
          DatingPreference.gothSeekingNormie,
          CommunityIdentity.goth,
        ),
        isNull,
      );
      expect(
        ProfileValidators.datingPreference(
          DatingPreference.normieSeekingGoth,
          CommunityIdentity.normie,
        ),
        isNull,
      );
    });

    test('codes match the database seed values', () {
      expect(CommunityIdentity.values.map((e) => e.code), ['goth', 'normie']);
      expect(DatingPreference.values.map((e) => e.code), [
        'goth_seeking_goth',
        'normie_seeking_goth',
        'goth_seeking_normie',
      ]);
      expect(CommunityIdentity.fromCode('unknown_future_value'), isNull);
    });
  });
}
