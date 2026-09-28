import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile/domain/verification_status.dart';
import 'package:grave_chemistry/features/verification/domain/camera_permission.dart';
import 'package:grave_chemistry/features/verification/domain/verification_failure.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_profile_repository.dart';
import '../../helpers/fake_verification.dart';
import '../../helpers/pump_app.dart';

const _homeMarker = 'Foundation build';

void main() {
  Future<FakeProfileRepository> pumpWithStatus(
    WidgetTester tester,
    VerificationStatus status, {
    FakeVerificationRepository? verification,
    FakeCameraPermissionService? cameraPermission,
    FakeCameraFactory? cameras,
    Size logicalSize = const Size(390, 844),
    double textScale = 1,
  }) async {
    final profiles = FakeProfileRepository(
      profile: completedProfileWith(status),
    );
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: testUser),
      profiles: profiles,
      verification: verification,
      cameraPermission: cameraPermission,
      cameras: cameras,
      logicalSize: logicalSize,
      textScale: textScale,
    );
    return profiles;
  }

  group('routing', () {
    testWidgets('complete profile without verification -> verification', (
      tester,
    ) async {
      await pumpWithStatus(tester, VerificationStatus.notStarted);
      expect(find.text('Verify your account'), findsOneWidget);
      expect(find.text('A quick live photo'), findsOneWidget);
      expect(find.text(_homeMarker), findsNothing);
    });

    testWidgets('pending -> pending screen, not the app', (tester) async {
      await pumpWithStatus(tester, VerificationStatus.pending);
      expect(find.text('Verification in review'), findsOneWidget);
      expect(find.text(_homeMarker), findsNothing);
    });

    testWidgets('rejected -> retry screen', (tester) async {
      await pumpWithStatus(tester, VerificationStatus.rejected);
      expect(find.textContaining("couldn't be approved"), findsOneWidget);
      expect(find.text('Start verification'), findsOneWidget);
    });

    testWidgets('reverification required -> retry screen', (tester) async {
      await pumpWithStatus(tester, VerificationStatus.reverificationRequired);
      expect(find.textContaining('verify your account again'), findsOneWidget);
    });

    testWidgets('verified -> the app', (tester) async {
      await pumpWithStatus(tester, VerificationStatus.verified);
      expect(find.text(_homeMarker), findsOneWidget);
    });

    testWidgets('pending user sees approval after checking status', (
      tester,
    ) async {
      final profiles = await pumpWithStatus(tester, VerificationStatus.pending);
      profiles.profile = completedProfileWith(VerificationStatus.verified);
      await tester.tapAndSettle(find.text('Check status'));
      expect(find.text(_homeMarker), findsOneWidget);
    });

    testWidgets('signing out from verification returns to sign-in', (
      tester,
    ) async {
      await pumpWithStatus(tester, VerificationStatus.notStarted);
      await tester.tapAndSettle(find.widgetWithText(TextButton, 'Sign out'));
      expect(find.widgetWithText(FilledButton, 'Sign in'), findsOneWidget);
    });
  });

  group('capture flow', () {
    testWidgets('offers the camera only, never a photo library', (
      tester,
    ) async {
      await pumpWithStatus(tester, VerificationStatus.notStarted);
      for (final word in ['Gallery', 'Library', 'Choose photo', 'Upload']) {
        expect(find.textContaining(word), findsNothing, reason: word);
      }
      expect(find.textContaining('library can’t be used'), findsOneWidget);
    });

    testWidgets('capture, retake, submit -> pending screen', (tester) async {
      final cameras = FakeCameraFactory();
      final permission = FakeCameraPermissionService();
      await pumpWithStatus(
        tester,
        VerificationStatus.notStarted,
        cameras: cameras,
        cameraPermission: permission,
      );
      expect(permission.requests, 0, reason: 'no prompt before starting');

      await tester.tapAndSettle(find.text('Start verification'));
      expect(permission.requests, 1);
      expect(find.text('Take your photo'), findsOneWidget);
      expect(find.text('Turn your head slightly to the left'), findsOneWidget);

      await tester.tapAndSettle(find.text('Take photo'));
      expect(find.text('Use this photo?'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);

      await tester.tapAndSettle(find.text('Retake'));
      expect(find.text('Take your photo'), findsOneWidget);
      await tester.tapAndSettle(find.text('Take photo'));

      await tester.tapAndSettle(find.text('Submit photo'));
      expect(find.text('Verification in review'), findsOneWidget);
      expect(find.text(_homeMarker), findsNothing);
      expect(cameras.created.every((c) => c.disposed), isTrue);
    });

    testWidgets('cancel from the camera returns to the explanation', (
      tester,
    ) async {
      await pumpWithStatus(tester, VerificationStatus.notStarted);
      await tester.tapAndSettle(find.text('Start verification'));
      await tester.tapAndSettle(find.byTooltip('Cancel'));
      expect(find.text('A quick live photo'), findsOneWidget);
    });

    testWidgets('permanently denied permission offers Settings', (
      tester,
    ) async {
      final permission = FakeCameraPermissionService(
        CameraPermissionStatus.permanentlyDenied,
      );
      await pumpWithStatus(
        tester,
        VerificationStatus.notStarted,
        cameraPermission: permission,
      );
      await tester.tapAndSettle(find.text('Start verification'));

      expect(find.text('Camera access needed'), findsOneWidget);
      await tester.tapAndSettle(find.text('Open Settings'));
      expect(permission.settingsOpened, 1);
    });

    testWidgets('upload failure shows a message and can be retried', (
      tester,
    ) async {
      final profiles = FakeProfileRepository(
        profile: completedProfileWith(VerificationStatus.notStarted),
      );
      final backend = FakeVerificationRepository(profiles: profiles)
        ..nextUploadFailure = const VerificationFailure(
          VerificationFailureType.uploadFailed,
          "Your photo couldn't be uploaded. Please try again.",
        );
      await pumpApp(
        tester,
        FakeAuthRepository(currentUser: testUser),
        profiles: profiles,
        verification: backend,
      );
      await tester.tapAndSettle(find.text('Start verification'));
      await tester.tapAndSettle(find.text('Take photo'));
      await tester.tapAndSettle(find.text('Submit photo'));

      expect(find.textContaining("couldn't be uploaded"), findsOneWidget);
      await tester.tapAndSettle(find.text('Try again'));
      expect(find.text('Verification in review'), findsOneWidget);
    });
  });

  group('accessibility', () {
    testWidgets('verification intro fits a small phone with 2x text', (
      tester,
    ) async {
      await pumpWithStatus(
        tester,
        VerificationStatus.rejected,
        logicalSize: const Size(320, 568),
        textScale: 2,
      );
      await tester.tapAndSettle(find.text('Start verification'));
      expect(tester.takeException(), isNull);
    });

    testWidgets('verification screens meet contrast and tap-target rules', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpWithStatus(tester, VerificationStatus.notStarted);
      await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
      await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
      await expectLater(tester, meetsGuideline(textContrastGuideline));

      await tester.tapAndSettle(find.text('Start verification'));
      await tester.tapAndSettle(find.text('Take photo'));
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      handle.dispose();
    });
  });
}
