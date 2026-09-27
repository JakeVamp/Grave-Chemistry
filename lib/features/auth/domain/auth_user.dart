/// The signed-in user, decoupled from the Supabase SDK type.
class AuthUser {
  const AuthUser({required this.id, required this.email});

  final String id;
  final String? email;

  @override
  bool operator ==(Object other) =>
      other is AuthUser && other.id == id && other.email == email;

  @override
  int get hashCode => Object.hash(id, email);
}
