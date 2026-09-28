import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/utils/app_logger.dart';
import '../domain/profile.dart';
import '../domain/profile_draft.dart';
import '../domain/profile_failure.dart';
import '../domain/profile_repository.dart';
import 'profile_error_mapper.dart';
import 'profile_row_mapper.dart';

/// Reads and writes `public.profiles`. Row Level Security limits every
/// query to the signed-in user's own row.
class SupabaseProfileRepository implements ProfileRepository {
  SupabaseProfileRepository(this._client);

  static const _table = 'profiles';
  static const _requestTimeout = Duration(seconds: 20);

  final SupabaseClient _client;

  @override
  Future<Profile?> fetchMyProfile() {
    return _guard(() async {
      final row = await _client
          .from(_table)
          .select(ProfileRowMapper.selectColumns)
          .eq('id', _currentUserId())
          .maybeSingle();
      return row == null ? null : ProfileRowMapper.fromRow(row);
    });
  }

  @override
  Future<Profile> saveMyProfile(ProfileDraft draft) {
    return _guard(() async {
      final userId = _currentUserId();
      final values = ProfileRowMapper.toWritableRow(draft);

      // Update first; insert only if the row doesn't exist yet. This avoids
      // upsert, which would need UPDATE permission on `id`.
      final updated = await _client
          .from(_table)
          .update(values)
          .eq('id', userId)
          .select(ProfileRowMapper.selectColumns);
      if (updated.isNotEmpty) return ProfileRowMapper.fromRow(updated.first);

      final inserted = await _client
          .from(_table)
          .insert({...values, 'id': userId})
          .select(ProfileRowMapper.selectColumns)
          .single();
      return ProfileRowMapper.fromRow(inserted);
    });
  }

  String _currentUserId() {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) {
      throw const ProfileFailure(
        ProfileFailureType.notAuthenticated,
        'Your session has expired. Please sign in again.',
      );
    }
    return userId;
  }

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_requestTimeout);
    } catch (error, stackTrace) {
      AppLogger.error(
        'Profile request failed',
        error: error,
        stackTrace: stackTrace,
      );
      throw mapProfileError(error);
    }
  }
}
