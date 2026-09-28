import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/application/auth_providers.dart';
import 'package:grave_chemistry/features/auth/domain/auth_event.dart';
import 'package:grave_chemistry/features/profile/application/profile_providers.dart';
import 'package:grave_chemistry/features/profile/domain/community_identity.dart';
import 'package:grave_chemistry/features/profile/domain/dating_preference.dart';
import 'package:grave_chemistry/features/profile/domain/gender_option.dart';
import 'package:grave_chemistry/features/profile/domain/profile_draft.dart';
import 'package:grave_chemistry/features/profile/domain/profile_failure.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_profile_repository.dart';

void main() {
  late FakeAuthRepository auth;
  late FakeProfileRepository profiles;

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        authRepositoryProvider.overrideWithValue(auth),
        profileRepositoryProvider.overrideWithValue(profiles),
      ],
    );
    addTearDown(container.dispose);
    container.listen(profileGateProvider, (_, _) {});
    return container;
  }

  Future<void> settle(ProviderContainer container) async {
    await Future<void>.delayed(Duration.zero);
    try {
      await container.read(profileControllerProvider.future);
    } on ProfileFailure {
      // Surfaced through the provider state.
    }
  }

  final validDraft = ProfileDraft(
    displayName: 'Raven',
    birthDate: DateTime.utc(1995, 10, 31),
    city: 'Salem',
    region: 'Massachusetts',
    gender: GenderOption.agender,
    communityIdentity: CommunityIdentity.normie,
    datingPreference: DatingPreference.normieSeekingGoth,
  );

  setUp(() {
    auth = FakeAuthRepository();
    profiles = FakeProfileRepository();
  });

  test('signed out: no profile and no request', () async {
    final container = createContainer();
    await settle(container);

    expect(container.read(profileControllerProvider).value, isNull);
    expect(profiles.fetchCount, 0);
  });

  test('signed in without a profile: gate is incomplete', () async {
    auth = FakeAuthRepository(currentUser: testUser);
    final container = createContainer();
    expect(container.read(profileGateProvider), ProfileGate.loading);

    await settle(container);
    expect(container.read(profileGateProvider), ProfileGate.incomplete);
    expect(profiles.fetchCount, 1);
  });

  test('signed in with a completed profile: gate is complete', () async {
    auth = FakeAuthRepository(currentUser: testUser);
    profiles = FakeProfileRepository.completed();
    final container = createContainer();
    await settle(container);

    expect(container.read(profileGateProvider), ProfileGate.complete);
  });

  test('signing in loads the profile; signing out clears it', () async {
    profiles = FakeProfileRepository.completed();
    final container = createContainer();
    await settle(container);
    expect(profiles.fetchCount, 0);

    auth.emit(AuthEventType.signedIn, testUser);
    await settle(container);
    expect(profiles.fetchCount, 1);
    expect(container.read(profileGateProvider), ProfileGate.complete);

    // A token refresh for the same user must not refetch.
    auth.emit(AuthEventType.sessionRefreshed, testUser);
    await settle(container);
    expect(profiles.fetchCount, 1);

    auth.emit(AuthEventType.signedOut);
    await settle(container);
    expect(container.read(profileControllerProvider).value, isNull);
  });

  test('a failed load reports an error and can be retried', () async {
    auth = FakeAuthRepository(currentUser: testUser);
    profiles = FakeProfileRepository.completed()
      ..nextFetchFailure = const ProfileFailure(
        ProfileFailureType.network,
        'offline',
      );
    final container = createContainer();
    await settle(container);
    expect(container.read(profileGateProvider), ProfileGate.error);

    container.read(profileControllerProvider.notifier).reload();
    expect(container.read(profileGateProvider), ProfileGate.loading);
    await settle(container);
    expect(container.read(profileGateProvider), ProfileGate.complete);
  });

  test('saving publishes the server result', () async {
    auth = FakeAuthRepository(currentUser: testUser);
    final container = createContainer();
    await settle(container);

    final saved = await container
        .read(profileControllerProvider.notifier)
        .save(validDraft);
    expect(saved.isCompleted, isTrue);
    expect(container.read(profileGateProvider), ProfileGate.complete);
  });

  test('completion comes from the repository, not the client', () async {
    auth = FakeAuthRepository(currentUser: testUser);
    final container = createContainer();
    await settle(container);

    // There is no way to pass a completion flag; an incomplete draft stays
    // incomplete.
    await container
        .read(profileControllerProvider.notifier)
        .save(const ProfileDraft(displayName: 'Raven'));
    expect(container.read(profileGateProvider), ProfileGate.incomplete);
  });

  test('a failed save throws and keeps the previous state', () async {
    auth = FakeAuthRepository(currentUser: testUser);
    profiles.nextSaveFailure = const ProfileFailure(
      ProfileFailureType.underage,
      'too young',
    );
    final container = createContainer();
    await settle(container);

    await expectLater(
      container.read(profileControllerProvider.notifier).save(validDraft),
      throwsA(isA<ProfileFailure>()),
    );
    expect(container.read(profileGateProvider), ProfileGate.incomplete);
  });
}
