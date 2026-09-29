import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo_failure.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_profile_photos.dart';
import '../../helpers/pump_app.dart';

void main() {
  Future<FakeProfilePhotoRepository> openPhotos(
    WidgetTester tester, {
    List<ProfilePhoto> initial = const [],
    FakePhotoPicker? picker,
    Size logicalSize = const Size(390, 844),
    double textScale = 1,
  }) async {
    final repo = FakeProfilePhotoRepository(photos: initial);
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: testUser),
      photos: repo,
      photoPicker: picker,
      logicalSize: logicalSize,
      textScale: textScale,
    );
    await tester.tapAndSettle(find.text('Profile photos'));
    return repo;
  }

  testWidgets('empty state explains review and separation from verification', (
    tester,
  ) async {
    await openPhotos(tester);
    expect(find.text('No photos yet.'), findsOneWidget);
    expect(find.text('0 of 6 photos'), findsOneWidget);
    expect(
      find.textContaining('verification photo is never used'),
      findsOneWidget,
    );
  });

  testWidgets('shows primary and review status for each photo', (tester) async {
    await openPhotos(
      tester,
      initial: [
        photo('a', 1, primary: true),
        photo('b', 2, status: PhotoReviewStatus.inReview),
        photo('c', 3, status: PhotoReviewStatus.notApproved),
      ],
    );
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('Live'), findsOneWidget);
    expect(find.text('In review'), findsOneWidget);
    expect(find.text('Not approved'), findsOneWidget);
  });

  testWidgets('adding a photo shows progress, then the photo in review', (
    tester,
  ) async {
    final repo = FakeProfilePhotoRepository()..uploadGate = Completer<void>();
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: testUser),
      photos: repo,
    );
    await tester.tapAndSettle(find.text('Profile photos'));

    await tester.tap(find.text('Add photo'));
    await tester.pump();
    await tester.pump();
    expect(find.text('Uploading…'), findsOneWidget);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);

    repo.uploadGate!.complete();
    await tester.pumpAndSettle();
    expect(find.text('In review'), findsOneWidget);
    expect(find.text('Primary'), findsOneWidget);
    expect(find.text('1 of 6 photos'), findsOneWidget);
  });

  testWidgets('the add button is disabled at the limit', (tester) async {
    await openPhotos(
      tester,
      initial: [for (var i = 1; i <= 6; i++) photo('p$i', i, primary: i == 1)],
    );
    await tester.scrollUntilVisible(find.text('Photo limit reached'), 200);
    final button = tester.widget<ButtonStyleButton>(
      find.ancestor(
        of: find.text('Photo limit reached'),
        matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
      ),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('make primary, move and delete from the photo menu', (
    tester,
  ) async {
    final repo = await openPhotos(
      tester,
      initial: [photo('a', 1, primary: true), photo('b', 2)],
    );

    await tester.tapAndSettle(find.byTooltip('Photo 2 options'));
    await tester.tapAndSettle(find.text('Make primary'));
    expect(repo.calls.last, 'primary:b');

    await tester.tapAndSettle(find.byTooltip('Photo 2 options'));
    await tester.tapAndSettle(find.text('Move up'));
    expect(repo.calls.last, 'reorder:b,a');

    await tester.tapAndSettle(find.byTooltip('Photo 2 options'));
    await tester.tapAndSettle(find.text('Delete'));
    expect(find.text('Delete this photo?'), findsOneWidget);
    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Delete'));
    expect(repo.calls.last, 'delete:a');
    expect(find.text('1 of 6 photos'), findsOneWidget);
  });

  testWidgets('a held photo cannot be deleted and says why', (tester) async {
    final repo =
        FakeProfilePhotoRepository(
            photos: [
              photo('a', 1, primary: true, status: PhotoReviewStatus.inReview),
            ],
          )
          ..nextDeleteFailure = const ProfilePhotoFailure(
            ProfilePhotoFailureType.underReview,
            "This photo is being reviewed and can't be changed right now.",
          );
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: testUser),
      photos: repo,
    );
    await tester.tapAndSettle(find.text('Profile photos'));
    await tester.tapAndSettle(find.byTooltip('Photo 1 options'));
    await tester.tapAndSettle(find.text('Delete'));
    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Delete'));

    expect(find.textContaining('being reviewed'), findsOneWidget);
    expect(find.text('1 of 6 photos'), findsOneWidget);
  });

  testWidgets('a failed upload offers Try again, which completes it', (
    tester,
  ) async {
    final repo = FakeProfilePhotoRepository()
      ..nextCompleteFailure = const ProfilePhotoFailure(
        ProfilePhotoFailureType.network,
        'Unable to connect. Check your internet connection and try again.',
      );
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: testUser),
      photos: repo,
    );
    await tester.tapAndSettle(find.text('Profile photos'));
    await tester.tapAndSettle(find.text('Add photo'));

    expect(find.textContaining('internet connection'), findsOneWidget);
    await tester.tapAndSettle(find.text('Try again'));
    expect(find.text('1 of 6 photos'), findsOneWidget);
    expect(find.text('In review'), findsOneWidget);
  });

  testWidgets('refresh shows review results without internal details', (
    tester,
  ) async {
    final repo = await openPhotos(
      tester,
      initial: [
        photo('a', 1, primary: true, status: PhotoReviewStatus.inReview),
      ],
    );
    expect(find.textContaining('Checking this photo'), findsOneWidget);

    repo.photos = [
      photo('a', 1, primary: true, status: PhotoReviewStatus.notApproved),
    ];
    await tester.tapAndSettle(find.byTooltip('Refresh'));
    expect(find.text('Not approved'), findsOneWidget);
    expect(find.textContaining("wasn't approved"), findsOneWidget);
    for (final hidden in [
      'duplicate',
      'risk',
      'provider',
      'child',
      'moderator',
    ]) {
      expect(
        find.textContaining(RegExp(hidden, caseSensitive: false)),
        findsNothing,
        reason: hidden,
      );
    }

    repo.photos = [];
    await tester.tapAndSettle(find.byTooltip('Refresh'));
    expect(
      find.text('No photos yet.'),
      findsOneWidget,
      reason: 'removed photos disappear',
    );
  });

  testWidgets('fits a small phone with 2x text', (tester) async {
    await openPhotos(
      tester,
      initial: [
        photo('a', 1, primary: true),
        photo('b', 2, status: PhotoReviewStatus.inReview),
      ],
      logicalSize: const Size(320, 568),
      textScale: 2,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('meets contrast and tap-target guidelines', (tester) async {
    final handle = tester.ensureSemantics();
    await openPhotos(tester, initial: [photo('a', 1, primary: true)]);
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    handle.dispose();
  });
}
