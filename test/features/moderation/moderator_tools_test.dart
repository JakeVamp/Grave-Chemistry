import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:grave_chemistry/core/router/app_routes.dart';
import 'package:grave_chemistry/features/home/presentation/home_screen.dart';
import 'package:grave_chemistry/features/moderation/domain/moderator_mfa.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_moderation.dart';
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
}
