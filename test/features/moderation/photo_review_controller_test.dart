import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/moderation/application/moderation_providers.dart';
import 'package:grave_chemistry/features/moderation/data/moderation_error_mapper.dart';
import 'package:grave_chemistry/features/moderation/domain/moderation_repository.dart';
import 'package:grave_chemistry/features/moderation/domain/photo_review_item.dart';

import '../../helpers/fake_moderation.dart';

void main() {
  late FakeModerationRepository repository;
  late FakeModeratorMfaRepository mfa;
  late ProviderContainer container;

  setUp(() {
    repository = FakeModerationRepository(
      items: [
        reviewItem('p1'),
        reviewItem('p2', minute: 1),
        reviewItem('p3', minute: 2),
      ],
    );
    mfa = FakeModeratorMfaRepository();
    container = ProviderContainer(
      overrides: [
        moderationRepositoryProvider.overrideWithValue(repository),
        moderatorMfaRepositoryProvider.overrideWithValue(mfa),
      ],
    );
    addTearDown(container.dispose);
  });

  Future<PhotoReviewController> open(String photoId) async {
    container.listen(photoReviewProvider(photoId), (_, _) {});
    container.listen(photoReviewQueueProvider, (_, _) {});
    await container.read(photoReviewQueueProvider.future);
    await container.read(photoReviewProvider(photoId).future);
    return container.read(photoReviewProvider(photoId).notifier);
  }

  List<String> queueIds() => [
    for (final item in container.read(photoReviewQueueProvider).value!)
      item.photoId,
  ];

  test(
    'a final action removes the item and advances to the next one',
    () async {
      final controller = await open('p2');
      final result = await controller.perform(ReviewAction.reject);
      expect(result, isA<ReviewAdvanced>());
      expect((result as ReviewAdvanced).nextPhotoId, 'p3');
      expect(queueIds(), ['p1', 'p3']);
    },
  );

  test('after the newest item it wraps to the oldest, then empties', () async {
    var controller = await open('p3');
    var result = await controller.perform(ReviewAction.approve);
    expect((result as ReviewAdvanced).nextPhotoId, 'p1');

    controller = await open('p1');
    result = await controller.perform(ReviewAction.remove);
    expect((result as ReviewAdvanced).nextPhotoId, 'p2');

    controller = await open('p2');
    result = await controller.perform(ReviewAction.approve);
    expect((result as ReviewAdvanced).nextPhotoId, isNull);
    expect(queueIds(), isEmpty);
  });

  test('a stale item stays, shows why, and leaves the queue', () async {
    final controller = await open('p1');
    repository.decideElsewhere('p1');
    final result = await controller.perform(ReviewAction.approve);

    expect(result, isA<ReviewStayed>());
    expect((result as ReviewStayed).message, unavailableFailure.message);
    final item = container.read(photoReviewProvider('p1')).value!.item!;
    expect(item.reviewState, ReviewState.decided);
    expect(item.canApprove, isFalse);
    expect(queueIds(), ['p2', 'p3']);
  });

  test('a refused approval changes nothing and keeps the item', () async {
    final controller = await open('p1');
    repository.nextActionFailure = refusedFailure;
    final result = await controller.perform(ReviewAction.approve);
    expect((result as ReviewStayed).message, refusedFailure.message);
    expect(queueIds(), ['p1', 'p2', 'p3']);
  });

  test('losing MFA mid-review re-checks the moderator session', () async {
    final controller = await open('p1');
    await container.read(moderatorMfaProvider.future);
    repository.nextActionFailure = notAuthorizedFailure;
    final before = container.read(moderatorMfaProvider);
    await controller.perform(ReviewAction.approve);
    expect(
      identical(container.read(moderatorMfaProvider), before),
      isFalse,
      reason: 'the MFA status is re-fetched',
    );
  });

  test('re-verification is not a final action', () async {
    final controller = await open('p1');
    final result = await controller.perform(
      ReviewAction.requireReverification,
      reason: '  mismatch  ',
    );
    expect(result, isA<ReviewStayed>());
    expect((result as ReviewStayed).isError, isFalse);
    expect(repository.calls, contains('reverify:owner-p1:mismatch'));
    expect(queueIds(), ['p1', 'p2', 'p3']);
  });

  test('escalation sends the chosen category', () async {
    final controller = await open('p1');
    await controller.perform(
      ReviewAction.escalate,
      category: ChildSafetyCategory.possibleMinor,
    );
    expect(
      repository.calls,
      contains('escalate:p1:sexual_content_involving_possible_minor'),
    );
    expect(queueIds(), ['p2', 'p3']);
  });
}
