enum ProfilePhotoFailureType {
  limitReached,
  notAllowed,
  rateLimited,
  invalidImage,
  uploadFailed,
  underReview,
  notFound,
  network,
  unknown,
}

/// A photo error with a message that is safe to show to the user.
class ProfilePhotoFailure implements Exception {
  const ProfilePhotoFailure(this.type, this.message);

  final ProfilePhotoFailureType type;
  final String message;

  @override
  String toString() => 'ProfilePhotoFailure(${type.name})';
}
