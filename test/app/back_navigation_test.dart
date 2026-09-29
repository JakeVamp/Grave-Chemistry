import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/features/auth/presentation/auth_screen.dart';
import 'package:grave_chemistry/features/home/presentation/home_screen.dart';
import 'package:grave_chemistry/features/moderation/domain/moderator_mfa.dart';
import 'package:grave_chemistry/features/moderation/presentation/moderator_home_screen.dart';
import 'package:grave_chemistry/features/moderation/presentation/photo_review_queue_screen.dart';
import 'package:grave_chemistry/features/moderation/presentation/photo_review_screen.dart';
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';

import '../helpers/fake_auth_repository.dart';
import '../helpers/fake_moderation.dart';
import '../helpers/fake_profile_repository.dart';
import '../helpers/pump_app.dart';

void main() {
  Future<void> go(WidgetTester tester, String location) async {
    GoRouter.of(tester.element(find.byType(Scaffold).first)).go(location);
    await tester.pumpAndSettle();
  }

  /// Android system back.
  Future<void> systemBack(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  group('member screens', () {
    for (final (label, title) in [
      ('Profile photos', 'Profile photos'),
      ('Discovery', 'Discovery'),
      ('Matches', 'Matches'),
      ('Messages', 'Messages'),
      ('Settings', 'Settings'),
    ]) {
      testWidgets('1+2. $label has Back to Home', (tester) async {
        await pumpApp(tester, FakeAuthRepository(currentUser: testUser));
        await tester.tapAndSettle(find.text(label));
        expect(find.byType(HomeScreen), findsNothing);
        expect(find.widgetWithText(AppBar, title), findsOneWidget);
        await tester.tapAndSettle(find.byType(BackButton));
        expect(find.byType(HomeScreen), findsOneWidget);
      });
    }

    testWidgets('opened directly (no history), Back and system back still '
        'lead to Home', (tester) async {
      await pumpApp(tester, FakeAuthRepository(currentUser: testUser));
      await go(tester, AppRoutes.settings);
      expect(find.byType(BackButton), findsOneWidget);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(HomeScreen), findsOneWidget);

      await go(tester, AppRoutes.profilePhotos);
      await systemBack(tester);
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('an unknown page has Back to Home', (tester) async {
      await pumpApp(tester, FakeAuthRepository(currentUser: testUser));
      await go(tester, '/nowhere');
      expect(find.text('Page not found'), findsWidgets);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('Home is a root screen without Back', (tester) async {
      await pumpApp(tester, FakeAuthRepository(currentUser: testUser));
      expect(find.byType(BackButton), findsNothing);
    });
  });

  group('signed-out screens', () {
    testWidgets('sign-up and forgot-password go back to sign-in', (
      tester,
    ) async {
      await pumpApp(tester, FakeAuthRepository());
      expect(find.byType(AuthScreen), findsOneWidget);
      expect(find.byType(BackButton), findsNothing, reason: 'root');

      await go(tester, AppRoutes.signUp);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(AuthScreen), findsOneWidget);

      await go(tester, AppRoutes.forgotPassword);
      await systemBack(tester);
      expect(find.byType(AuthScreen), findsOneWidget);
    });

    testWidgets('the check-email screen goes back to sign-in', (tester) async {
      await pumpApp(tester, FakeAuthRepository());
      await go(tester, '${AppRoutes.checkEmail}?email=a%40b.com');
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(AuthScreen), findsOneWidget);
    });
  });

  group('onboarding and verification', () {
    testWidgets('6. a member being verified has no Back, and system back '
        'does not leave verification', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(
          profile: completedProfileWith(VerificationStatus.notStarted),
        ),
      );
      expect(find.text('Verify your account'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
      await systemBack(tester);
      expect(find.text('Verify your account'), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });

    testWidgets('6. a member in profile setup has no Back', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: FakeProfileRepository(),
      );
      expect(find.text('Create your profile'), findsOneWidget);
      expect(find.byType(BackButton), findsNothing);
    });

    testWidgets('a moderator in member setup can go back to Moderator Home', (
      tester,
    ) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        profiles: FakeProfileRepository(),
      );
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      expect(find.byType(BackButton), findsNothing, reason: 'their root');

      await tester.tapAndSettle(find.text('Set up member profile'));
      expect(find.text('Create your profile'), findsOneWidget);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);

      await tester.tapAndSettle(find.text('Set up member profile'));
      await systemBack(tester);
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
    });
  });

  group('moderator screens', () {
    testWidgets('3+4. review detail → queue → Moderator Home → Home', (
      tester,
    ) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        moderation: FakeModerationRepository(items: [reviewItem('p1')]),
      );
      await tester.tapAndSettle(find.text('Moderator tools'));
      await tester.tapAndSettle(find.text('Photo review'));
      await tester.tapAndSettle(find.text('Morticia, 34'));
      expect(find.byType(PhotoReviewScreen), findsOneWidget);

      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(PhotoReviewQueueScreen), findsOneWidget);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(HomeScreen), findsOneWidget);
    });

    testWidgets('3+4. opened directly, detail still goes back to the queue '
        'and the queue to Moderator Home', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        moderation: FakeModerationRepository(items: [reviewItem('p1')]),
      );
      await go(tester, AppRoutes.photoReviewItem('p1'));
      expect(find.byType(PhotoReviewScreen), findsOneWidget);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(PhotoReviewQueueScreen), findsOneWidget);
      await systemBack(tester);
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
    });

    testWidgets('after auto-advancing to the next photo, Back returns to the '
        'queue', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        moderation: FakeModerationRepository(
          items: [
            reviewItem('p1'),
            reviewItem('p2', name: 'Lydia', minute: 1),
          ],
        ),
        logicalSize: const Size(390, 1400),
      );
      await tester.tapAndSettle(find.text('Moderator tools'));
      await tester.tapAndSettle(find.text('Photo review'));
      await tester.tapAndSettle(find.text('Morticia, 34'));
      await tester.tapAndSettle(find.text('Approve'));
      expect(find.text('Lydia, 34'), findsOneWidget);
      await tester.tapAndSettle(find.byType(BackButton));
      expect(find.byType(PhotoReviewQueueScreen), findsOneWidget);
    });

    testWidgets('5. going back never skips moderator MFA', (tester) async {
      final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        moderation: moderation,
        mfa: FakeModeratorMfaRepository(
          current: const MfaCodeRequired('factor-1'),
        ),
      );
      await go(tester, AppRoutes.photoReviewItem('p1'));
      await tester.tapAndSettle(find.byType(BackButton));
      await tester.tapAndSettle(find.byType(BackButton));

      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      expect(find.text('Two-factor verification'), findsOneWidget);
      expect(find.text('Photo review'), findsNothing);
    });

    testWidgets('an incomplete moderator’s Moderator Home has no Back into '
        'the dating app', (tester) async {
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: moderatorUser),
        profiles: FakeProfileRepository(),
      );
      expect(find.byType(BackButton), findsNothing);
      await systemBack(tester);
      expect(find.byType(ModeratorHomeScreen), findsOneWidget);
      expect(find.byType(HomeScreen), findsNothing);
    });
  });
}
