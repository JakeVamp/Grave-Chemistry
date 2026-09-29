import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile_photos/application/profile_photo_providers.dart';
import 'package:grave_chemistry/features/profile_photos/data/supabase_profile_photo_repository.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo_failure.dart';

import '../../helpers/fake_profile_photos.dart';

void main() {
  late FakeProfilePhotoRepository repo;
  late FakePhotoPicker picker;

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        profilePhotoRepositoryProvider.overrideWithValue(repo),
        photoPickerProvider.overrideWithValue(picker),
        profilePhotoSanitizerProvider.overrideWithValue((bytes) async => bytes),
      ],
    );
    addTearDown(container.dispose);
    container.listen(profilePhotosProvider, (_, _) {});
    container.listen(photoUploadProvider, (_, _) {});
    return container;
  }

  setUp(() {
    repo = FakeProfilePhotoRepository();
    picker = FakePhotoPicker(result: pickedBytes);
  });

  test(
    'upload goes through reserve, upload and complete, then refreshes',
    () async {
      final c = createContainer();
      await c.read(profilePhotosProvider.future);

      final added = await c.read(photoUploadProvider.notifier).pickAndUpload();
      expect(added, isTrue);
      expect(repo.calls, ['reserve', 'upload:p1', 'complete:p1']);
      final photos = c.read(profilePhotosProvider).value!;
      expect(photos.single.status, PhotoReviewStatus.inReview);
      expect(photos.single.isPrimary, isTrue);
      expect(c.read(photoUploadProvider).isBusy, isFalse);
    },
  );

  test('cancelling the picker does nothing', () async {
    picker.result = null;
    final c = createContainer();
    expect(await c.read(photoUploadProvider.notifier).pickAndUpload(), isFalse);
    expect(repo.calls, isEmpty);
  });

  test('the server limit is reported without uploading', () async {
    repo = FakeProfilePhotoRepository(
      photos: [for (var i = 1; i <= 6; i++) photo('x$i', i, primary: i == 1)],
    );
    final c = createContainer();
    await c.read(profilePhotosProvider.future);
    await c.read(photoUploadProvider.notifier).pickAndUpload();

    expect(
      c.read(photoUploadProvider).failure?.type,
      ProfilePhotoFailureType.limitReached,
    );
    expect(repo.calls, ['reserve']);
  });

  test('upload failure is shown and nothing is added', () async {
    repo.nextUploadFailure = const ProfilePhotoFailure(
      ProfilePhotoFailureType.uploadFailed,
      'failed',
    );
    final c = createContainer();
    await c.read(profilePhotosProvider.future);
    await c.read(photoUploadProvider.notifier).pickAndUpload();

    expect(
      c.read(photoUploadProvider).failure?.type,
      ProfilePhotoFailureType.uploadFailed,
    );
    expect(c.read(profilePhotosProvider).value, isEmpty);
    c.read(photoUploadProvider.notifier).dismissFailure();
    expect(c.read(photoUploadProvider).failure, isNull);
  });

  test('unreadable images are rejected before reserving a slot', () async {
    final c = ProviderContainer(
      overrides: [
        profilePhotoRepositoryProvider.overrideWithValue(repo),
        photoPickerProvider.overrideWithValue(picker),
        profilePhotoSanitizerProvider.overrideWithValue(
          (bytes) async => throw const FormatException('bad'),
        ),
      ],
    );
    addTearDown(c.dispose);
    c.listen(photoUploadProvider, (_, _) {});
    await c.read(photoUploadProvider.notifier).pickAndUpload();

    expect(
      c.read(photoUploadProvider).failure?.type,
      ProfilePhotoFailureType.invalidImage,
    );
    expect(repo.calls, isEmpty);
  });

  test('reorder, primary and delete', () async {
    repo = FakeProfilePhotoRepository(
      photos: [photo('a', 1, primary: true), photo('b', 2), photo('c', 3)],
    );
    final c = createContainer();
    await c.read(profilePhotosProvider.future);
    final controller = c.read(profilePhotosProvider.notifier);

    await controller.move(2, 0);
    expect(repo.calls.last, 'reorder:c,a,b');
    expect(c.read(profilePhotosProvider).value!.map((p) => p.id), [
      'c',
      'a',
      'b',
    ]);

    await controller.setPrimary('b');
    expect(
      c.read(profilePhotosProvider).value!.where((p) => p.isPrimary).single.id,
      'b',
    );

    await controller.delete('b');
    final left = c.read(profilePhotosProvider).value!;
    expect(left.map((p) => p.id), ['c', 'a']);
    expect(left.where((p) => p.isPrimary), hasLength(1));
  });

  test('a photo under review cannot be deleted', () async {
    repo = FakeProfilePhotoRepository(photos: [photo('a', 1, primary: true)])
      ..nextDeleteFailure = const ProfilePhotoFailure(
        ProfilePhotoFailureType.underReview,
        'under review',
      );
    final c = createContainer();
    await c.read(profilePhotosProvider.future);
    await expectLater(
      c.read(profilePhotosProvider.notifier).delete('a'),
      throwsA(isA<ProfilePhotoFailure>()),
    );
    expect(c.read(profilePhotosProvider).value, hasLength(1));
  });

  test('rows map to photos with a coarse status only', () {
    final p = profilePhotoFromRow({
      'photo_id': 'id-1',
      'object_path': null,
      'position': 2,
      'is_primary': false,
      'status': 'in_review',
    });
    expect(p.objectPath, isNull);
    expect(p.status, PhotoReviewStatus.inReview);
    expect(
      PhotoReviewStatus.fromCode('something_new'),
      PhotoReviewStatus.inReview,
    );
  });
}
