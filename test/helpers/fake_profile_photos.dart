import 'dart:async';
import 'dart:typed_data';

import 'package:grave_chemistry/features/profile_photos/application/photo_picker.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo_failure.dart';
import 'package:grave_chemistry/features/profile_photos/domain/profile_photo_repository.dart';

final pickedBytes = Uint8List.fromList(List.filled(8, 1));

/// In-memory backend that mirrors the server rules: new photos start in
/// review, the first is primary, the limit is enforced.
class FakeProfilePhotoRepository implements ProfilePhotoRepository {
  FakeProfilePhotoRepository({List<ProfilePhoto>? photos})
    : photos = [...?photos];

  List<ProfilePhoto> photos;
  int _next = 0;

  ProfilePhotoFailure? nextReserveFailure;
  ProfilePhotoFailure? nextUploadFailure;
  ProfilePhotoFailure? nextDeleteFailure;

  /// When set, uploads wait for it, to observe progress.
  Completer<void>? uploadGate;
  final List<String> calls = [];

  @override
  Future<List<ProfilePhoto>> fetchMine() async => List.of(photos);

  @override
  Future<PhotoUploadSlot> reserveUpload() async {
    calls.add('reserve');
    final failure = nextReserveFailure;
    if (failure != null) {
      nextReserveFailure = null;
      throw failure;
    }
    if (photos.length >= ProfilePhotoLimits.maxPhotos) {
      throw const ProfilePhotoFailure(
        ProfilePhotoFailureType.limitReached,
        'limit',
      );
    }
    _next++;
    return PhotoUploadSlot(assetId: 'p$_next', objectPath: 'p$_next/x.jpg');
  }

  @override
  Future<void> uploadFile(PhotoUploadSlot slot, Uint8List jpeg) async {
    calls.add('upload:${slot.assetId}');
    if (uploadGate != null) await uploadGate!.future;
    final failure = nextUploadFailure;
    if (failure != null) {
      nextUploadFailure = null;
      throw failure;
    }
  }

  @override
  Future<void> completeUpload(PhotoUploadSlot slot) async {
    calls.add('complete:${slot.assetId}');
    photos.add(
      ProfilePhoto(
        id: slot.assetId,
        objectPath: slot.objectPath,
        position: photos.length + 1,
        isPrimary: photos.isEmpty,
        status: PhotoReviewStatus.inReview,
      ),
    );
  }

  @override
  Future<void> delete(String photoId) async {
    calls.add('delete:$photoId');
    final failure = nextDeleteFailure;
    if (failure != null) {
      nextDeleteFailure = null;
      throw failure;
    }
    final wasPrimary = photos.firstWhere((p) => p.id == photoId).isPrimary;
    photos.removeWhere((p) => p.id == photoId);
    _renumber(
      primaryId: wasPrimary && photos.isNotEmpty ? photos.first.id : null,
    );
  }

  @override
  Future<void> reorder(List<String> photoIds) async {
    calls.add('reorder:${photoIds.join(',')}');
    photos = [for (final id in photoIds) photos.firstWhere((p) => p.id == id)];
    _renumber();
  }

  @override
  Future<void> setPrimary(String photoId) async {
    calls.add('primary:$photoId');
    _renumber(primaryId: photoId);
  }

  @override
  Future<String?> signedUrl(String objectPath) async => null;

  void _renumber({String? primaryId}) {
    photos = [
      for (final (i, p) in photos.indexed)
        ProfilePhoto(
          id: p.id,
          objectPath: p.objectPath,
          position: i + 1,
          isPrimary: primaryId == null ? p.isPrimary : p.id == primaryId,
          status: p.status,
        ),
    ];
  }
}

class FakePhotoPicker implements PhotoPicker {
  FakePhotoPicker({this.result});

  Uint8List? result;
  int picks = 0;

  @override
  Future<Uint8List?> pickFromLibrary() async {
    picks++;
    return result;
  }
}

ProfilePhoto photo(
  String id,
  int position, {
  bool primary = false,
  PhotoReviewStatus status = PhotoReviewStatus.live,
}) => ProfilePhoto(
  id: id,
  objectPath: '$id/x.jpg',
  position: position,
  isPrimary: primary,
  status: status,
);
