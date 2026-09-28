import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile/domain/community_identity.dart';
import 'package:grave_chemistry/features/profile/domain/dating_preference.dart';
import 'package:grave_chemistry/features/profile/domain/gender_option.dart';
import 'package:grave_chemistry/features/profile/domain/profile_completion.dart';
import 'package:grave_chemistry/features/profile/domain/profile_draft.dart';

void main() {
  final today = DateTime.utc(2026, 9, 28);

  ProfileDraft complete({
    String displayName = 'Raven',
    DateTime? birthDate,
    GenderOption gender = GenderOption.nonBinary,
    String genderSelfDescription = '',
    CommunityIdentity identity = CommunityIdentity.goth,
    DatingPreference preference = DatingPreference.gothSeekingGoth,
    String bio = '',
  }) {
    return ProfileDraft(
      displayName: displayName,
      birthDate: birthDate ?? DateTime.utc(1995, 10, 31),
      city: 'Salem',
      region: 'Massachusetts',
      bio: bio,
      gender: gender,
      genderSelfDescription: genderSelfDescription,
      communityIdentity: identity,
      datingPreference: preference,
    );
  }

  test('a fully valid draft is complete', () {
    expect(ProfileCompletion.isComplete(complete(), today: today), isTrue);
  });

  test('an empty draft reports every required field', () {
    final errors = ProfileCompletion.errors(const ProfileDraft(), today: today);
    expect(errors.keys, {
      ProfileField.displayName,
      ProfileField.birthDate,
      ProfileField.city,
      ProfileField.region,
      ProfileField.gender,
      ProfileField.communityIdentity,
      ProfileField.datingPreference,
    });
  });

  test('bio is not required', () {
    expect(
      ProfileCompletion.isComplete(complete(bio: ''), today: today),
      isTrue,
    );
  });

  test('whitespace-only answers do not count', () {
    expect(
      ProfileCompletion.errors(complete(displayName: '   '), today: today),
      contains(ProfileField.displayName),
    );
  });

  test('under-18 and future birth dates are incomplete', () {
    expect(
      ProfileCompletion.isComplete(
        complete(birthDate: DateTime.utc(2010, 1, 1)),
        today: today,
      ),
      isFalse,
    );
    expect(
      ProfileCompletion.isComplete(
        complete(birthDate: DateTime.utc(2030, 1, 1)),
        today: today,
      ),
      isFalse,
    );
  });

  test('self-describe needs a description', () {
    expect(
      ProfileCompletion.errors(
        complete(gender: GenderOption.selfDescribe),
        today: today,
      ).keys,
      [ProfileField.genderSelfDescription],
    );
    expect(
      ProfileCompletion.isComplete(
        complete(
          gender: GenderOption.selfDescribe,
          genderSelfDescription: 'Moth-adjacent',
        ),
        today: today,
      ),
      isTrue,
    );
  });

  test('a mismatched preference is incomplete', () {
    expect(
      ProfileCompletion.errors(
        complete(
          identity: CommunityIdentity.goth,
          preference: DatingPreference.normieSeekingGoth,
        ),
        today: today,
      ).keys,
      [ProfileField.datingPreference],
    );
  });

  test('normalising trims text, keeps bio line breaks, drops stale '
      'self-description', () {
    final draft = complete(
      displayName: '  Raven ',
      bio: '  Line one\nLine two  ',
      gender: GenderOption.woman,
      genderSelfDescription: 'left over',
    ).normalized();
    expect(draft.displayName, 'Raven');
    expect(draft.bio, 'Line one\nLine two');
    expect(draft.genderSelfDescription, '');
  });
}
