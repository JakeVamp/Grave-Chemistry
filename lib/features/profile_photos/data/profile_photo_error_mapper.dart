import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../domain/profile_photo_failure.dart';

ProfilePhotoFailure failureForPhotoOutcome(String? outcome) {
  return switch (outcome) {
    'limit_reached' => const ProfilePhotoFailure(
      ProfilePhotoFailureType.limitReached,
      "You've reached the maximum number of photos. Delete one to add another.",
    ),
    'not_allowed' => const ProfilePhotoFailure(
      ProfilePhotoFailureType.notAllowed,
      "You can't add photos right now.",
    ),
    'rate_limited' => const ProfilePhotoFailure(
      ProfilePhotoFailureType.rateLimited,
      "You've added a lot of photos today. Please try again later.",
    ),
    'upload_missing' => const ProfilePhotoFailure(
      ProfilePhotoFailureType.uploadFailed,
      "Your photo didn't finish uploading. Please try again.",
    ),
    'under_review' => const ProfilePhotoFailure(
      ProfilePhotoFailureType.underReview,
      "This photo is being reviewed and can't be changed right now.",
    ),
    'not_found' => const ProfilePhotoFailure(
      ProfilePhotoFailureType.notFound,
      'That photo is no longer available.',
    ),
    _ => const ProfilePhotoFailure(
      ProfilePhotoFailureType.unknown,
      'Something went wrong. Please try again.',
    ),
  };
}

ProfilePhotoFailure mapProfilePhotoError(
  Object error, {
  ProfilePhotoFailureType fallback = ProfilePhotoFailureType.unknown,
}) {
  if (error is ProfilePhotoFailure) return error;
  if (error is SocketException ||
      error is TimeoutException ||
      error is http.ClientException) {
    return const ProfilePhotoFailure(
      ProfilePhotoFailureType.network,
      'Unable to connect. Check your internet connection and try again.',
    );
  }
  if (fallback == ProfilePhotoFailureType.uploadFailed) {
    return const ProfilePhotoFailure(
      ProfilePhotoFailureType.uploadFailed,
      "Your photo couldn't be uploaded. Please try again.",
    );
  }
  return const ProfilePhotoFailure(
    ProfilePhotoFailureType.unknown,
    'Something went wrong. Please try again.',
  );
}
