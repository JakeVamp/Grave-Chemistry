import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/domain/auth_event.dart';
import 'package:grave_chemistry/features/auth/domain/auth_failure.dart';
import 'package:grave_chemistry/features/auth/domain/sign_up_result.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/pump_app.dart';

final _signInButton = find.widgetWithText(FilledButton, 'Sign in');
const _homeMarker = 'Foundation build';

void main() {
  group('startup', () {
    testWidgets('signed-out users land on the sign-in screen', (tester) async {
      await pumpApp(tester, FakeAuthRepository());

      expect(find.text('Grave Chemistry'), findsOneWidget);
      expect(_signInButton, findsOneWidget);
      expect(find.text('Forgot password?'), findsOneWidget);
      expect(find.text('Create an account'), findsOneWidget);
    });

    testWidgets('a persisted session goes straight to the app', (tester) async {
      await pumpApp(tester, FakeAuthRepository(currentUser: testUser));

      expect(find.text(_homeMarker), findsOneWidget);
    });
  });

  group('sign in', () {
    testWidgets('validates fields before calling the backend', (tester) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, repo);

      await tester.tapAndSettle(_signInButton);
      expect(find.text('Email is required.'), findsOneWidget);
      expect(find.text('Password is required.'), findsOneWidget);

      await tester.enterField('Email', 'not-an-email');
      await tester.tapAndSettle(_signInButton);
      expect(find.text('Enter a valid email address.'), findsOneWidget);

      expect(repo.calls, isEmpty);
    });

    testWidgets('shows loading, then enters the app', (tester) async {
      final repo = FakeAuthRepository()..gate = Completer<void>();
      await pumpApp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'nightshade');
      await tester.tap(_signInButton);
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(repo.calls, ['signIn:raven@example.com']);

      repo.gate!.complete();
      await tester.pumpAndSettle();
      expect(find.text(_homeMarker), findsOneWidget);
    });

    testWidgets('shows a friendly error on failure', (tester) async {
      final repo = FakeAuthRepository()
        ..nextFailure = const AuthFailure(
          AuthFailureType.invalidCredentials,
          'Incorrect email or password.',
        );
      await pumpApp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'wrong');
      await tester.tapAndSettle(_signInButton);

      expect(find.text('Incorrect email or password.'), findsOneWidget);
      expect(_signInButton, findsOneWidget);
    });

    testWidgets('unconfirmed email offers to resend confirmation', (
      tester,
    ) async {
      final repo = FakeAuthRepository()
        ..nextFailure = const AuthFailure(
          AuthFailureType.emailNotConfirmed,
          'Please confirm your email address before signing in.',
        );
      await pumpApp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'nightshade');
      await tester.tapAndSettle(_signInButton);
      await tester.tapAndSettle(find.text('Resend confirmation email'));

      expect(repo.calls.last, 'resend:raven@example.com');
      expect(find.text('Check your email'), findsOneWidget);
    });

    testWidgets('shows email-link errors on the sign-in screen', (
      tester,
    ) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, repo);

      repo.emitError(
        const AuthFailure(
          AuthFailureType.linkExpired,
          'This link has expired. Please request a new one.',
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.text('This link has expired. Please request a new one.'),
        findsOneWidget,
      );
    });
  });

  group('sign up', () {
    Future<void> openSignUp(
      WidgetTester tester,
      FakeAuthRepository repo,
    ) async {
      await pumpApp(tester, repo);
      await tester.tapAndSettle(find.text('Create an account'));
    }

    final createButton = find.widgetWithText(FilledButton, 'Create account');

    testWidgets('validates password length and confirmation', (tester) async {
      final repo = FakeAuthRepository();
      await openSignUp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'short');
      await tester.enterField('Confirm password', 'different');
      await tester.tapAndSettle(createButton);

      expect(
        find.text('Password must be at least 8 characters.'),
        findsOneWidget,
      );
      expect(find.text('Passwords do not match.'), findsOneWidget);
      expect(repo.calls, isEmpty);
    });

    testWidgets('asks the user to confirm their email', (tester) async {
      final repo = FakeAuthRepository();
      await openSignUp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'nightshade');
      await tester.enterField('Confirm password', 'nightshade');
      await tester.tapAndSettle(createButton);

      expect(repo.calls, ['signUp:raven@example.com']);
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('raven@example.com'), findsOneWidget);

      await tester.tapAndSettle(find.text('Resend email'));
      expect(repo.calls.last, 'resend:raven@example.com');
      expect(find.text('Email sent again.'), findsOneWidget);

      await tester.tapAndSettle(find.text('Back to sign in'));
      expect(_signInButton, findsOneWidget);
    });

    testWidgets('enters the app when confirmation is disabled', (tester) async {
      final repo = FakeAuthRepository()..signUpResult = SignUpResult.signedIn;
      await openSignUp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.enterField('Password', 'nightshade');
      await tester.enterField('Confirm password', 'nightshade');
      await tester.tapAndSettle(createButton);

      expect(find.text(_homeMarker), findsOneWidget);
    });
  });

  group('password reset', () {
    testWidgets('sends a reset link using the entered email', (tester) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, repo);

      await tester.enterField('Email', 'raven@example.com');
      await tester.tapAndSettle(find.text('Forgot password?'));
      await tester.tapAndSettle(
        find.widgetWithText(FilledButton, 'Send reset link'),
      );

      expect(repo.calls, ['reset:raven@example.com']);
      expect(find.text('Check your email'), findsOneWidget);
      expect(find.textContaining('reset your password'), findsOneWidget);
    });

    testWidgets('recovery link forces a new password, then enters the app', (
      tester,
    ) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, repo);

      repo.emit(AuthEventType.passwordRecovery, testUser);
      await tester.pumpAndSettle();
      expect(find.text('Choose a new password'), findsOneWidget);

      // Session refreshes must not let the user skip the reset.
      repo.emit(AuthEventType.sessionRefreshed, testUser);
      await tester.pumpAndSettle();
      expect(find.text('Choose a new password'), findsOneWidget);

      await tester.enterField('New password', 'nightshade');
      await tester.enterField('Confirm new password', 'nightshade');
      await tester.tapAndSettle(
        find.widgetWithText(FilledButton, 'Update password'),
      );

      expect(repo.calls, ['updatePassword']);
      expect(find.text(_homeMarker), findsOneWidget);
      expect(find.text('Your password has been updated.'), findsOneWidget);
    });

    testWidgets('recovery can be cancelled by signing out', (tester) async {
      final repo = FakeAuthRepository();
      await pumpApp(tester, repo);

      repo.emit(AuthEventType.passwordRecovery, testUser);
      await tester.pumpAndSettle();
      await tester.tapAndSettle(find.text('Cancel and sign out'));

      expect(_signInButton, findsOneWidget);
    });
  });

  testWidgets('signing out from settings returns to sign-in', (tester) async {
    final repo = FakeAuthRepository(currentUser: testUser);
    await pumpApp(tester, repo);

    await tester.tapAndSettle(find.text('Settings'));
    await tester.tapAndSettle(find.widgetWithText(FilledButton, 'Sign out'));

    expect(repo.calls, ['signOut']);
    expect(_signInButton, findsOneWidget);
  });

  testWidgets('session expiry elsewhere returns the user to sign-in', (
    tester,
  ) async {
    final repo = FakeAuthRepository(currentUser: testUser);
    await pumpApp(tester, repo);

    repo.emit(AuthEventType.signedOut);
    await tester.pumpAndSettle();

    expect(_signInButton, findsOneWidget);
  });
}
