import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile/domain/community_identity.dart';
import 'package:grave_chemistry/features/profile/domain/dating_preference.dart';
import 'package:grave_chemistry/features/profile/domain/gender_option.dart';
import 'package:grave_chemistry/features/profile/domain/profile.dart';
import 'package:grave_chemistry/features/profile/domain/profile_failure.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_profile_repository.dart';
import '../../helpers/pump_app.dart';

const _setupTitle = 'Create your profile';
const _homeMarker = 'Foundation build';
final _saveButton = find.widgetWithText(FilledButton, 'Save profile');

Future<void> _pickBirthDate(WidgetTester tester, DateTime date) async {
  await tester.tapAndSettle(find.bySemanticsLabel('Birth date'));
  // Switch the picker to typed entry.
  await tester.tap(find.byIcon(Icons.edit_outlined));
  await tester.pumpAndSettle();
  String two(int n) => n.toString().padLeft(2, '0');
  await tester.enterText(
    find.descendant(of: find.byType(Dialog), matching: find.byType(TextField)),
    '${two(date.month)}/${two(date.day)}/${date.year}',
  );
  await tester.tap(find.text('OK'));
  await tester.pumpAndSettle();
}

Future<void> _chooseGender(WidgetTester tester, String label) async {
  await tester.tapAndSettle(find.byType(DropdownButtonFormField<GenderOption>));
  await tester.tap(find.text(label).last);
  await tester.pumpAndSettle();
}

Future<void> _fillValidProfile(WidgetTester tester) async {
  await tester.enterField('Display name', '  Raven  ');
  await _pickBirthDate(tester, DateTime(1995, 10, 31));
  await _chooseGender(tester, 'Non-binary');
  await tester.enterField('Bio (optional)', 'Fog enjoyer.\nVelvet, always!');
  await tester.enterField('City', 'Salem');
  await tester.enterField('State / region', 'Massachusetts');
  await tester.tapAndSettle(find.text('Goth'));
  await tester.tapAndSettle(find.text('Goth seeking Normie'));
}

