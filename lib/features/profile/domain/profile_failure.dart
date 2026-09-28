enum ProfileFailureType {
  network,
  underage,
  birthDateInFuture,
  invalidData,
  notAuthenticated,
  permissionDenied,
  unknown,
}

/// A profile error with a message that is safe to show to the user.
class ProfileFailure implements Exception {
  const ProfileFailure(this.type, this.message);

  final ProfileFailureType type;
  final String message;

  @override
  String toString() => 'ProfileFailure(${type.name}): $message';
}
