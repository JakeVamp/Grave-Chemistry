import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/moderation/data/moderation_error_mapper.dart';
import 'package:grave_chemistry/features/moderation/domain/photo_review_item.dart';
import 'package:grave_chemistry/features/moderation/domain/review_media.dart';
import 'package:grave_chemistry/features/moderation/presentation/photo_review_screen.dart';

import '../../helpers/fake_auth_repository.dart';
import '../../helpers/fake_moderation.dart';
import '../../helpers/pump_app.dart';

void main() {
  Future<void> openQueue(
    WidgetTester tester,
    FakeModerationRepository moderation, {
    FakeScreenSecurity? screenSecurity,
  }) async {
    await pumpApp(
      tester,
      FakeAuthRepository(currentUser: moderatorUser),
      moderation: moderation,
      screenSecurity: screenSecurity,
      logicalSize: const Size(390, 1400),
    );
    await tester.tapAndSettle(find.text('Moderator tools'));
    await tester.tapAndSettle(find.text('Photo review'));
  }

  Future<void> openItem(WidgetTester tester, String name) async {
    await tester.tapAndSettle(find.textContaining(name).first);
    expect(find.byType(PhotoReviewScreen), findsOneWidget);
  }

  testWidgets('the queue shows review-useful facts only', (tester) async {
    final moderation = FakeModerationRepository(
      items: [
        reviewItem(
          'p1',
          name: 'Wednesday',
          duplicate: DuplicateMatch.exact,
          signals: true,
        ),
        reviewItem(
          'p2',
          name: 'Lydia',
          minute: 1,
          duplicate: DuplicateMatch.similar,
          state: ReviewState.processingFailed,
        ),
      ],
    );
    await openQueue(tester, moderation);

    expect(find.text('Wednesday, 34'), findsOneWidget);
    expect(find.text('Same photo as another account'), findsOneWidget);
    expect(find.text('Similar to another account’s photo'), findsOneWidget);
    expect(find.text('Account has review signals'), findsOneWidget);
    expect(find.text('Processing failed'), findsOneWidget);
    expect(find.text('Retry available'), findsOneWidget);
    expect(find.text('Verified'), findsNWidgets(2));
    // Nothing internal: ids, owner ids, hashes.
    expect(find.textContaining('owner-'), findsNothing);
    expect(find.textContaining('p1'), findsNothing);
    expect(moderation.mediaLoads, 0, reason: 'photos load only when opened');
  });

  testWidgets('an empty queue says so', (tester) async {
    await openQueue(tester, FakeModerationRepository());
    expect(find.text('All caught up'), findsOneWidget);
    expect(find.text('No photos are waiting for review.'), findsOneWidget);
  });

  testWidgets('review shows both photos side by side, blocks screenshots and '
      'offers no way to save them', (tester) async {
    final security = FakeScreenSecurity();
    final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
    await openQueue(tester, moderation, screenSecurity: security);
    await openItem(tester, 'Morticia');

    expect(find.text('Profile photo'), findsOneWidget);
    expect(find.text('Verification photo'), findsOneWidget);
    expect(find.byType(Image), findsNWidgets(2));
    expect(find.textContaining('No automated face matching'), findsOneWidget);
    expect(security.isSecure, isTrue);
    for (final label in ['Download', 'Save photo', 'Share', 'Save image']) {
      expect(find.text(label), findsNothing);
    }
    expect(find.byIcon(Icons.download), findsNothing);
    expect(find.byIcon(Icons.share), findsNothing);

    final key = MemoryImage(reviewImageBytes);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(key).tracked,
      isTrue,
    );

    await tester.tapAndSettle(find.byType(BackButton));
    expect(security.calls, ['enable', 'disable']);
    expect(
      PaintingBinding.instance.imageCache.statusForKey(key).tracked,
      isFalse,
      reason: 'decoded review photos are evicted when the screen closes',
    );
  });

  testWidgets('no verification photo on file is stated plainly', (
    tester,
  ) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')])
      ..verification = VerificationPhotoAvailability.none;
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');
    expect(find.text('No approved verification photo on file'), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('if the photos cannot be loaded securely, none are shown', (
    tester,
  ) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')])
      ..mediaFailure = mediaUnavailableFailure;
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    expect(find.byType(Image), findsNothing);
    expect(find.text(mediaUnavailableFailure.message), findsOneWidget);

    moderation.mediaFailure = null;
    await tester.tapAndSettle(find.text('Reload photos'));
    expect(find.byType(Image), findsNWidgets(2));
    expect(moderation.mediaLoads, 2);
  });

  testWidgets('approve needs no confirmation and advances to the next photo, '
      'then to the empty queue', (tester) async {
    final moderation = FakeModerationRepository(
      items: [
        reviewItem('p1', name: 'Morticia'),
        reviewItem('p2', name: 'Lydia', minute: 1),
      ],
    );
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    await tester.tapAndSettle(find.text('Approve'));
    expect(moderation.calls, contains('approve:p1:'));
    expect(find.text('Lydia, 34'), findsOneWidget, reason: 'next item');

    await tester.tapAndSettle(find.text('Approve'));
    expect(find.text('All caught up'), findsOneWidget);
    expect(find.text('Morticia, 34'), findsNothing);
  });

  testWidgets('reject requires confirmation and records the reason', (
    tester,
  ) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    await tester.tapAndSettle(find.text('Reject'));
    expect(find.text('Reject this photo?'), findsOneWidget);
    await tester.tapAndSettle(find.text('Cancel'));
    expect(moderation.calls.where((c) => c.startsWith('reject')), isEmpty);

    await tester.tapAndSettle(find.text('Reject'));
    await tester.enterText(
      find.widgetWithText(TextField, 'Reason (optional, moderators only)'),
      'Not a photo of a person',
    );
    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Reject'));
    expect(moderation.calls, contains('reject:p1:Not a photo of a person'));
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('remove, re-verification and escalation all require '
      'confirmation', (tester) async {
    final moderation = FakeModerationRepository(
      items: [
        reviewItem('p1', name: 'Morticia'),
        reviewItem('p2', name: 'Lydia', minute: 1),
      ],
    );
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    await tester.tapAndSettle(find.text('Require re-verification'));
    expect(find.text('Require re-verification?'), findsOneWidget);
    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Require'));
    expect(moderation.calls, contains('reverify:owner-p1:'));
    expect(find.textContaining('Re-verification required.'), findsOneWidget);
    expect(find.text('Morticia, 34'), findsOneWidget, reason: 'stays on photo');

    await tester.tapAndSettle(find.text('Escalate to child safety'));
    expect(find.text('Escalate to child safety?'), findsOneWidget);
    final escalate = find.widgetWithText(TextButton, 'Escalate');
    expect(
      tester.widget<TextButton>(escalate).onPressed,
      isNull,
      reason: 'a category must be chosen',
    );
    await tester.tapAndSettle(find.text('The member may be under 18'));
    await tester.tapAndSettle(escalate);
    expect(moderation.calls, contains('escalate:p1:underage_user_concern'));
    expect(find.text('Lydia, 34'), findsOneWidget);

    await tester.tapAndSettle(find.text('Remove'));
    expect(find.text('Remove this photo?'), findsOneWidget);
    await tester.tapAndSettle(find.widgetWithText(TextButton, 'Remove'));
    expect(moderation.calls, contains('remove:p2:'));
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('a refused approval shows a generic message and refreshes', (
    tester,
  ) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')])
      ..nextActionFailure = refusedFailure;
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    await tester.tapAndSettle(find.text('Approve'));
    expect(find.text(refusedFailure.message), findsOneWidget);
    expect(find.textContaining('child-safety review'), findsNothing);
    expect(find.text('Morticia, 34'), findsOneWidget, reason: 'not advanced');
  });

  testWidgets('a photo already handled by another moderator cannot be '
      'approved and leaves the queue', (tester) async {
    final moderation = FakeModerationRepository(
      items: [
        reviewItem('p1'),
        reviewItem('p2', name: 'Lydia', minute: 1),
      ],
    );
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    moderation.decideElsewhere('p1');
    await tester.tapAndSettle(find.text('Approve'));

    expect(find.text(unavailableFailure.message), findsOneWidget);
    expect(find.text('This photo has already been handled.'), findsOneWidget);
    expect(find.text('Approve'), findsNothing, reason: 'no actions remain');
    expect(find.byType(Image), findsNothing, reason: 'photos are closed');

    await tester.tapAndSettle(find.byType(BackButton));
    expect(find.text('Morticia, 34'), findsNothing);
    expect(find.text('Lydia, 34'), findsOneWidget);
  });

  testWidgets('a photo escalated elsewhere becomes unavailable', (
    tester,
  ) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    moderation.items.remove('p1');
    await tester.tapAndSettle(find.byTooltip('Refresh'));
    expect(
      find.text('This photo is no longer available for review.'),
      findsOneWidget,
    );
    expect(find.byType(Image), findsNothing);
    await tester.tapAndSettle(find.text('Back to queue'));
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('a failed photo can be retried but not approved', (tester) async {
    final moderation = FakeModerationRepository(
      items: [reviewItem('p1', state: ReviewState.processingFailed)],
    );
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    final approve = find.widgetWithText(FilledButton, 'Approve');
    expect(tester.widget<FilledButton>(approve).onPressed, isNull);
    expect(find.textContaining('can’t be approved'), findsOneWidget);

    await tester.tapAndSettle(find.text('Retry processing'));
    expect(moderation.calls, contains('retry:p1'));
    expect(find.text('All caught up'), findsOneWidget);
  });

  testWidgets('moderator notes can be added and are listed', (tester) async {
    final moderation = FakeModerationRepository(items: [reviewItem('p1')]);
    await openQueue(tester, moderation);
    await openItem(tester, 'Morticia');

    expect(find.text('No notes yet.'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Add a note'),
      '  Looks like a stock photo.  ',
    );
    await tester.tapAndSettle(find.text('Save note'));
    expect(moderation.calls, contains('note:p1:Looks like a stock photo.'));
    expect(find.text('Looks like a stock photo.'), findsOneWidget);
  });
}
