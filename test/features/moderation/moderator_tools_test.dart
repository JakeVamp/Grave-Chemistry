import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/features/home/presentation/home_screen.dart';
import 'package:grave_chemistry/features/moderation/domain/moderator_mfa.dart';
import 'package:grave_chemistry/features/moderation/presentation/moderator_home_screen.dart';
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_moderation.dart';
import '../../helpers/fake_profile_repository.dart';
import '../../helpers/pump_app.dart';

void main() {
  testWidgets('members who are not moderators never see moderator tools', (
    tester,
  ) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: testUser),
      moderation: moderation,
    );
    expect(find.text('Moderator tools'), findsNothing);

    // Typing the address directly doesn't help either.
    GoRouter.of(tester.element(find.byType(HomeScreen)))
        .go(AppRoutes.photoReview);
    await tester.pumpAndSettle();
    expect(find.byType(HomeScreen), findsOneWidget);
    expect(find.text('Photo review'), findsNothing);
    expect(moderation.calls, isEmpty, reason: 'no moderator request is made');
  });

  testWidgets('moderators see the entry point on the home screen', (
    tester,
  ) async {
    await pumpApp(tester, FakeAuthRepository(currentUser: moderatorUser));
    await tester.tapAndSettle(find.text('Moderator tools'));
    await tester.tapAndSettle(find.text('Photo review'));
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('without MFA in this session, tools stay locked until a code '
      'is verified', (tester) async {
    final mfa = FakeModeratorMfaRepository(
      current: const MfaCodeRequired('factor-1'),
    );
    final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: moderatorUser),
      mfa: mfa,
      moderation: moderation,
    );
    await tester.tapAndSettle(find.text('Moderator tools'));

    expect(find.text('Two-factor verification'), findsOneWidget);
    expect(find.text('Photo review'), findsNothing);
    expect(moderation.calls, isEmpty);

    await tester.enterText(find.byType(TextField), '000000');
    await tester.tapAndSettle(find.text('Verify'));
    expect(find.textContaining("That code didn't work"), findsOneWidget);
    expect(find.text('Photo review'), findsNothing);

    await tester.enterText(find.byType(TextField), '12');
    await tester.tapAndSettle(find.text('Verify'));
    expect(find.text('Enter the 6-digit code.'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      FakeModeratorMfaRepository.validCode,
    );
    await tester.tapAndSettle(find.text('Verify'));
    expect(find.text('Photo review'), findsOneWidget);
    expect(mfa.calls, ['verify:factor-1', 'verify:factor-1']);
  });

  testWidgets('a moderator without an authenticator sets one up first', (
    tester,
  ) async {
    final mfa = FakeModeratorMfaRepository(
      current: const MfaEnrollmentRequired(),
    );
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: moderatorUser),
      mfa: mfa,
    );
    await tester.tapAndSettle(find.text('Moderator tools'));
    expect(find.text('Set up two-factor verification'), findsOneWidget);

    await tester.tapAndSettle(find.text('Set up authenticator'));
    expect(find.text('JBSWY3DPEHPK3PXP'), findsOneWidget);

    await tester.enterText(
      find.byType(TextField),
      FakeModeratorMfaRepository.validCode,
    );
    await tester.tapAndSettle(find.text('Verify'));
    expect(find.text('Photo review'), findsOneWidget);
    expect(mfa.calls, ['enroll', 'verify:factor-new']);
  });

  group('moderators with an unfinished member profile', () {
    testWidgets('1. a normal user without a profile still goes to profile '
        'setup', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(),
      );
      expect(find.text('Create your profile'), findsOneWidget);
      expect(find.byType(ModeratorHomeScreen), findsNothing);
    });

    testWidgets('a normal user awaiting verification still goes to '
        'verification', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(
          profile: completedProfileWith(VerificationStatus.notStarted),
        ),
      );
      expect(find.text('Verify your account'), findsOneWidget);
    });

    testWidgets('2+3. an unverified moderator lands on Moderator Home, which '
        'stays locked until MFA succeeds', (tester) async {
      final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
      final mfa = FakeModeratorMfaRepository(
        current: const MfaCodeRequired('factor-1'),
      );
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        profiles: FakeProfileRepository(
          profile: completedProfileWith(VerificationStatus.notStarted),
        ),
        moderation: moderation,
        mfa: mfa,
      );

      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      expect(find.text('Verify your account'), findsNothing);
      expect(find.text('Two-factor verification'), findsOneWidget);
      expect(find.text('Photo review'), findsNothing);
      expect(moderation.calls, isEmpty, reason: 'no moderator action yet');

      await tester.enterText(
        find.byType(TextField),
        FakeModeratorMfaRepository.validCode,
      );
      await tester.tapAndSettle(find.text('Verify'));
      await tester.tapAndSettle(find.text('Photo review'));
      expect(find.text('Morticia, 34'), findsOneWidget);
    });

    testWidgets('a moderator without any profile reaches Moderator Home, and '
        'the dating app stays closed', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        profiles: FakeProfileRepository(),
      );
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      expect(find.textContaining('members can’t see you'), findsOneWidget);

      GoRouter.of(tester.element(find.byType(ModeratorHomeScreen)))
          .go(AppRoutes.discovery);
      await tester.pumpAndSettle();
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      expect(find.text('Discovery is not built yet.'), findsNothing);
    });

    testWidgets('an incomplete moderator can open member setup or sign out', (
      tester,
    ) async {
      final auth = FakeAuthRepository(currentUser: moderatorUser);
      await pumpApp(tester, auth, profiles: FakeProfileRepository());

      await tester.tapAndSettle(find.text('Set up member profile'));
      expect(find.text('Create your profile'), findsOneWidget);

      GoRouter.of(tester.element(find.text('Create your profile')))
          .go(AppRoutes.moderation);
      await tester.pumpAndSettle();
      await tester.tapAndSettle(find.byTooltip('Sign out'));
      expect(auth.calls, contains('signOut'));
    });

    testWidgets('a fully onboarded moderator keeps the normal app', (
      tester,
    ) async {
      await pumpApp(tester, FakeAuthRepository(currentUser: moderatorUser));
      expect(find.text('Foundation build'), findsOneWidget);
      await tester.tapAndSettle(find.text('Moderator tools'));
      expect(find.text('Set up member profile'), findsNothing);
      expect(find.byTooltip('Sign out'), findsNothing);
    });
  });
}
