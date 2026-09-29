import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../shared/utils/app_logger.dart';
import '../domain/moderation_failure.dart';
import '../domain/moderator_mfa.dart';
import 'moderation_error_mapper.dart';

/// TOTP multi-factor authentication through Supabase Auth. Reaching aal2
/// is what the database requires for every moderator request.
class SupabaseModeratorMfaRepository implements ModeratorMfaRepository {
  SupabaseModeratorMfaRepository(this._auth);

  static const _timeout = Duration(seconds: 20);

  final GoTrueClient _auth;

  @override
  Future<ModeratorMfaStatus> status() => _guard(() async {
    final level = _auth.mfa.getAuthenticatorAssuranceLevel();
    if (level.currentLevel == AuthenticatorAssuranceLevels.aal2) {
      return const MfaVerified();
    }
    final factors = await _auth.mfa.listFactors();
    if (factors.totp.isNotEmpty) return MfaCodeRequired(factors.totp.first.id);
    return const MfaEnrollmentRequired();
  });

  @override
  Future<TotpEnrollment> enrollTotp() => _guard(() async {
    // Abandoned set-ups would otherwise pile up (and block re-enrolling).
    for (final factor in _auth.currentUser?.factors ?? const <Factor>[]) {
      if (factor.factorType == FactorType.totp &&
          factor.status == FactorStatus.unverified) {
        await _auth.mfa.unenroll(factor.id);
      }
    }
    final response = await _auth.mfa.enroll(
      issuer: 'Grave Chemistry',
      friendlyName: 'Moderator authenticator',
    );
    final totp = response.totp;
    if (totp == null) throw unknownFailure;
    return TotpEnrollment(factorId: response.id, secret: totp.secret);
  });

  @override
  Future<void> verifyCode({required String factorId, required String code}) =>
      _guard(
        () => _auth.mfa.challengeAndVerify(factorId: factorId, code: code),
      );

  Future<T> _guard<T>(Future<T> Function() action) async {
    try {
      return await action().timeout(_timeout);
    } on AuthException catch (error) {
      AppLogger.error('MFA request failed (${error.runtimeType})');
      throw const ModerationFailure(
        ModerationFailureType.notAuthorized,
        "That code didn't work. Check your authenticator app and try again.",
      );
    } catch (error) {
      AppLogger.error('MFA request failed (${error.runtimeType})');
      throw mapModerationError(error);
    }
  }
}
