import 'package:flutter_test/flutter_test.dart';
import 'package:grave_chemistry/features/moderation/data/moderation_error_mapper.dart';
import 'package:grave_chemistry/features/moderation/data/review_media_loader.dart';
import 'package:grave_chemistry/features/moderation/data/supabase_moderation_repository.dart';
import 'package:grave_chemistry/features/moderation/domain/moderation_failure.dart';
import 'package:grave_chemistry/features/moderation/domain/photo_review_item.dart';
import 'package:grave_chemistry/features/moderation/domain/review_media.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../helpers/fake_moderation.dart';

void main() {
  group('review media loader', () {
    const profileUrl = 'https://project.supabase.co/storage/v1/sign/p?token=a';
    const selfieUrl = 'https://project.supabase.co/storage/v1/sign/v?token=b';

    Map<String, dynamic> urls({
      String? verificationUrl = selfieUrl,
      String verification = 'available',
    }) => {
      'profile_photo_url': profileUrl,
      'verification_photo_url': verificationUrl,
      'verification': verification,
      'expires_in': 60,
    };

    ReviewMediaLoader loader(
      Map<String, dynamic> response,
      Future<http.Response> Function(http.Request) handler,
    ) => ReviewMediaLoader((_) async => response, MockClient(handler));

    test('downloads both photos once and returns only bytes', () async {
      final requested = <String>[];
      final media = await loader(urls(), (request) async {
        requested.add(request.url.toString());
        return http.Response.bytes(jpegBytes(), 200);
      }).load('p1');

      expect(requested, [profileUrl, selfieUrl]);
      expect(media.profilePhoto, jpegBytes());
      expect(media.verificationPhoto, jpegBytes());
      expect(media.verification, VerificationPhotoAvailability.available);
    });

    test('an expired signed URL fails closed', () async {
      expect(
        loader(
          urls(),
          (_) async => http.Response('{"error":"expired"}', 400),
        ).load('p1'),
        throwsA(
          isA<ModerationFailure>().having(
            (f) => f.type,
            'type',
            ModerationFailureType.mediaUnavailable,
          ),
        ),
      );
    });

    test('content that is not a JPEG is refused', () async {
      expect(
        loader(urls(), (_) async => http.Response('<html>', 200)).load('p1'),
        throwsA(isA<ModerationFailure>()),
      );
    });

    test('oversized downloads are refused', () async {
      expect(
        loader(
          urls(),
          (_) async => http.Response.bytes(
            jpegBytes(ReviewMediaLoader.maxBytes + 1),
            200,
          ),
        ).load('p1'),
        throwsA(isA<ModerationFailure>()),
      );
    });

    test('only https links are followed', () async {
      var requests = 0;
      final response = urls()..['profile_photo_url'] = 'http://evil.test/p';
      expect(
        loader(response, (_) async {
          requests++;
          return http.Response.bytes(jpegBytes(), 200);
        }).load('p1'),
        throwsA(isA<ModerationFailure>()),
      );
      expect(requests, 0);
    });

    test('a network error fails closed', () async {
      expect(
        loader(urls(), (_) => throw http.ClientException('offline')).load('p1'),
        throwsA(isA<ModerationFailure>()),
      );
    });

    test(
      'a verification photo that fails to load is reported as such',
      () async {
        final media = await loader(urls(), (request) async {
          if (request.url.toString() == selfieUrl) {
            return http.Response('expired', 400);
          }
          return http.Response.bytes(jpegBytes(), 200);
        }).load('p1');
        expect(media.verificationPhoto, isNull);
        expect(media.verification, VerificationPhotoAvailability.unavailable);
      },
    );

    test('no verification photo on file', () async {
      final media = await loader(
        urls(verificationUrl: null, verification: 'none'),
        (_) async => http.Response.bytes(jpegBytes(), 200),
      ).load('p1');
      expect(media.verification, VerificationPhotoAvailability.none);
    });

    test('a refused signing request never downloads anything', () async {
      var requests = 0;
      final loader = ReviewMediaLoader(
        (_) async => throw const FunctionException(status: 403),
        MockClient((_) async {
          requests++;
          return http.Response.bytes(jpegBytes(), 200);
        }),
      );
      expect(loader.load('p1'), throwsA(isA<FunctionException>()));
      expect(requests, 0);
      expect(
        mapModerationError(const FunctionException(status: 403)).type,
        ModerationFailureType.notAuthorized,
      );
    });
  });

  group('error mapping', () {
    test('database text is never shown, only generic messages', () {
      final cases = {
        const PostgrestException(message: 'not_authorized', code: '42501'):
            ModerationFailureType.notAuthorized,
        const PostgrestException(
          message: 'photo is not awaiting a decision',
          code: '23514',
        ): ModerationFailureType.unavailable,
        const PostgrestException(
          message: 'photo is not available for moderation',
          code: 'P0001',
        ): ModerationFailureType.unavailable,
        const PostgrestException(
          message: 'photo is not in a failed state',
          code: 'P0001',
        ): ModerationFailureType.unavailable,
        const PostgrestException(
          message: 'photo is under child-safety review',
          code: '23514',
        ): ModerationFailureType.refused,
        const PostgrestException(
          message: 'photo has not passed processing',
          code: '23514',
        ): ModerationFailureType.refused,
        const PostgrestException(message: 'boom', code: 'XX000'):
            ModerationFailureType.unknown,
      };
      for (final MapEntry(key: error, value: type) in cases.entries) {
        final failure = mapModerationError(error);
        expect(failure.type, type, reason: error.message);
        expect(failure.message, isNot(contains(error.message)));
        expect(failure.message.toLowerCase(), isNot(contains('child')));
      }
    });

    test('Edge Function statuses', () {
      expect(
        mapModerationError(const FunctionException(status: 404)).type,
        ModerationFailureType.unavailable,
      );
      expect(
        mapModerationError(const FunctionException(status: 502)).type,
        ModerationFailureType.mediaUnavailable,
      );
    });
  });

  group('queue rows', () {
    Map<String, dynamic> row([Map<String, dynamic> extra = const {}]) => {
      'photo_id': 'p1',
      'owner_id': 'o1',
      'uploaded_at': '2026-09-29T12:00:00Z',
      'display_name': 'Morticia',
      'age': 34,
      'verification_status': 'verified',
      'has_review_signals': true,
      'duplicate_match': 'similar',
      'content_flagged': false,
      'automated_checks_incomplete': false,
      'review_state': 'awaiting_review',
      'can_approve': true,
      'can_retry': false,
      ...extra,
    };

    test('parses the review flags', () {
      final item = photoReviewItemFromRow(row());
      expect(item.duplicateMatch, DuplicateMatch.similar);
      expect(item.hasReviewSignals, isTrue);
      expect(item.isOpen, isTrue);
      expect(item.canApprove, isTrue);
    });

    test('unknown states and missing hints fail closed', () {
      final item = photoReviewItemFromRow(
        row({
          'review_state': 'something_new',
          'can_approve': null,
          'can_retry': null,
          'automated_checks_incomplete': null,
        }),
      );
      expect(item.reviewState, ReviewState.decided);
      expect(item.isOpen, isFalse);
      expect(item.canApprove, isFalse);
      expect(item.canRetry, isFalse);
      expect(item.automatedChecksIncomplete, isTrue);
    });
  });
}
