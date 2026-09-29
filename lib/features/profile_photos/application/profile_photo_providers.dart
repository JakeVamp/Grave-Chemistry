import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/supabase/supabase_providers.dart';
import '../../../shared/media/photo_sanitizer.dart';
import '../data/device_photo_picker.dart';
import '../data/supabase_profile_photo_repository.dart';
import '../domain/profile_photo.dart';
import '../domain/profile_photo_failure.dart';
import '../domain/profile_photo_repository.dart';
import 'photo_picker.dart';

final profilePhotoRepositoryProvider = Provider<ProfilePhotoRepository>(
  (ref) => SupabaseProfilePhotoRepository(ref.watch(supabaseClientProvider)),
);

final photoPickerProvider = Provider<PhotoPicker>((ref) => DevicePhotoPicker());

/// Re-encodes a picked image as JPEG without metadata, off the UI isolate.
final profilePhotoSanitizerProvider =
    Provider<Future<Uint8List> Function(Uint8List)>(
      (ref) =>
          (bytes) => compute(sanitizePhoto, bytes),
    );

final profilePhotosProvider =
    AsyncNotifierProvider.autoDispose<
      ProfilePhotosController,
      List<ProfilePhoto>
    >(ProfilePhotosController.new, retry: (retryCount, error) => null);

/// Short-lived signed URL for a photo path, for showing thumbnails.
final profilePhotoUrlProvider = FutureProvider.autoDispose
    .family<String?, String>(
      (ref, objectPath) =>
          ref.watch(profilePhotoRepositoryProvider).signedUrl(objectPath),
    );

final photoUploadProvider =
    NotifierProvider.autoDispose<PhotoUploadController, PhotoUploadState>(
      PhotoUploadController.new,
    );

class ProfilePhotosController extends AsyncNotifier<List<ProfilePhoto>> {
  ProfilePhotoRepository get _repository =>
      ref.read(profilePhotoRepositoryProvider);

  @override
  Future<List<ProfilePhoto>> build() =>
      ref.watch(profilePhotoRepositoryProvider).fetchMine();

  Future<void> refresh() async {
    final photos = await _repository.fetchMine();
    if (ref.mounted) state = AsyncData(photos);
  }

  /// Throws `ProfilePhotoFailure`.
  Future<void> delete(String photoId) async {
    await _repository.delete(photoId);
    await refresh();
  }

  Future<void> setPrimary(String photoId) async {
    await _repository.setPrimary(photoId);
    await refresh();
  }

  /// Moves a photo from one index to another in the current order.
  Future<void> move(int from, int to) async {
    final photos = [...?state.value];
    if (from < 0 || from >= photos.length || to < 0 || to >= photos.length) {
      return;
    }
    final moved = photos.removeAt(from);
    photos.insert(to, moved);
    // Show the new order immediately; the server confirms it.
    state = AsyncData([
      for (final (i, p) in photos.indexed)
        ProfilePhoto(
          id: p.id,
          objectPath: p.objectPath,
          position: i + 1,
          isPrimary: p.isPrimary,
          status: p.status,
        ),
    ]);
    try {
      await _repository.reorder([for (final p in photos) p.id]);
    } finally {
      await refresh();
    }
  }
}

enum PhotoUploadStage { idle, preparing, uploading, finishing }

class PhotoUploadState {
  const PhotoUploadState({this.stage = PhotoUploadStage.idle, this.failure});

  final PhotoUploadStage stage;
  final ProfilePhotoFailure? failure;

  bool get isBusy => stage != PhotoUploadStage.idle;

  /// Coarse progress for the progress bar.
  double get progress => switch (stage) {
    PhotoUploadStage.idle => 0,
    PhotoUploadStage.preparing => 0.2,
    PhotoUploadStage.uploading => 0.55,
    PhotoUploadStage.finishing => 0.9,
  };

  String get label => switch (stage) {
    PhotoUploadStage.idle => '',
    PhotoUploadStage.preparing => 'Preparing photo…',
    PhotoUploadStage.uploading => 'Uploading…',
    PhotoUploadStage.finishing => 'Finishing up…',
  };
}

class PhotoUploadController extends Notifier<PhotoUploadState> {
  @override
  PhotoUploadState build() => const PhotoUploadState();

  /// Picks a photo from the library, strips its metadata and uploads it.
  /// Returns true when a photo was added.
  Future<bool> pickAndUpload() async {
    if (state.isBusy) return false;
    final picked = await ref.read(photoPickerProvider).pickFromLibrary();
    if (picked == null || !ref.mounted) return false;

    state = const PhotoUploadState(stage: PhotoUploadStage.preparing);
    final repository = ref.read(profilePhotoRepositoryProvider);
    try {
      final Uint8List jpeg;
      try {
        jpeg = await ref.read(profilePhotoSanitizerProvider)(picked);
      } on FormatException {
        throw const ProfilePhotoFailure(
          ProfilePhotoFailureType.invalidImage,
          "That file couldn't be read as a photo. Please choose another.",
        );
      }
      final slot = await repository.reserveUpload();
      if (!ref.mounted) return false;
      state = const PhotoUploadState(stage: PhotoUploadStage.uploading);
      await repository.uploadFile(slot, jpeg);
      if (!ref.mounted) return false;
      state = const PhotoUploadState(stage: PhotoUploadStage.finishing);
      await repository.completeUpload(slot);
    } on ProfilePhotoFailure catch (failure) {
      if (ref.mounted) state = PhotoUploadState(failure: failure);
      return false;
    }
    if (!ref.mounted) return true;
    state = const PhotoUploadState();
    await ref.read(profilePhotosProvider.notifier).refresh();
    return true;
  }

  void dismissFailure() => state = const PhotoUploadState();
}
