import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/profile/data/profile_error_mapper.dart';
import 'package:grave_chemistry/features/profile/data/profile_row_mapper.dart';
import 'package:grave_chemistry/features/profile/domain/community_identity.dart';
import 'package:grave_chemistry/features/profile/domain/dating_preference.dart';
import 'package:grave_chemistry/features/profile/domain/gender_option.dart';
import 'package:grave_chemistry/features/profile/domain/profile_draft.dart';
import 'package:grave_chemistry/features/profile/domain/profile_failure.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  group('ProfileRowMapper', () {
    test('reads a database row', () {
      final profile = ProfileRowMapper.fromRow({
        'id': 'user-1',
        'display_name': 'Raven',
        'birth_date': '1995-10-31',
        'location_city': 'Salem',
        'location_state_or_region': 'Massachusetts',
        'bio': 'Line one\nLine two',
        'gender': 'self_describe',
        'gender_self_description': 'Moth-adjacent',
        'community_identity': 'goth',
        'dating_preference': 'goth_seeking_normie',
        'profile_completed': true,
        'created_at': '2026-09-28T10:00:00+00:00',
        'updated_at': '2026-09-28T11:00:00+00:00',
      });

      expect(profile.isCompleted, isTrue);
      expect(profile.birthDate, DateTime.utc(1995, 10, 31));
      expect(profile.gender, GenderOption.selfDescribe);
      expect(profile.communityIdentity, CommunityIdentity.goth);
      expect(profile.datingPreference, DatingPreference.gothSeekingNormie);
      expect(profile.bio, 'Line one\nLine two');
      expect(profile.updatedAt, DateTime.utc(2026, 9, 28, 11));
      expect(profile.ageOn(DateTime.utc(2026, 9, 28)), 30);
    });

    test('tolerates a partial row and unknown future codes', () {
      final profile = ProfileRowMapper.fromRow({
        'id': 'user-1',
        'profile_completed': false,
        'gender': 'added_in_a_later_release',
      });
      expect(profile.isCompleted, isFalse);
      expect(profile.gender, isNull);
      expect(profile.birthDate, isNull);
    });

    test('writes only onboarding columns, never completion or timestamps', () {
      final row = ProfileRowMapper.toWritableRow(
        ProfileDraft(
          displayName: '  Raven ',
          birthDate: DateTime.utc(1995, 3, 7),
          city: ' Salem',
          region: 'Massachusetts ',
          bio: '   ',
          gender: GenderOption.woman,
          genderSelfDescription: 'stale',
          communityIdentity: CommunityIdentity.normie,
          datingPreference: DatingPreference.normieSeekingGoth,
        ),
      );

      expect(row, {
        'display_name': 'Raven',
        'birth_date': '1995-03-07',
        'location_city': 'Salem',
        'location_state_or_region': 'Massachusetts',
        'bio': null,
        'gender': 'woman',
        'gender_self_description': null,
        'community_identity': 'normie',
        'dating_preference': 'normie_seeking_goth',
      });
      expect(row.containsKey('profile_completed'), isFalse);
      expect(row.containsKey('id'), isFalse);
    });
  });

  group('mapProfileError', () {
    ProfileFailureType typeOf(Object error) => mapProfileError(error).type;

    test('maps trigger age errors', () {
      expect(
        typeOf(
          const PostgrestException(message: 'under_minimum_age', code: '23514'),
        ),
        ProfileFailureType.underage,
      );
      expect(
        typeOf(
          const PostgrestException(
            message: 'birth_date_in_future',
            code: '23514',
          ),
        ),
        ProfileFailureType.birthDateInFuture,
      );
    });

    test('maps constraint, permission and session errors', () {
      expect(
        typeOf(const PostgrestException(message: 'x', code: '23503')),
        ProfileFailureType.invalidData,
      );
      expect(
        typeOf(const PostgrestException(message: 'x', code: '42501')),
        ProfileFailureType.permissionDenied,
      );
      expect(
        typeOf(
          const PostgrestException(message: 'JWT expired', code: 'PGRST301'),
        ),
        ProfileFailureType.notAuthenticated,
      );
    });

    test('maps network failures', () {
      expect(
        typeOf(http.ClientException('offline')),
        ProfileFailureType.network,
      );
      expect(typeOf(TimeoutException('slow')), ProfileFailureType.network);
    });

    test('never exposes raw database messages', () {
      final failure = mapProfileError(
        const PostgrestException(
          message: 'relation "profiles" does not exist',
          code: '42P01',
        ),
      );
      expect(failure.type, ProfileFailureType.unknown);
      expect(failure.message, isNot(contains('relation')));
    });
  });
}
