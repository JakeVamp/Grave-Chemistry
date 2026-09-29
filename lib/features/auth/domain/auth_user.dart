/// The signed-in user, decoupled from the Supabase SDK type.
class AuthUser {
  const AuthUser({required this.id, required this.email, this.role});

  final String id;
  final String? email;

  /// `app_metadata.role`, which only the service role can set. Used only to
  /// decide whether to show moderator navigation; the database checks the
  /// role (and MFA) again for every moderator request.
  final String? role;

  bool get isModerator => role == 'moderator' || role == 'admin';

  @override
  bool operator ==(Object other) =>
      other is AuthUser &&
      other.id == id &&
      other.email == email &&
      other.role == role;

  @override
  int get hashCode => Object.hash(id, email, role);
}
