import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/verification_failure.dart';

const _networkMessage =
    'Unable to connect. Check your internet connection and try again.';

/// Maps a refusal outcome returned by the verification RPCs.
VerificationFailure failureForOutcome(String? outcome) {
  return switch (outcome) {
    'session_expired' ||
    'session_not_open' ||
    'session_not_found' => const VerificationFailure(
      VerificationFailureType.sessionExpired,
      'Your verification session timed out. Please start again.',
    ),
    'media_missing' => const VerificationFailure(
      VerificationFailureType.uploadFailed,
      "We didn't receive your photo. Please try submitting again.",
    ),
    'already_submitted' || 'already_verified' => const VerificationFailure(
      VerificationFailureType.alreadySubmitted,
      "You've already submitted a verification photo.",
    ),
    'profile_incomplete' => const VerificationFailure(
      VerificationFailureType.notEligible,
      'Please finish your profile before verifying.',
    ),
    'rate_limited' => const VerificationFailure(
      VerificationFailureType.rateLimited,
      'Too many attempts. Please wait a while and try again.',
    ),
    'too_many_attempts' => const VerificationFailure(
      VerificationFailureType.tooManyAttempts,
      "You've reached the limit for verification attempts. Please try again "
      'later.',
    ),
    _ => const VerificationFailure(
      VerificationFailureType.unknown,
      'Something went wrong. Please try again.',
    ),
  };
}

/// Maps exceptions from Supabase calls. Raw server text is never shown.
VerificationFailure mapVerificationError(
  Object error, {
  VerificationFailureType fallback = VerificationFailureType.unknown,
}) {
  if (error is VerificationFailure) return error;
  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return const VerificationFailure(
      VerificationFailureType.network,
      _networkMessage,
    );
  }
  if (fallback == VerificationFailureType.uploadFailed) {
    return const VerificationFailure(
      VerificationFailureType.uploadFailed,
      "Your photo couldn't be uploaded. Please try again.",
    );
  }
  return const VerificationFailure(
    VerificationFailureType.unknown,
    'Something went wrong. Please try again.',
  );
}
