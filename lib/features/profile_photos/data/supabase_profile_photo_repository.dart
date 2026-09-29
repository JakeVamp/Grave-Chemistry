import 'dart:async';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/utils/app_logger.dart';
import '../domain/profile_photo.dart';
import '../domain/profile_photo_failure.dart';
import '../domain/profile_photo_repository.dart';
import 'profile_photo_error_mapper.dart';

/// Profile photo RPCs and the private `profile-photos` bucket. Approval and
/// visibility are decided server-side.
class SupabaseProfilePhotoRepository implements ProfilePhotoRepository {
  SupabaseProfilePhotoRepository(this._client);

  static const bucket = 'profile-photos';
  static const _signedUrlLifetime = Duration(minutes: 30);
  static const _timeout = Duration(seconds: 30);

  final SupabaseClient _client;

  @override
  Future<List<ProfilePhoto>> fetchMine() async {
    final rows = await _call(() => _client.rpc<dynamic>('my_profile_photos'));
    return [
      for (final row in (rows as List).cast<Map<String, dynamic>>())
        profilePhotoFromRow(row),
    ];
  }

  @override
  Future<PhotoUploadSlot> reserveUpload() async {
    final result = await _call(
      () => _client.rpc<dynamic>('begin_profile_photo_upload'),
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['outcome'] != 'ready') {
      throw failureForPhotoOutcome(map['outcome'] as String?);
    }
    return PhotoUploadSlot(
      assetId: map['asset_id'] as String,
      objectPath: map['object_path'] as String,
    );
  }

  @override
  Future<void> uploadFile(PhotoUploadSlot slot, Uint8List jpeg) async {
    await _call(
      () => _client.storage
          .from(bucket)
          .uploadBinary(
            slot.objectPath,
            jpeg,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          ),
      fallback: ProfilePhotoFailureType.uploadFailed,
    );
  }

  @override
  Future<void> completeUpload(PhotoUploadSlot slot) async {
    final result = await _call(
      () => _client.rpc<dynamic>(
        'complete_profile_photo_upload',
        params: {'p_asset_id': slot.assetId},
      ),
    );
    final outcome = (result as Map)['outcome'] as String?;
    if (outcome != 'added') throw failureForPhotoOutcome(outcome);
  }

  @override
  Future<void> delete(String photoId) async {
    final result = await _call(
      () => _client.rpc<dynamic>(
        'delete_profile_photo',
        params: {'p_photo_id': photoId},
      ),
    );
    final outcome = (result as Map)['outcome'] as String?;
    if (outcome != 'removed') throw failureForPhotoOutcome(outcome);
  }

  @override
  Future<void> reorder(List<String> photoIds) => _call(
    () => _client.rpc<dynamic>(
      'reorder_profile_photos',
      params: {'p_photo_ids': photoIds},
    ),
  );

  @override
  Future<void> setPrimary(String photoId) => _call(
    () => _client.rpc<dynamic>(
      'set_primary_profile_photo',
      params: {'p_photo_id': photoId},
    ),
  );

  @override
  Future<String?> signedUrl(String objectPath) async {
    try {
      return await _client.storage
          .from(bucket)
          .createSignedUrl(objectPath, _signedUrlLifetime.inSeconds)
          .timeout(_timeout);
    } catch (error) {
      // Never log the URL or path.
      AppLogger.error('Photo URL unavailable (${error.runtimeType})');
      return null;
    }
  }

  Future<T> _call<T>(
    Future<T> Function() action, {
    ProfilePhotoFailureType fallback = ProfilePhotoFailureType.unknown,
  }) async {
    try {
      return await action().timeout(_timeout);
    } catch (error) {
      AppLogger.error('Profile photo request failed (${error.runtimeType})');
      throw mapProfilePhotoError(error, fallback: fallback);
    }
  }
}

ProfilePhoto profilePhotoFromRow(Map<String, dynamic> row) {
  return ProfilePhoto(
    id: row['photo_id'] as String,
    objectPath: row['object_path'] as String?,
    position: (row['position'] as num).toInt(),
    isPrimary: row['is_primary'] as bool? ?? false,
    status: PhotoReviewStatus.fromCode(row['status'] as String?),
  );
}