void main() {
  group('routing after sign-in', () {
    testWidgets('user without a profile goes to profile setup', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(),
      );
      expect(find.text(_setupTitle), findsOneWidget);
    });

    testWidgets('user with an incomplete profile goes to profile setup', (
      tester,
    ) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(
          profile: const Profile(
            id: 'user-1',
            isCompleted: false,
            displayName: 'Half Done',
            city: 'Salem',
          ),
        ),
      );
      expect(find.text(_setupTitle), findsOneWidget);
      // Previously saved answers are restored.
      expect(find.text('Half Done'), findsOneWidget);
      expect(find.text('Salem'), findsOneWidget);
    });

    testWidgets('user with a completed profile goes to the app', (
      tester,
    ) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository.completed(),
      );
      expect(find.text(_homeMarker), findsOneWidget);
    });

    testWidgets('signing in without a profile lands on setup', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(),
        profiles: FakeProfileRepository(),
      );
      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'nightshade');
      await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Sign in'));

      expect(find.text(_setupTitle), findsOneWidget);
    });

    testWidgets('shows loading, then an error with retry', (tester) async {
      final profiles = FakeProfileRepository.completed()
        ..gate = Completer<void>()
        ..nextFetchFailure = const ProfileFailure(
          ProfileFailureType.network,
          'Unable to connect. Check your internet connection and try again.',
        );
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: profiles,
        settle: false,
      );
      await tester.pump();
      // pumpAndSettle would wait forever on the spinner.
      expect(find.text('Loading your profile…'), findsOneWidget);

      profiles.gate!.complete();
      profiles.gate = null;
      await tester.pumpAndSettle();
      expect(find.text("We couldn't load your profile"), findsOneWidget);
      expect(find.textContaining('internet connection'), findsOneWidget);

      await tester.tapAndSettle(find.text('Try again'));
      expect(find.text(_homeMarker), findsOneWidget);
    });

    testWidgets('signing out from setup returns to sign-in', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(),
      );
      await tester.tapAndSettle(find.widgetWithText(TextButton, 'Sign out'));

      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });
  });

  group('profile setup form', () {
    Future<FakeProfileRepository> openSetup(WidgetTester tester) async {
      final profiles = FakeProfileRepository();
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: profiles,
      );
      return profiles;
    }

    testWidgets('shows every required-field error and saves nothing', (
      tester,
    ) async {
      final profiles = await openSetup(tester);
      await tester.tapAndSettle(_saveButton);

      for (final message in [
        'Display name is required.',
        'Birth date is required.',
        'Please choose a gender.',
        'City is required.',
        'State or region is required.',
        'Please choose your community.',
        'Please choose a dating preference.',
      ]) {
        expect(find.text(message), findsOneWidget, reason: message);
      }
      expect(profiles.savedDrafts, isEmpty);
    });

    testWidgets('rejects users under 18', (tester) async {
      final profiles = await openSetup(tester);
      final now = DateTime.now().toUtc();
      await _pickBirthDate(tester, DateTime(now.year - 17, 1, 1));
      await tester.tapAndSettle(_saveButton);

      expect(
        find.text('You must be at least 18 to use Grave Chemistry.'),
        findsOneWidget,
      );
      expect(profiles.savedDrafts, isEmpty);
    });

    testWidgets('self-describe asks for a description', (tester) async {
      await openSetup(tester);
      expect(find.text('Describe your gender'), findsNothing);

      await _chooseGender(tester, 'Self-describe');
      expect(find.text('Describe your gender'), findsOneWidget);

      await tester.tapAndSettle(_saveButton);
      expect(find.text('Please describe your gender.'), findsOneWidget);
    });

    testWidgets('flags a preference that contradicts the identity without '
        'changing it', (tester) async {
      await openSetup(tester);
      await tester.tapAndSettle(find.text('Normie'));
      await tester.tapAndSettle(find.text('Goth seeking Goth'));
      await tester.tapAndSettle(_saveButton);

      expect(
        find.textContaining("doesn't match your community (Normie)"),
        findsOneWidget,
      );
    });

    testWidgets('a valid profile saves and moves on to verification', (
      tester,
    ) async {
      final profiles = await openSetup(tester);
      await _fillValidProfile(tester);
      await tester.tapAndSettle(_saveButton);

      expect(profiles.savedDrafts, hasLength(1));
      final saved = profiles.savedDrafts.single.normalized();
      expect(saved.displayName, 'Raven');
      expect(saved.birthDate, DateTime.utc(1995, 10, 31));
      expect(saved.bio, 'Fog enjoyer.\nVelvet, always!');
      expect(saved.gender, GenderOption.nonBinary);
      expect(saved.communityIdentity, CommunityIdentity.goth);
      expect(saved.datingPreference, DatingPreference.gothSeekingNormie);
      // Next onboarding step: live photo verification, not the app.
      expect(find.text('Verify your account'), findsOneWidget);
      expect(find.text(_homeMarker), findsNothing);
    });

    testWidgets('shows a friendly error when saving fails', (tester) async {
      final profiles = await openSetup(tester);
      profiles.nextSaveFailure = const ProfileFailure(
        ProfileFailureType.network,
        'Unable to connect. Check your internet connection and try again.',
      );
      await _fillValidProfile(tester);
      await tester.tapAndSettle(_saveButton);

      expect(find.textContaining('internet connection'), findsOneWidget);
      expect(find.text(_setupTitle), findsOneWidget);
    });
  });

  group('accessibility and layout', () {
    testWidgets('setup fits a small phone with 2x text', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(),
        logicalSize: const Size(320, 568),
        textScale: 2,
      );
      await tester.tapAndSettle(_saveButton);
      await tester.tapAndSettle(find.text('Goth seeking Normie'));
      // Any overflow would have failed the test by now.
      expect(tester.takeException(), isNull);
    });

    testWidgets('setup meets tap target and labelling guidelines', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(),
      );
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
