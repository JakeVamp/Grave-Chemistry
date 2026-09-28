import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/profile_failure.dart';

/// Converts errors from the Supabase data API into user-facing
/// [ProfileFailure]s. Raw database messages are never shown to users.
ProfileFailure mapProfileError(Object error) {
  if (error is ProfileFailure) return error;

  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return const ProfileFailure(
      ProfileFailureType.network,
      'Unable to connect. Check your internet connection and try again.',
    );
  }

  if (error is PostgrestException) {
    // Raised by the profiles_before_write trigger.
    if (error.message.contains('under_minimum_age')) {
      return const ProfileFailure(
        ProfileFailureType.underage,
        'You must be at least 18 to use Grave Chemistry.',
      );
    }
    if (error.message.contains('birth_date_in_future')) {
      return const ProfileFailure(
        ProfileFailureType.birthDateInFuture,
        "Birth date can't be in the future.",
      );
    }

    switch (error.code) {
      case '23514': // check_violation
      case '23503': // foreign_key_violation (unknown option or mismatch)
      case '22P02': // invalid_text_representation
      case '22007': // invalid_datetime_format
        return const ProfileFailure(
          ProfileFailureType.invalidData,
          'Some of your answers could not be saved. Please review them and '
          'try again.',
        );
      case '42501': // insufficient_privilege / RLS
        return const ProfileFailure(
          ProfileFailureType.permissionDenied,
          "You don't have permission to change this profile.",
        );
      case 'PGRST301':
      case 'PGRST302':
      case 'PGRST303':
        return const ProfileFailure(
          ProfileFailureType.notAuthenticated,
          'Your session has expired. Please sign in again.',
        );
    }
  }

  return const ProfileFailure(
    ProfileFailureType.unknown,
    'Something went wrong. Please try again.',
  );
}
