import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/moderation_failure.dart';

const notAuthorizedFailure = ModerationFailure(
  ModerationFailureType.notAuthorized,
  'Your moderator session needs two-factor verification. Go back to '
  'Moderator tools and verify again.',
);

const unavailableFailure = ModerationFailure(
  ModerationFailureType.unavailable,
  'This photo was already handled or has changed. Your queue has been '
  'updated.',
);

const refusedFailure = ModerationFailure(
  ModerationFailureType.refused,
  "This action isn't allowed for this photo right now. Nothing was changed.",
);

const mediaUnavailableFailure = ModerationFailure(
  ModerationFailureType.mediaUnavailable,
  "The photos couldn't be loaded securely. Try again.",
);

const networkFailure = ModerationFailure(
  ModerationFailureType.network,
  'Unable to connect. Check your internet connection and try again.',
);

const unknownFailure = ModerationFailure(
  ModerationFailureType.unknown,
  "Something went wrong. Refresh to check the photo's current state.",
);

// Database messages that mean the item changed under the moderator.
const _stale = [
  'not awaiting a decision',
  'not available',
  'not found',
  'not in a failed state',
];

// Safety conditions the database enforces on approval.
const _refused = ['not passed processing', 'child-safety review'];

/// Maps backend errors to safe, generic messages. Database text is only
/// matched, never shown.
ModerationFailure mapModerationError(Object error) {
  if (error is ModerationFailure) return error;
  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return networkFailure;
  }
  if (error is PostgrestException) {
    if (error.code == '42501') return notAuthorizedFailure;
    final message = error.message.toLowerCase();
    if (_refused.any(message.contains)) return refusedFailure;
    if (_stale.any(message.contains)) return unavailableFailure;
    if (error.code == '23514') return refusedFailure;
    return unknownFailure;
  }
  if (error is FunctionException) {
    return switch (error.status) {
      401 || 403 => notAuthorizedFailure,
      404 => unavailableFailure,
      _ => mediaUnavailableFailure,
    };
  }
  if (error is AuthException) return notAuthorizedFailure;
  return unknownFailure;
}
