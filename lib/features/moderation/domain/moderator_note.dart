/// A private moderator note. Never shown to members.
class ModeratorNote {
  const ModeratorNote({
    required this.id,
    required this.body,
    required this.moderatorId,
    required this.createdAt,
  });

  final int id;
  final String body;
  final String moderatorId;
  final DateTime createdAt;

  static const maxLength = 1000;
}
