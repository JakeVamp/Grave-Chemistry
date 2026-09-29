import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/auth/data/supabase_auth_repository.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  User user({
    Map<String, dynamic> app = const {},
    Map<String, dynamic>? userMeta,
  }) => User(
    id: 'u1',
    appMetadata: app,
    userMetadata: userMeta,
    aud: 'authenticated',
    createdAt: '2026-09-29T00:00:00Z',
  );

  test('the moderator role comes from app_metadata', () {
    final mapped = authUserFromSupabase(user(app: {'role': 'moderator'}));
    expect(mapped.role, 'moderator');
    expect(mapped.isModerator, isTrue);
  });

  test('4. user_metadata.role = moderator grants nothing', () {
    final mapped = authUserFromSupabase(user(userMeta: {'role': 'moderator'}));
    expect(mapped.role, isNull);
    expect(mapped.isModerator, isFalse);
  });

  test('other roles and malformed values are not moderators', () {
    for (final role in <Object?>['child_safety_reviewer', 'user', 42, null]) {
      expect(
        authUserFromSupabase(user(app: {'role': role})).isModerator,
        isFalse,
        reason: '$role',
      );
    }
  });
}
