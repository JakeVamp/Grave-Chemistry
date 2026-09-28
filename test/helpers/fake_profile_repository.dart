import 'dart:async';

import 'package:grave_chemistry/features/profile/domain/community_identity.dart';
import 'package:grave_chemistry/features/profile/domain/dating_preference.dart';
import 'package:grave_chemistry/features/profile/domain/gender_option.dart';
import 'package:grave_chemistry/features/profile/domain/profile.dart';
import 'package:grave_chemistry/features/profile/domain/profile_completion.dart';
import 'package:grave_chemistry/features/profile/domain/profile_draft.dart';
import 'package:grave_chemistry/features/profile/domain/profile_failure.dart';
import 'package:grave_chemistry/features/profile/domain/profile_repository.dart';

final completedProfile = Profile(
  id: 'user-1',
  isCompleted: true,
  displayName: 'Raven',
  birthDate: DateTime.utc(1995, 10, 31),
  city: 'Salem',
  region: 'Massachusetts',
  gender: GenderOption.nonBinary,
  communityIdentity: CommunityIdentity.goth,
  datingPreference: DatingPreference.gothSeekingGoth,
);

/// In-memory [ProfileRepository]. Like the database, it decides completion
/// itself instead of trusting the client.
class FakeProfileRepository implements ProfileRepository {
  FakeProfileRepository({this.profile});

  /// A repository whose user already finished onboarding.
  factory FakeProfileRepository.completed() =>
      FakeProfileRepository(profile: completedProfile);

  Profile? profile;

  /// Thrown (once) by the next fetch / save.
  ProfileFailure? nextFetchFailure;
  ProfileFailure? nextSaveFailure;

  /// When set, requests wait for it, to observe loading states.
  Completer<void>? gate;

  int fetchCount = 0;
  final List<ProfileDraft> savedDrafts = [];

  @override
  Future<Profile?> fetchMyProfile() async {
    fetchCount++;
    if (gate != null) await gate!.future;
    final failure = nextFetchFailure;
    if (failure != null) {
      nextFetchFailure = null;
      throw failure;
    }
    return profile;
  }

  @override
  Future<Profile> saveMyProfile(ProfileDraft draft) async {
    savedDrafts.add(draft);
    if (gate != null) await gate!.future;
    final failure = nextSaveFailure;
    if (failure != null) {
      nextSaveFailure = null;
      throw failure;
    }
    final d = draft.normalized();
    return profile = Profile(
      id: 'user-1',
      isCompleted: ProfileCompletion.isComplete(d, today: DateTime.utc(2026)),
      displayName: d.displayName,
      birthDate: d.birthDate,
      city: d.city,
      region: d.region,
      bio: d.bio.isEmpty ? null : d.bio,
      gender: d.gender,
      genderSelfDescription: d.genderSelfDescription.isEmpty
          ? null
          : d.genderSelfDescription,
      communityIdentity: d.communityIdentity,
      datingPreference: d.datingPreference,
    );
  }
}
