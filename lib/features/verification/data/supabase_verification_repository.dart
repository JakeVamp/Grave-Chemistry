import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/utils/app_logger.dart';
import '../domain/verification_failure.dart';
import '../domain/verification_repository.dart';
import '../domain/verification_session.dart';
import 'verification_error_mapper.dart';

/// Talks to the verification RPCs and the private `verification-media`
/// bucket. Approval never happens here: the backend only lets clients move
/// themselves to `pending`.
class SupabaseVerificationRepository implements VerificationRepository {
  SupabaseVerificationRepository(this._client, {Random? random})
    : _random = random ?? Random.secure();

  static const bucket = 'verification-media';
  static const _timeout = Duration(seconds: 30);

  final SupabaseClient _client;
  final Random _random;

  @override
  Future<VerificationSession> startSession() async {
    final result = await _call(
      () => _client.rpc<dynamic>('start_verification_session'),
    );
    final map = Map<String, dynamic>.from(result as Map);
    if (map['outcome'] != 'issued') {
      throw failureForOutcome(map['outcome'] as String?);
    }
    return VerificationSession(
      id: map['session_id'] as String,
      challengeCode: map['challenge_type'] as String,
      expiresAt: DateTime.parse(map['expires_at'] as String).toUtc(),
      attemptNumber: (map['attempt_number'] as num).toInt(),
    );
  }

  @override
  Future<String> uploadPhoto(
    VerificationSession session,
    Uint8List jpeg,
  ) async {
    // `<session id>/<32 random hex>.jpg`: no user ID, email or name, and
    // not guessable. The storage policy enforces this shape.
    final path = '${session.id}/${_randomHex(16)}.jpg';
    await _call(
      () => _client.storage
          .from(bucket)
          .uploadBinary(
            path,
            jpeg,
            fileOptions: const FileOptions(contentType: 'image/jpeg'),
          ),
      fallback: VerificationFailureType.uploadFailed,
    );
    return path;
  }

  @override
  Future<void> submit(VerificationSession session, String objectPath) async {
    final result = await _call(
      () => _client.rpc<dynamic>(
        'submit_verification_session',
        params: {'p_session_id': session.id, 'p_object_path': objectPath},
      ),
    );
    final outcome = (result as Map)['outcome'] as String?;
    if (outcome != 'submitted') throw failureForOutcome(outcome);
  }

  String _randomHex(int bytes) => List.generate(
    bytes,
    (_) => _random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();

  Future<T> _call<T>(
    Future<T> Function() action, {
    VerificationFailureType fallback = VerificationFailureType.unknown,
  }) async {
    try {
      return await action().timeout(_timeout);
    } catch (error) {
      // Only the error type is logged: never paths, URLs, tokens or bytes.
      AppLogger.error('Verification request failed (${error.runtimeType})');
      throw mapVerificationError(error, fallback: fallback);
    }
  }
}
