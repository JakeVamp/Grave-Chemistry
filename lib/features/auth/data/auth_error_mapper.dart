import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/auth_failure.dart';

const _networkMessage =
    'Unable to connect. Check your internet connection and try again.';
const _rateLimitMessage =
    'Too many attempts. Please wait a few minutes and try again.';
const _linkExpiredMessage = 'This link has expired. Please request a new one.';
const _linkInvalidMessage =
    'This link is invalid or has already been used. Please request a new one.';
const _unknownMessage = 'Something went wrong. Please try again.';

/// Converts any error thrown by Supabase Auth into a user-facing
/// [AuthFailure]. Raw server messages are never shown to users.
AuthFailure mapAuthError(Object error) {
  if (error is AuthFailure) return error;

  if (error is AuthRetryableFetchException ||
      error is SocketException ||
      error is TimeoutException) {
    return const AuthFailure(AuthFailureType.network, _networkMessage);
  }

  if (error is AuthWeakPasswordException) {
    return const AuthFailure(
      AuthFailureType.weakPassword,
      'That password is too weak. Try a longer password with a mix of '
      'letters, numbers and symbols.',
    );
  }

  if (error is! AuthException) {
    return const AuthFailure(AuthFailureType.unknown, _unknownMessage);
  }

  // Errors parsed from a redirect URL carry the error code in `statusCode`
  // and the error name in `code`, so both are checked.
  final codes = {error.code, error.statusCode};
  bool has(String code) => codes.contains(code);

  if (has('invalid_credentials')) {
    return const AuthFailure(
      AuthFailureType.invalidCredentials,
      'Incorrect email or password.',
    );
  }
  if (has('email_not_confirmed')) {
    return const AuthFailure(
      AuthFailureType.emailNotConfirmed,
      'Please confirm your email address before signing in.',
    );
  }
  if (has('user_already_exists') || has('email_exists')) {
    return const AuthFailure(
      AuthFailureType.emailAlreadyRegistered,
      'An account with this email already exists. Try signing in instead.',
    );
  }
  if (has('email_address_invalid')) {
    return const AuthFailure(
      AuthFailureType.invalidEmail,
      'Please enter a valid email address.',
    );
  }
  if (has('weak_password')) {
    return const AuthFailure(
      AuthFailureType.weakPassword,
      'That password is too weak. Please choose a stronger one.',
    );
  }
  if (has('same_password')) {
    return const AuthFailure(
      AuthFailureType.samePassword,
      'Your new password must be different from your current password.',
    );
  }
  if (has('signup_disabled') || has('email_provider_disabled')) {
    return const AuthFailure(
      AuthFailureType.signUpDisabled,
      'New account sign-ups are currently unavailable.',
    );
  }
  if (has('over_email_send_rate_limit') ||
      has('over_request_rate_limit') ||
      has('429')) {
    return const AuthFailure(AuthFailureType.rateLimited, _rateLimitMessage);
  }
  if (has('otp_expired') || has('flow_state_expired')) {
    return const AuthFailure(AuthFailureType.linkExpired, _linkExpiredMessage);
  }
  if (error is AuthPKCEGrantCodeExchangeError ||
      error.message.contains('Code verifier could not be found')) {
    return const AuthFailure(
      AuthFailureType.linkInvalid,
      'This link could not be completed on this device. Open it on the '
      'device where you requested it. If you were confirming your email, '
      'try signing in.',
    );
  }
  if (has('flow_state_not_found') ||
      has('bad_code_verifier') ||
      has('otp_disabled') ||
      has('access_denied')) {
    return const AuthFailure(AuthFailureType.linkInvalid, _linkInvalidMessage);
  }
  if (error is AuthSessionMissingException ||
      has('session_not_found') ||
      has('refresh_token_not_found') ||
      has('refresh_token_already_used')) {
    return const AuthFailure(
      AuthFailureType.sessionExpired,
      'Your session has expired. Please sign in again.',
    );
  }

  return const AuthFailure(AuthFailureType.unknown, _unknownMessage);
}
