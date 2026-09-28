/// Mirrors rows in `public.community_identities`. New identities are added
/// as a database row plus an enum value here.
enum CommunityIdentity {
  goth('goth', 'Goth'),
  normie('normie', 'Normie');

  const CommunityIdentity(this.code, this.label);

  /// Value stored in the database.
  final String code;
  final String label;

  /// Returns null for codes this app version doesn't know yet.
  static CommunityIdentity? fromCode(String? code) {
    for (final value in values) {
      if (value.code == code) return value;
    }
    return null;
  }
}
